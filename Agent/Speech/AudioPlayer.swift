import AVFoundation

/// Plays raw Float32 PCM buffers. Buffers scheduled while another is playing
/// are queued and played back-to-back, which is what we want both when
/// echoing consecutive utterances and when a long summary is synthesized a
/// sentence at a time so the first sentence can start playing immediately.
///
/// Supports pause/resume so the UI can offer a real transport control rather
/// than a fire-and-forget play button.
final class AudioPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()

  private let lock = NSLock()
  private var connectedSampleRate: Double?
  private var queuedBuffers = 0
  /// Bumped whenever the queue is thrown away, so completion handlers for
  /// flushed buffers can tell they are stale.
  private var epoch = 0
  private var paused = false

  /// Called on the main queue once everything scheduled has finished playing,
  /// or once it becomes certain that it never will.
  var onQueueDrained: (() -> Void)?

  init() {
    engine.attach(node)
    NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
  }

  /// Bring the session and engine up before there is anything to play.
  /// Activating an audio session and starting the engine costs real time;
  /// spending it while the first chunk is still being synthesized keeps it
  /// off the path between the tap and the first sound.
  func prepare(sampleRate: Int) {
    guard let format = Self.format(for: Double(sampleRate)) else { return }
    try? AudioSession.activateForPlayback()
    connect(format)
    startEngineIfNeeded()
  }

  func play(samples: [Float], sampleRate: Int) {
    guard !samples.isEmpty else { return }
    guard
      let format = Self.format(for: Double(sampleRate)),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
      buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }

    try? AudioSession.activateForPlayback()
    connect(format)
    guard startEngineIfNeeded() else {
      // Nothing will play and no completion handler is coming, so release the
      // transport instead of leaving it waiting on a drain that cannot arrive.
      notifyDrained()
      return
    }

    lock.lock()
    let generation = epoch
    queuedBuffers += 1
    let isPaused = paused
    lock.unlock()

    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      self?.bufferFinished(generation)
    }
    // A buffer arriving while the user has us paused stays queued until they
    // resume — it must not restart playback on its own.
    if !isPaused && !node.isPlaying {
      node.play()
    }
  }

  func pause() {
    lock.lock()
    paused = true
    lock.unlock()
    node.pause()
  }

  func resume() {
    lock.lock()
    let wasPaused = paused
    paused = false
    lock.unlock()
    guard wasPaused else { return }
    try? AudioSession.activateForPlayback()
    guard startEngineIfNeeded() else {
      notifyDrained()
      return
    }
    node.play()
  }

  /// Drops everything queued. Buffers already handed to the engine fire their
  /// completion handlers as they are flushed; the epoch bump makes those
  /// callbacks no-ops.
  func stop() {
    lock.lock()
    epoch &+= 1
    queuedBuffers = 0
    paused = false
    lock.unlock()
    node.stop()
  }

  // MARK: - Private

  private static func format(for sampleRate: Double) -> AVAudioFormat? {
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
  }

  /// The route or session category changed under us — switching between
  /// `.playback` and `.playAndRecord` is enough to do it — and AVAudioEngine
  /// stops itself when that happens. Buffers already scheduled are gone and
  /// their completion handlers will never arrive, so drop the accounting and
  /// tell the transport; otherwise it waits forever for a drain that cannot
  /// come. The next `play()` rebuilds the connection and keeps going.
  private func handleConfigurationChange() {
    lock.lock()
    let lostAudio = queuedBuffers > 0
    epoch &+= 1
    queuedBuffers = 0
    connectedSampleRate = nil
    lock.unlock()

    if lostAudio { notifyDrained() }
  }

  private func connect(_ format: AVAudioFormat) {
    lock.lock()
    let needsConnect = connectedSampleRate != format.sampleRate
    if needsConnect {
      epoch &+= 1
      queuedBuffers = 0
      connectedSampleRate = format.sampleRate
    }
    lock.unlock()
    guard needsConnect else { return }

    node.stop()
    engine.stop()
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  /// False when the engine could not be started — the session was denied, or
  /// another app holds the route. Callers must not assume audio will play.
  @discardableResult
  private func startEngineIfNeeded() -> Bool {
    if engine.isRunning { return true }
    engine.prepare()
    do {
      try engine.start()
      return true
    } catch {
      return false
    }
  }

  private func bufferFinished(_ generation: Int) {
    lock.lock()
    guard generation == epoch else {
      lock.unlock()
      return
    }
    queuedBuffers = max(0, queuedBuffers - 1)
    let drained = queuedBuffers == 0
    lock.unlock()

    if drained { notifyDrained() }
  }

  private func notifyDrained() {
    DispatchQueue.main.async { [weak self] in self?.onQueueDrained?() }
  }
}
