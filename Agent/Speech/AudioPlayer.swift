import AVFoundation

/// Plays raw Float32 PCM buffers. Buffers scheduled while another is playing
/// are queued and played back-to-back, which is exactly what we want when
/// echoing consecutive utterances.
final class AudioPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var connectedSampleRate: Double?

  init() {
    engine.attach(node)
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

    try? AudioSession.activate()

    if connectedSampleRate != sr {
      node.stop()
      engine.stop()
      engine.connect(node, to: engine.mainMixerNode, format: format)
      connectedSampleRate = sr
    }
    if !engine.isRunning {
      try? engine.start()
    }
    node.scheduleBuffer(buffer, completionHandler: nil)
    if !node.isPlaying {
      node.play()
    }
  }

  func stop() {
    node.stop()
  }
}
