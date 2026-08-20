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

    try AudioSession.activate()

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

/// One place to configure the shared audio session for simultaneous
/// record + playback.
enum AudioSession {
  static func activate() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    try session.setActive(true)
  }
}
