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

  /// Called on the main queue once everything scheduled has finished playing.
  var onQueueDrained: (() -> Void)?

  init() {
    engine.attach(node)
    NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      // The route or session category changed under us (headphones, or a
      // capture claim flipping us to .playAndRecord). Force a reconnect
      // before the next buffer goes in.
      guard let self else { return }
      self.lock.lock()
      self.connectedSampleRate = nil
      self.lock.unlock()
    }
  }

  /// Bring the session and engine up before there is anything to play.
  /// Activating an audio session and starting the engine costs real time;
  /// spending it while the first chunk is still being synthesized keeps it
  /// off the path between the tap and the first sound.
  func prepare(sampleRate: Int) {
    try? AudioSession.activateForPlayback()
    connect(sampleRate: Double(sampleRate))
    startEngineIfNeeded()
  }

  func play(samples: [Float], sampleRate: Int) {
    guard !samples.isEmpty else { return }
    let sr = Double(sampleRate)
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
      buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }

    try? AudioSession.activateForPlayback()
    connect(sampleRate: sr)
    startEngineIfNeeded()

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
    startEngineIfNeeded()
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

  private func connect(sampleRate sr: Double) {
    lock.lock()
    let needsConnect = connectedSampleRate != sr
    lock.unlock()
    guard needsConnect,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)
    else { return }

    lock.lock()
    epoch &+= 1
    queuedBuffers = 0
    connectedSampleRate = sr
    lock.unlock()

    node.stop()
    engine.stop()
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  private func startEngineIfNeeded() {
    guard !engine.isRunning else { return }
    engine.prepare()
    try? engine.start()
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

    guard drained else { return }
    DispatchQueue.main.async { [weak self] in self?.onQueueDrained?() }
  }
}
