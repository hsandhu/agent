/// Zero-shot (voice cloning) TTS support for ZipVoice.
///
/// The upstream `SherpaOnnx.swift` wrapper does not yet expose
/// `SherpaOnnxOfflineTtsGenerateWithZipvoice`, so we add it here.

import Foundation

extension SherpaOnnxOfflineTtsWrapper {
  /// Synthesize `text` in the voice of the speaker heard in `promptSamples`.
  ///
  /// - Parameters:
  ///   - text: The text to speak.
  ///   - promptText: Transcription of the prompt audio.
  ///   - promptSamples: Reference (enrollment) audio, normalized to [-1, 1].
  ///   - promptSampleRate: Sample rate of `promptSamples`.
  ///   - speed: >1 speaks faster, <1 slower.
  ///   - numSteps: Flow-matching steps; 4 is the recommended value for the
  ///     distilled ZipVoice model (more steps = higher quality, slower).
  func generateZeroShot(
    text: String,
    promptText: String,
    promptSamples: [Float],
    promptSampleRate: Int,
    speed: Float = 1.0,
    numSteps: Int = 4
  ) -> SherpaOnnxGeneratedAudioWrapper {
    let audio = promptSamples.withUnsafeBufferPointer { buf in
      SherpaOnnxOfflineTtsGenerateWithZipvoice(
        tts,
        toCPointer(text),
        toCPointer(promptText),
        buf.baseAddress,
        Int32(promptSamples.count),
        Int32(promptSampleRate),
        speed,
        Int32(numSteps)
      )
    }
    return SherpaOnnxGeneratedAudioWrapper(audio: audio)
  }
}
