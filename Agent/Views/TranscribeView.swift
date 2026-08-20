import SwiftUI

/// Live streaming transcription with optional "echo": every finalized
/// utterance is re-synthesized in the selected cloned voice — the local
/// loopback version of the text-based voice call.
struct TranscribeView: View {
  @EnvironmentObject var stt: SttEngine
  @EnvironmentObject var tts: TtsEngine
  @EnvironmentObject var voices: VoiceProfileStore

  @State private var echo = false
  @State private var micDenied = false

  var body: some View {
    VStack(spacing: 0) {
      transcript
      controls
    }
    .navigationTitle("Live Transcription")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !stt.segments.isEmpty {
        Button("Clear") { stt.clear() }
      }
    }
    .onAppear { configureEcho() }
    .onDisappear { if stt.isRunning { stt.stop() } }
    .onChange(of: echo) { configureEcho() }
    .alert("Microphone access is required", isPresented: $micDenied) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access for Agent in Settings to transcribe speech.")
    }
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if stt.segments.isEmpty && stt.partial.isEmpty {
            VStack(spacing: 6) {
              Text("Nothing transcribed yet")
                .font(.subheadline.weight(.medium))
              Text("Start listening and talk. Each pause finalizes an utterance.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
          }

          ForEach(stt.segments) { segment in
            HStack(alignment: .top, spacing: 10) {
              Text(segment.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button {
                tts.speak(text: segment.text, profile: voices.selected)
              } label: {
                Image(systemName: "play.circle")
                  .font(.title3)
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.borderless)
              .disabled(tts.loadState != .ready)
              .accessibilityLabel("Speak this line")
            }
            .padding(14)
            .background(
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemGray6)))
            .id(segment.id)
          }

          if !stt.partial.isEmpty {
            Text(stt.partial)
              .font(.callout)
              .foregroundStyle(.blue)
              .padding(.horizontal, 14)
              .id("partial")
          }
        }
        .padding(20)
      }
      .onChange(of: stt.segments) {
        if let last = stt.segments.last {
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
      .onChange(of: stt.partial) {
        if !stt.partial.isEmpty {
          proxy.scrollTo("partial", anchor: .bottom)
        }
      }
    }
  }

  private var controls: some View {
    VStack(spacing: 14) {
      Toggle(isOn: $echo) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Echo in \(voices.selected.name.lowercased())")
            .font(.subheadline)
          Text(echoDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .disabled(tts.loadState != .ready)

      if stt.isRunning {
        PillButton(title: "Stop Listening", systemImage: "stop.fill", kind: .destructive) {
          stt.stop()
        }
      } else {
        PillButton(title: "Start Listening", systemImage: "mic.fill", action: startListening)
      }

      HStack(spacing: 7) {
        StatusDot(color: stt.isRunning ? .red : Color(.systemGray3), size: 7)
        Text(stt.status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    // A solid background, not a material: material vibrancy washes out the
    // primary-colored pill button into gray.
    .background(alignment: .top) {
      Color(.systemBackground)
        .overlay(alignment: .top) { Divider() }
        .ignoresSafeArea(edges: .bottom)
    }
  }

  private var echoDetail: String {
    if tts.isSynthesizing { return "Synthesizing…" }
    if let stats = tts.lastStats { return stats }
    return "Speak each finished line back in the cloned voice"
  }

  private func startListening() {
    Task {
      if await AudioCapture.requestPermission() {
        stt.start()
      } else {
        micDenied = true
      }
    }
  }

  private func configureEcho() {
    if echo {
      stt.onUtterance = { text in
        tts.speak(text: text, profile: voices.selected)
      }
    } else {
      stt.onUtterance = nil
    }
  }
}
