import SwiftUI

/// Voice enrollment: record ~10 seconds reading the prompt sentence.
/// The recording + prompt text become the ZipVoice reference profile.
struct VoiceView: View {
  @EnvironmentObject var voices: VoiceProfileStore
  @EnvironmentObject var stt: SttEngine
  @EnvironmentObject var tts: TtsEngine
  @StateObject private var recorder = EnrollRecorder()

  @State private var errorMessage: String?
  @State private var micDenied = false

  private let minSeconds: TimeInterval = 3
  private let maxSeconds: TimeInterval = 20

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        voicePicker
        enrollment

        Text(
          "Your recording never leaves this device. It is used only as the reference sample for on-device speech synthesis."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .navigationTitle("My Voice")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Microphone access is required", isPresented: $micDenied) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access for Agent in Settings to record your voice.")
    }
    .onChange(of: recorder.duration) {
      if recorder.isRecording && recorder.duration >= maxSeconds {
        finishRecording()
      }
    }
    .onDisappear {
      // Leaving mid-recording would otherwise keep the mic engine running.
      if recorder.isRecording { _ = recorder.stop() }
    }
  }

  // MARK: Voice selection

  private var voicePicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionLabel("Active voice")
      RowGroup {
        ForEach(Array(voices.profiles.enumerated()), id: \.element.id) { index, profile in
          SelectionRow(
            title: profile.name,
            subtitle: profile.id == "user" ? "Recorded on this device" : "Built-in sample",
            isSelected: voices.selectedID == profile.id,
            select: { voices.selectedID = profile.id }
          ) {
            Button {
              tts.playWav(url: profile.wavURL)
            } label: {
              Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play \(profile.name) reference audio")
          }
          if index < voices.profiles.count - 1 {
            RowDivider(leading: 28)
          }
        }
      }
    }
  }

  // MARK: Enrollment

  private var enrollment: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionLabel(voices.userProfile == nil ? "Enroll my voice" : "Re-record my voice")

      Text("Read this sentence aloud, naturally:")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Card {
        Text(VoiceProfileStore.enrollmentPrompt)
          .font(.callout)
      }

      if recorder.isRecording {
        Card {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              HStack(spacing: 7) {
                StatusDot(color: .red)
                Text("Recording")
                  .font(.subheadline.weight(.medium))
              }
              Spacer()
              Text(String(format: "%.1fs", recorder.duration))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            LevelMeter(level: recorder.level)
            Text(
              recorder.duration < minSeconds
                ? "Keep going — at least \(Int(minSeconds)) seconds needed."
                : "Long enough. Stop whenever you're ready."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        PillButton(
          title: "Stop & Save", systemImage: "stop.fill", kind: .destructive,
          action: finishRecording
        )
        .disabled(recorder.duration < minSeconds)
      } else {
        PillButton(
          title: voices.userProfile == nil ? "Start Recording" : "Record Again",
          systemImage: "mic.fill", action: startRecording)

        if voices.userProfile != nil {
          HStack(spacing: 7) {
            Image(systemName: "checkmark")
              .font(.subheadline.weight(.bold))
              .foregroundStyle(.green)
            Text("Your voice is enrolled and ready to use.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let error = errorMessage {
        Text(error)
          .font(.subheadline)
          .foregroundStyle(.red)
      }
    }
  }

  // MARK: Actions

  private func startRecording() {
    errorMessage = nil
    if stt.isRunning { stt.stop() }  // only one capture session at a time
    Task {
      guard await AudioCapture.requestPermission() else {
        micDenied = true
        return
      }
      do {
        try recorder.start()
      } catch {
        errorMessage = "Could not start recording: \(error.localizedDescription)"
      }
    }
  }

  private func finishRecording() {
    let samples = recorder.stop()
    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
    guard seconds >= minSeconds else {
      errorMessage = String(
        format: "Recording was too short (%.1fs). Please record at least %.0f seconds.",
        seconds, minSeconds)
      return
    }
    // Cloning from silence yields an unusable voice, so reject a recording
    // that never picked up real speech (mic muted, covered, or wrong input).
    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
    guard peak >= 0.02 else {
      errorMessage =
        "That recording was almost silent. Check your microphone and read the sentence aloud."
      return
    }
    do {
      try voices.saveUserProfile(samples: samples, sampleRate: Int(AudioCapture.targetSampleRate))
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct LevelMeter: View {
  let level: Float

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color(.systemGray4))
        Capsule()
          .fill(level > 0.85 ? Color.red : Color.primary)
          .frame(width: geo.size.width * CGFloat(min(max(level, 0.02), 1)))
          .animation(.linear(duration: 0.1), value: level)
      }
    }
    .frame(height: 6)
  }
}
