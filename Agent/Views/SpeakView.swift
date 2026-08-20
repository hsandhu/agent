import SwiftUI

/// Type text, hear it in the selected cloned voice — the receiving end of the
/// future text-based voice call.
struct SpeakView: View {
  @EnvironmentObject var tts: TtsEngine
  @EnvironmentObject var voices: VoiceProfileStore

  @State private var text = "Hello! This voice was cloned and synthesized entirely on this device."
  @FocusState private var editing: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 6) {
          SectionLabel("Text")
          Card {
            TextEditor(text: $text)
              .font(.callout)
              .scrollContentBackground(.hidden)
              .frame(minHeight: 120)
              .focused($editing)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          SectionLabel("Voice")
          RowGroup {
            ForEach(Array(voices.profiles.enumerated()), id: \.element.id) { index, profile in
              SelectionRow(
                title: profile.name,
                isSelected: voices.selectedID == profile.id,
                select: { voices.selectedID = profile.id }
              ) {
                EmptyView()
              }
              if index < voices.profiles.count - 1 {
                RowDivider(leading: 28)
              }
            }
          }
        }

        VStack(spacing: 10) {
          PillButton(
            title: tts.isSynthesizing ? "Synthesizing…" : "Speak",
            systemImage: "play.fill",
            isLoading: tts.isSynthesizing
          ) {
            editing = false
            tts.speak(text: text, profile: voices.selected)
          }
          .disabled(
            tts.loadState != .ready || tts.isSynthesizing
              || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          PillButton(title: "Stop Playback", systemImage: "stop.fill", kind: .secondary) {
            tts.stopPlayback()
          }
        }

        statusFooter
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .navigationTitle("Speak Text")
    .navigationBarTitleDisplayMode(.inline)
    .scrollDismissesKeyboard(.interactively)
  }

  @ViewBuilder private var statusFooter: some View {
    switch tts.loadState {
    case .loading, .idle:
      HStack(spacing: 8) {
        ProgressView().controlSize(.mini)
        Text("Loading the ZipVoice model…")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
    case .failed(let message):
      HStack(spacing: 7) {
        StatusDot(color: .red, size: 7)
        Text(message)
      }
      .font(.footnote)
      .foregroundStyle(.red)
    case .ready:
      if let stats = tts.lastStats {
        Text(stats)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}
