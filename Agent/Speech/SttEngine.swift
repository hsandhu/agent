import Foundation
import Combine

struct TranscriptSegment: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let date = Date()
}

/// Streaming on-device speech-to-text built on the sherpa-onnx streaming
/// Zipformer transducer, with endpoint detection to segment utterances.
final class SttEngine: ObservableObject {
  @Published private(set) var partial = ""
  @Published private(set) var segments: [TranscriptSegment] = []
  @Published private(set) var isRunning = false
  @Published private(set) var status = "Idle"

  /// Called on the main queue each time an utterance is finalized.
  var onUtterance: ((String) -> Void)?

  /// Dictation mode: while these are set, recognized speech is routed to them
  /// instead of the main transcript (used to dictate into text fields, e.g.
  /// describing a new agent task). Set/cleared on the main thread.
  var dictationOnPartial: ((String) -> Void)?
  var dictationOnUtterance: ((String) -> Void)?

  private var recognizer: SherpaOnnxRecognizer?
  private let capture = AudioCapture()
  private let queue = DispatchQueue(label: "com.robsandhu.agent.stt", qos: .userInitiated)
  private var lastPartial = ""

  /// Both must be called on the main thread; `isRunning` flips immediately so
  /// a start/stop pair arriving in quick succession cannot interleave (the
  /// deferred capture start re-checks it).
  func start() {
    guard !isRunning else { return }
    isRunning = true
    status = "Loading recognizer…"

    capture.onSamples = { [weak self] samples in
      guard let self else { return }
      self.queue.async { self.process(samples) }
    }

    queue.async { [weak self] in
      guard let self else { return }
      self.ensureRecognizer()
      DispatchQueue.main.async {
        guard self.isRunning else { return }  // stopped while loading
        do {
          try self.capture.start()
          self.status = "Listening"
        } catch {
          self.isRunning = false
          self.status = "Mic error: \(error.localizedDescription)"
        }
      }
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    status = "Idle"
    capture.stop()
    queue.async { [weak self] in
      guard let self, let recognizer = self.recognizer else { return }
      // Flush whatever is still buffered into a final segment.
      while recognizer.isReady() { recognizer.decode() }
      let text = Self.prettify(recognizer.getResult().text)
      recognizer.reset()
      self.lastPartial = ""
      self.onMain {
        if let dictate = self.dictationOnUtterance {
          if !text.isEmpty { dictate(text) }
          self.dictationOnPartial?("")
          return
        }
        if !text.isEmpty {
          self.segments.append(TranscriptSegment(text: text))
          self.onUtterance?(text)
        }
        self.partial = ""
      }
    }
  }

  func clear() {
    segments.removeAll()
    partial = ""
  }

  // MARK: - Decoding (all on `queue`)

  private func ensureRecognizer() {
    guard recognizer == nil else { return }
    let transducer = sherpaOnnxOnlineTransducerModelConfig(
      encoder: ModelPaths.asrEncoder.path,
      decoder: ModelPaths.asrDecoder.path,
      joiner: ModelPaths.asrJoiner.path
    )
    let modelConfig = sherpaOnnxOnlineModelConfig(
      tokens: ModelPaths.asrTokens.path,
      transducer: transducer,
      numThreads: 2,
      provider: "cpu"
    )
    var config = sherpaOnnxOnlineRecognizerConfig(
      featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
      modelConfig: modelConfig,
      enableEndpoint: true,
      rule1MinTrailingSilence: 2.4,   // silence with no speech yet
      rule2MinTrailingSilence: 0.9,   // trailing silence after speech
      rule3MinUtteranceLength: 30     // hard cap on utterance length
    )
    recognizer = SherpaOnnxRecognizer(config: &config)
  }

  private func process(_ samples: [Float]) {
    guard let recognizer else { return }
    recognizer.acceptWaveform(samples: samples, sampleRate: 16_000)
    while recognizer.isReady() {
      recognizer.decode()
    }
    let text = Self.prettify(recognizer.getResult().text)

    if recognizer.isEndpoint() {
      recognizer.reset()
      lastPartial = ""
      onMain {
        if let dictate = self.dictationOnUtterance {
          if !text.isEmpty { dictate(text) }
          self.dictationOnPartial?("")
          return
        }
        self.partial = ""
        if !text.isEmpty {
          self.segments.append(TranscriptSegment(text: text))
          self.onUtterance?(text)
        }
      }
    } else if text != lastPartial {
      lastPartial = text
      onMain {
        if let dictatePartial = self.dictationOnPartial {
          dictatePartial(text)
        } else {
          self.partial = text
        }
      }
    }
  }

  /// The 20M Zipformer emits unpunctuated ALL-CAPS text; make it readable.
  private static func prettify(_ raw: String) -> String {
    let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = t.first else { return "" }
    return first.uppercased() + t.dropFirst()
  }

  private func onMain(_ work: @escaping () -> Void) {
    DispatchQueue.main.async(execute: work)
  }
}
