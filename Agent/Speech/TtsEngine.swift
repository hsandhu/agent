import Foundation
import Combine

/// On-device zero-shot (voice cloning) TTS built on ZipVoice-Distill via
/// sherpa-onnx. Synthesis requests are serialized on a background queue;
/// resulting audio is queued into the player in order.
///
/// Long text is synthesized a chunk at a time and each chunk is handed to the
/// player as soon as it exists, so the first sentence starts playing while the
/// rest is still being generated. Synthesizing a whole paragraph before
/// scheduling anything is what made pressing play feel dead for seconds.
final class TtsEngine: ObservableObject {
  enum LoadState: Equatable {
    case idle, loading, ready
    case failed(String)
  }

  /// What the transport is doing, and for whom. `preparing` exists so a play
  /// button can flip to "pause" the instant it is tapped, while the first
  /// chunk is still being synthesized.
  enum Playback: Equatable {
    case idle
    case preparing(UUID)
    case playing(UUID)
    case paused(UUID)

    var id: UUID? {
      switch self {
      case .idle: return nil
      case .preparing(let id), .playing(let id), .paused(let id): return id
      }
    }

    var isPaused: Bool {
      if case .paused = self { return true }
      return false
    }
  }

  /// Whether a request interrupts what is playing or queues up behind it.
  /// Echoing live transcription wants `enqueue`; pressing play on a result
  /// wants `replace`.
  enum SpeakMode {
    case enqueue
    case replace
  }

  @Published private(set) var loadState: LoadState = .idle
  @Published private(set) var isSynthesizing = false
  @Published private(set) var lastStats: String?
  @Published private(set) var playback: Playback = .idle

  /// Flow-matching steps; 4 is recommended for the distilled model.
  var numSteps = 4
  var speed: Float = 1.0

  private var tts: SherpaOnnxOfflineTtsWrapper?
  private let queue = DispatchQueue(label: "com.robsandhu.agent.tts", qos: .userInitiated)
  private let player = AudioPlayer()
  // Keyed by wav path; enrollment writes a new file each time so no staleness.
  private var promptCache: [String: (samples: [Float], sampleRate: Int)] = [:]

  private let lock = NSLock()
  /// Bumped whenever pending work is cancelled, so in-flight chunks can bail.
  private var epoch = 0
  /// Chunks accepted but not yet handed to the player, across all requests.
  private var pendingChunks = 0
  /// ZipVoice's vocoder output rate — used to warm the engine up before the
  /// first chunk exists. Corrected from the real audio after the first run.
  private var outputSampleRate = 24_000

  init() {
    player.onQueueDrained = { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let pending = self.pendingChunks
      self.lock.unlock()
      // More chunks are still coming; the silence is a buffer gap, not the end.
      guard pending == 0, !self.playback.isPaused else { return }
      self.playback = .idle
    }
  }

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

  // MARK: - Speaking

  /// Synthesize `text` in the voice described by `profile` and play it.
  ///
  /// `id` identifies the utterance so the UI can show transport state for the
  /// row that started it; pass the model's id when there is one.
  @discardableResult
  func speak(
    text: String,
    profile: VoiceProfile,
    id: UUID = UUID(),
    mode: SpeakMode = .enqueue
  ) -> UUID {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let chunks = Self.chunks(for: trimmed)
    guard !chunks.isEmpty else { return id }

    lock.lock()
    if mode == .replace {
      epoch &+= 1
      pendingChunks = 0
    }
    let generation = epoch
    pendingChunks += chunks.count
    lock.unlock()

    if mode == .replace { player.stop() }
    publish(.preparing(id))

    queue.async { [weak self] in
      guard let self else { return }
      guard let tts = self.tts, self.isCurrent(generation) else {
        self.dropChunks(chunks.count, generation: generation)
        self.publishIdle(for: id)
        return
      }
      guard let prompt = self.prompt(for: profile) else {
        DispatchQueue.main.async {
          self.lastStats = "Could not read reference audio for \(profile.name)."
        }
        self.dropChunks(chunks.count, generation: generation)
        self.publishIdle(for: id)
        return
      }

      // Bring the audio path up while the first chunk is being generated.
      self.player.prepare(sampleRate: self.outputSampleRate)

      DispatchQueue.main.async { self.isSynthesizing = true }
      let started = Date()
      var totalDuration = 0.0
      var firstSoundAt: TimeInterval?

      // Reaching either `break` means the epoch moved on, and whoever moved
      // it already reset `pendingChunks` — no accounting to undo here.
      for chunk in chunks {
        guard self.isCurrent(generation) else { break }
        let audio = tts.generateZeroShot(
          text: Self.ensureTerminalPunctuation(chunk),
          promptText: profile.transcript,
          promptSamples: prompt.samples,
          promptSampleRate: prompt.sampleRate,
          speed: self.speed,
          numSteps: self.numSteps
        )
        guard self.isCurrent(generation) else { break }
        if audio.n > 0 {
          if firstSoundAt == nil { firstSoundAt = Date().timeIntervalSince(started) }
          self.outputSampleRate = Int(audio.sampleRate)
          totalDuration += Double(audio.n) / Double(audio.sampleRate)
          self.player.play(samples: audio.samples, sampleRate: Int(audio.sampleRate))
          self.markPlaying(id)
        }
        // Counted down only once the audio is queued, so a drain callback
        // can't see an empty pipeline while the last chunk is still in hand.
        self.dropChunks(1, generation: generation)
      }

      let elapsed = Date().timeIntervalSince(started)
      DispatchQueue.main.async {
        self.isSynthesizing = false
        if let firstSoundAt {
          // RTF stays in: above 1.0 synthesis can't keep ahead of playback and
          // the chunks start gapping, which is the number worth tuning against.
          self.lastStats = String(
            format: "%.1fs of audio in %.1fs (RTF %.2f) · first sound after %.1fs",
            totalDuration, elapsed, totalDuration > 0 ? elapsed / totalDuration : 0,
            firstSoundAt)
        } else {
          self.lastStats = "Synthesis produced no audio."
        }
      }
      // Nothing reached the player, so no drain callback is coming.
      if firstSoundAt == nil { self.publishIdle(for: id) }
    }
    return id
  }

  /// Play / pause / resume the utterance identified by `id`, the way a
  /// transport button expects. Call from the main thread.
  func toggle(text: String, profile: VoiceProfile, id: UUID) {
    switch playback {
    case .playing(let current) where current == id,
      .preparing(let current) where current == id:
      pause()
    case .paused(let current) where current == id:
      resume()
    default:
      speak(text: text, profile: profile, id: id, mode: .replace)
    }
  }

  /// Call from the main thread.
  func pause() {
    guard let id = playback.id else { return }
    player.pause()
    playback = .paused(id)
  }

  /// Call from the main thread.
  func resume() {
    guard case .paused(let id) = playback else { return }
    player.resume()
    playback = .playing(id)
  }

  func stopPlayback() {
    lock.lock()
    epoch &+= 1
    pendingChunks = 0
    lock.unlock()
    player.stop()
    publish(.idle)
  }

  func isActive(_ id: UUID) -> Bool { playback.id == id }
  func isPaused(_ id: UUID) -> Bool { playback == .paused(id) }
  func isPreparing(_ id: UUID) -> Bool { playback == .preparing(id) }

  /// Whether `id` owns the transport and is not parked — what a play/pause
  /// button draws itself from. True from the tap, through synthesis, until the
  /// audio runs out or the user pauses.
  func isSounding(_ id: UUID) -> Bool { isActive(id) && !isPaused(id) }

  /// Play a raw wav file (used to preview enrollment recordings).
  func playWav(url: URL) {
    queue.async { [weak self] in
      guard let self else { return }
      let wave = SherpaOnnxWaveWrapper.readWave(filename: url.path)
      guard wave.wave != nil, wave.numSamples > 0 else { return }
      self.player.play(samples: wave.samples, sampleRate: wave.sampleRate)
    }
  }

  // MARK: - Private state

  private func isCurrent(_ generation: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == epoch
  }

  /// `count` chunks left the pipeline, whether they were played or abandoned.
  private func dropChunks(_ count: Int, generation: Int) {
    lock.lock()
    if generation == epoch { pendingChunks = max(0, pendingChunks - count) }
    lock.unlock()
  }

  /// Applied immediately when the caller is already on the main thread. A tap
  /// has to see its own state change before the next tap reads it, or a quick
  /// second tap finds `.idle` and restarts instead of pausing.
  private func publish(_ state: Playback) {
    if Thread.isMainThread {
      playback = state
    } else {
      DispatchQueue.main.async { self.playback = state }
    }
  }

  /// The first audio for `id` is scheduled. A pause the user asked for while
  /// we were still synthesizing wins, and so does a newer utterance.
  private func markPlaying(_ id: UUID) {
    DispatchQueue.main.async {
      if self.playback == .preparing(id) { self.playback = .playing(id) }
    }
  }

  private func publishIdle(for id: UUID) {
    DispatchQueue.main.async {
      if self.playback.id == id { self.playback = .idle }
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

  // MARK: - Chunking

  /// Time-to-first-sound is what makes playback feel immediate, so the opening
  /// chunk is deliberately short. Later chunks are longer: the queue is
  /// already running by then, and prosody is better with more context.
  private static let firstChunkCharacters = 120
  private static let chunkCharacters = 260

  /// Splits text into synthesis-sized pieces along sentence boundaries.
  static func chunks(for text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var pending = sentences(in: text)

    while !pending.isEmpty {
      let limit = result.isEmpty ? firstChunkCharacters : chunkCharacters
      let sentence = pending.removeFirst()

      // A sentence too long to be a chunk on its own is word-wrapped at
      // whatever limit is in force right now, so one runaway sentence can
      // neither stall the queue nor bloat the opening chunk.
      if sentence.count > limit,
        let (head, tail) = splitAtWordBoundary(sentence, limit: limit)
      {
        pending.insert(contentsOf: [head, tail], at: 0)
        continue
      }

      if current.isEmpty {
        current = sentence
      } else if current.count + 1 + sentence.count <= limit {
        current += " " + sentence
      } else {
        result.append(current)
        current = sentence
      }
      if current.count >= limit {
        result.append(current)
        current = ""
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  /// Sentence-ish split: a terminator followed by a space, plus every line
  /// break (summaries arrive as markdown, so bullets are their own lines).
  /// "Dr. Smith" splitting early costs a small pause and nothing else.
  private static func sentences(in text: String) -> [String] {
    var result: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      var current = ""
      var previous: Character?
      for character in line {
        if let previous, ".!?".contains(previous), character == " ", current.count > 1 {
          result.append(current.trimmingCharacters(in: .whitespaces))
          current = ""
        }
        current.append(character)
        previous = character
      }
      let tail = current.trimmingCharacters(in: .whitespaces)
      if !tail.isEmpty { result.append(tail) }
    }
    return result
  }

  /// The longest prefix of `text` that fits `limit`, and the rest. Nil when
  /// there is no word boundary to split on (a single overlong word).
  private static func splitAtWordBoundary(_ text: String, limit: Int) -> (String, String)? {
    var head = ""
    var tail: [Substring] = []
    for word in text.split(separator: " ") {
      if tail.isEmpty, head.isEmpty || head.count + 1 + word.count <= limit {
        head += head.isEmpty ? String(word) : " " + word
      } else {
        tail.append(word)
      }
    }
    guard !head.isEmpty, !tail.isEmpty else { return nil }
    return (head, tail.joined(separator: " "))
  }
}
