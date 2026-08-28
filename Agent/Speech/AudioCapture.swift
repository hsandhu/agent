import AVFoundation

/// Captures microphone audio and delivers 16 kHz mono Float32 chunks.
///
/// The hardware format (typically 44.1/48 kHz) is converted on the fly with
/// AVAudioConverter, which is what both the streaming recognizer and the
/// enrollment recorder consume.
final class AudioCapture {
  static let targetSampleRate: Double = 16_000

  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: AudioCapture.targetSampleRate,
    channels: 1,
    interleaved: false
  )!

  /// Called on an audio thread with each converted chunk.
  var onSamples: (([Float]) -> Void)?

  private(set) var isRunning = false

  static func requestPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  func start() throws {
    guard !isRunning else { return }

    try AudioSession.beginRecording()

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    converter = AVAudioConverter(from: inputFormat, to: outputFormat)

    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.handle(buffer)
    }
    engine.prepare()
    try engine.start()
    isRunning = true
  }

  func stop() {
    guard isRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    converter = nil
    isRunning = false
    AudioSession.endRecording()
  }

  private func handle(_ buffer: AVAudioPCMBuffer) {
    guard let converter else { return }
    let ratio = AudioCapture.targetSampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

    var delivered = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if delivered {
        status.pointee = .noDataNow
        return nil
      }
      delivered = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let channel = out.floatChannelData else { return }

    let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    onSamples?(samples)
  }
}

/// One place to configure the shared audio session.
///
/// Capture needs `.playAndRecord`. Playback on its own is happier in
/// `.playback`: it routes to the speaker at full volume and the session
/// activates faster, which shows up directly as time-to-first-sound. Anything
/// capturing holds a claim, so a playback request can never downgrade the
/// category out from under a live microphone tap (the Echo loopback records
/// and plays at the same time).
enum AudioSession {
  private static let lock = NSLock()
  private static var recorders = 0
  private static var appliedCategory: AVAudioSession.Category?

  /// Claim the session for capture. Balance every call with `endRecording()`.
  static func beginRecording() throws {
    lock.lock()
    recorders += 1
    lock.unlock()
    try apply(.playAndRecord)
  }

  static func endRecording() {
    lock.lock()
    recorders = max(0, recorders - 1)
    lock.unlock()
  }

  /// Bring the session up for output, keeping `.playAndRecord` for as long as
  /// anything is capturing.
  static func activateForPlayback() throws {
    lock.lock()
    let recording = recorders > 0
    lock.unlock()
    try apply(recording ? .playAndRecord : .playback)
  }

  private static func apply(_ category: AVAudioSession.Category) throws {
    let session = AVAudioSession.sharedInstance()
    lock.lock()
    let needsCategory = appliedCategory != category
    lock.unlock()

    if needsCategory {
      try session.setCategory(
        category, mode: .default,
        options: category == .playAndRecord ? [.defaultToSpeaker] : [])
      lock.lock()
      appliedCategory = category
      lock.unlock()
    }
    try session.setActive(true)
  }
}
