import Foundation

/// Locations of the bundled sherpa-onnx models.
///
/// `vendor/models` is added to the app target as a folder reference, so it is
/// copied into the bundle as a `models/` directory with its structure intact.
enum ModelPaths {
  static var models: URL {
    Bundle.main.resourceURL!.appendingPathComponent("models", isDirectory: true)
  }

  // Streaming Zipformer transducer (English, 20M params, int8).
  static var asrDir: URL {
    models.appendingPathComponent("asr-zipformer-en-20M", isDirectory: true)
  }
  static var asrEncoder: URL { asrDir.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx") }
  static var asrDecoder: URL { asrDir.appendingPathComponent("decoder-epoch-99-avg-1.onnx") }
  static var asrJoiner: URL { asrDir.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx") }
  static var asrTokens: URL { asrDir.appendingPathComponent("tokens.txt") }

  // ZipVoice-Distill (int8) + vocos vocoder.
  static var zipvoiceDir: URL {
    models.appendingPathComponent("zipvoice", isDirectory: true)
  }
  static var ttsTokens: URL { zipvoiceDir.appendingPathComponent("tokens.txt") }
  static var ttsEncoder: URL { zipvoiceDir.appendingPathComponent("encoder.int8.onnx") }
  static var ttsDecoder: URL { zipvoiceDir.appendingPathComponent("decoder.int8.onnx") }
  static var ttsVocoder: URL { zipvoiceDir.appendingPathComponent("vocos_24khz.onnx") }
  static var ttsLexicon: URL { zipvoiceDir.appendingPathComponent("lexicon.txt") }
  static var ttsEspeakData: URL { zipvoiceDir.appendingPathComponent("espeak-ng-data", isDirectory: true) }

  // Built-in reference voice (LibriSpeech sample) so TTS works before enrollment.
  static var demoVoiceWav: URL { models.appendingPathComponent("demo-voice/demo.wav") }
  static var demoVoiceTranscript: URL { models.appendingPathComponent("demo-voice/demo.txt") }
}
