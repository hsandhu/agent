import Foundation
import Combine

/// On-device zero-shot (voice cloning) TTS built on ZipVoice-Distill via
/// sherpa-onnx. Synthesis requests are serialized on a background queue;
/// resulting audio is queued into the player in order.
final class TtsEngine: ObservableObject {
  enum LoadState: Equatable {
    case idle, loading, ready
    case failed(String)
  }

  @Published private(set) var loadState: LoadState = .idle
  @Published private(set) var isSynthesizing = false
  @Published private(set) var lastStats: String?

  /// Flow-matching steps; 4 is recommended for the distilled model.
  var numSteps = 4
  var speed: Float = 1.0

  private var tts: SherpaOnnxOfflineTtsWrapper?
  private let queue = DispatchQueue(label: "com.robsandhu.agent.tts", qos: .userInitiated)
  private let player = AudioPlayer()
  // Keyed by wav path; enrollment writes a new file each time so no staleness.
  private var promptCache: [String: (samples: [Float], sampleRate: Int)] = [:]

  func loadIfNeeded() {
    switch loadState {
    case .idle, .failed: break
    case .loading, .ready: return
    }
    loadState = .loading
    queue.async { [weak self] in
      guard let self else { return }
      let zipvoice = sherpaOnnxOfflineTtsZipvoiceModelConfig(
        tokens: ModelPaths.ttsTokens.path,
        encoder: ModelPaths.ttsEncoder.path,
        decoder: ModelPaths.ttsDecoder.path,
        vocoder: ModelPaths.ttsVocoder.path,
        dataDir: ModelPaths.ttsEspeakData.path,
        lexicon: ModelPaths.ttsLexicon.path
      )
      let model = sherpaOnnxOfflineTtsModelConfig(
        numThreads: min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)),
        zipvoice: zipvoice
      )
      var config = sherpaOnnxOfflineTtsConfig(model: model)
      let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
      if wrapper.tts == nil {
        DispatchQueue.main.async { self.loadState = .failed("Could not load the ZipVoice model.") }
      } else {
        self.tts = wrapper
        DispatchQueue.main.async { self.loadState = .ready }
      }
    }
  }

  /// Synthesize `text` in the voice described by `profile` and play it.
  /// Requests are processed in order.
  func speak(text: String, profile: VoiceProfile) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queue.async { [weak self] in
      guard let self, let tts = self.tts else { return }
      guard let prompt = self.prompt(for: profile) else {
        DispatchQueue.main.async { self.lastStats = "Could not read reference audio for \(profile.name)." }
        return
      }
      DispatchQueue.main.async { self.isSynthesizing = true }

      let started = Date()
      let audio = tts.generateZeroShot(
        text: Self.ensureTerminalPunctuation(trimmed),
        promptText: profile.transcript,
        promptSamples: prompt.samples,
        promptSampleRate: prompt.sampleRate,
        speed: self.speed,
        numSteps: self.numSteps
      )
      let elapsed = Date().timeIntervalSince(started)
      let duration = audio.sampleRate > 0 ? Double(audio.n) / Double(audio.sampleRate) : 0

      DispatchQueue.main.async {
        self.isSynthesizing = false
        if audio.n > 0 {
          self.lastStats = String(
            format: "%.1fs of audio in %.1fs (RTF %.2f)",
            duration, elapsed, duration > 0 ? elapsed / duration : 0)
        } else {
          self.lastStats = "Synthesis produced no audio."
        }
      }
      if audio.n > 0 {
        self.player.play(samples: audio.samples, sampleRate: Int(audio.sampleRate))
      }
    }
  }

  func stopPlayback() {
    player.stop()
  }

  /// Play a raw wav file (used to preview enrollment recordings).
  func playWav(url: URL) {
    queue.async { [weak self] in
      guard let self else { return }
      let wave = SherpaOnnxWaveWrapper.readWave(filename: url.path)
      guard wave.wave != nil, wave.numSamples > 0 else { return }
      self.player.play(samples: wave.samples, sampleRate: wave.sampleRate)
    }
  }

  // MARK: - Private (on `queue`)

  private func prompt(for profile: VoiceProfile) -> (samples: [Float], sampleRate: Int)? {
    let key = profile.wavURL.path
    if let cached = promptCache[key] { return cached }
    let wave = SherpaOnnxWaveWrapper.readWave(filename: key)
    guard wave.wave != nil, wave.numSamples > 0 else { return nil }
    let value = (samples: wave.samples, sampleRate: wave.sampleRate)
    promptCache[key] = value
    return value
  }

  /// ZipVoice prosody is better when the sentence ends with punctuation, and
  /// our ASR output has none.
  private static func ensureTerminalPunctuation(_ text: String) -> String {
    guard let last = text.last else { return text }
    return ".!?,;:".contains(last) ? text : text + "."
  }
}
