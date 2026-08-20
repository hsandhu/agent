import Foundation
import Combine

/// A reference voice for zero-shot TTS: a short audio sample plus its
/// transcript. This pair is all ZipVoice needs to clone a speaker.
struct VoiceProfile: Identifiable, Hashable {
  let id: String
  let name: String
  let wavURL: URL
  let transcript: String
}

/// Owns the built-in demo voice and the user's enrolled voice
/// (stored in Documents/voice-profile/).
final class VoiceProfileStore: ObservableObject {
  @Published private(set) var userProfile: VoiceProfile?
  @Published var selectedID: String = "demo"

  static let enrollmentPrompt =
    "The quick brown fox jumps over the lazy dog. I am recording this short sample so this app can learn what my voice sounds like."

  let demo = VoiceProfile(
    id: "demo",
    name: "Demo voice",
    wavURL: ModelPaths.demoVoiceWav,
    transcript: (try? String(contentsOf: ModelPaths.demoVoiceTranscript, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "After early nightfall the yellow lamps would light up here and there the squalid quarter of the brothels."
  )

  var profiles: [VoiceProfile] {
    if let userProfile { return [userProfile, demo] }
    return [demo]
  }

  var selected: VoiceProfile {
    profiles.first { $0.id == selectedID } ?? demo
  }

  init() {
    loadUserProfile()
    if userProfile != nil { selectedID = "user" }
  }

  func saveUserProfile(samples: [Float], sampleRate: Int) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)

    // A fresh filename each time keeps TtsEngine's prompt cache correct.
    let wavName = "reference-\(Int(Date().timeIntervalSince1970)).wav"
    let wavURL = directory.appendingPathComponent(wavName)

    let ok = samples.withUnsafeBufferPointer { buf in
      SherpaOnnxWriteWave(buf.baseAddress, Int32(samples.count), Int32(sampleRate), toCPointer(wavURL.path))
    }
    guard ok == 1 else {
      throw NSError(
        domain: "VoiceProfileStore", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not write the recording to disk."])
    }

    // Drop older recordings.
    if let old = userProfile?.wavURL, old != wavURL {
      try? fm.removeItem(at: old)
    }

    let meta = Meta(wavName: wavName, transcript: Self.enrollmentPrompt)
    try JSONEncoder().encode(meta).write(to: metaURL)

    userProfile = VoiceProfile(
      id: "user", name: "My voice", wavURL: wavURL, transcript: meta.transcript)
    selectedID = "user"
  }

  // MARK: - Private

  private struct Meta: Codable {
    let wavName: String
    let transcript: String
  }

  private var directory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("voice-profile", isDirectory: true)
  }

  private var metaURL: URL { directory.appendingPathComponent("profile.json") }

  private func loadUserProfile() {
    guard
      let data = try? Data(contentsOf: metaURL),
      let meta = try? JSONDecoder().decode(Meta.self, from: data)
    else { return }
    let wavURL = directory.appendingPathComponent(meta.wavName)
    guard FileManager.default.fileExists(atPath: wavURL.path) else { return }
    userProfile = VoiceProfile(
      id: "user", name: "My voice", wavURL: wavURL, transcript: meta.transcript)
  }
}

/// Records the enrollment sample (16 kHz mono) and reports live level/duration.
final class EnrollRecorder: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var level: Float = 0

  private let capture = AudioCapture()
  private let queue = DispatchQueue(label: "com.robsandhu.agent.enroll")
  private var samples: [Float] = []

  func start() throws {
    guard !isRecording else { return }
    queue.sync { samples.removeAll() }
    capture.onSamples = { [weak self] chunk in
      guard let self else { return }
      self.queue.async {
        self.samples.append(contentsOf: chunk)
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
        let seconds = Double(self.samples.count) / AudioCapture.targetSampleRate
        DispatchQueue.main.async {
          self.level = min(1, rms * 8)
          self.duration = seconds
        }
      }
    }
    try capture.start()
    isRecording = true
  }

  /// Stops the recording and returns the captured 16 kHz samples.
  func stop() -> [Float] {
    capture.stop()
    isRecording = false
    var captured: [Float] = []
    queue.sync { captured = self.samples }
    return captured
  }
}
