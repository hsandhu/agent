import SwiftUI

/// Settings hub: the speech tools (voice training, live transcription,
/// speak-text) live here as menu entries now that Agents is the main screen.
struct SettingsView: View {
  @EnvironmentObject var tts: TtsEngine
  @EnvironmentObject var voices: VoiceProfileStore
  @State private var webSearch = WebSearchConfig.current

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 6) {
          SectionLabel("Voice & speech")
          RowGroup {
            NavigationLink {
              VoiceView()
            } label: {
              SettingsRow(
                icon: "person.wave.2", title: "My Voice",
                detail: voices.userProfile == nil ? "Not enrolled" : "Enrolled",
                detailColor: voices.userProfile == nil ? .secondary : .green)
            }
            .buttonStyle(.plain)
            RowDivider(leading: 36)
            NavigationLink {
              TranscribeView()
            } label: {
              SettingsRow(icon: "waveform", title: "Live Transcription")
            }
            .buttonStyle(.plain)
            RowDivider(leading: 36)
            NavigationLink {
              SpeakView()
            } label: {
              SettingsRow(icon: "speaker.wave.2", title: "Speak Text")
            }
            .buttonStyle(.plain)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          SectionLabel("Agents")
          RowGroup {
            NavigationLink {
              WebSearchView()
            } label: {
              SettingsRow(
                icon: "globe", title: "Web Research",
                detail: webSearchDetail,
                detailColor: webSearch.isUsable ? .green : .secondary)
            }
            .buttonStyle(.plain)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          SectionLabel("On-device")
          RowGroup {
            InfoRow(title: "Active voice") {
              Text(voices.selected.name)
            }
            RowDivider()
            InfoRow(title: "Speech engine") {
              engineStatus
            }
            RowDivider()
            InfoRow(title: "Recognizer") {
              Text("Zipformer 20M")
            }
            RowDivider()
            InfoRow(title: "Synthesizer") {
              Text("ZipVoice-Distill")
            }
          }
        }

        Text(privacyNote)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .navigationTitle("Settings")
    .onAppear { webSearch = .current }
  }

  private var webSearchDetail: String {
    guard webSearch.isEnabled else { return "Off" }
    return webSearch.isUsable ? webSearch.provider.displayName : "Needs a key"
  }

  private var privacyNote: String {
    let base =
      "Speech recognition and synthesis run entirely on this device. Your voice sample never leaves it."
    guard webSearch.isUsable else { return base }
    return base
      + " Web research is on, so agents send your task text to \(webSearch.provider.displayName) and download the pages they read."
  }

  @ViewBuilder private var engineStatus: some View {
    switch tts.loadState {
    case .idle, .loading:
      HStack(spacing: 7) {
        ProgressView().controlSize(.mini)
        Text("Loading…")
      }
    case .ready:
      HStack(spacing: 7) {
        StatusDot(color: .green, size: 7)
        Text("Ready")
      }
    case .failed:
      HStack(spacing: 7) {
        StatusDot(color: .red, size: 7)
        Text("Unavailable")
      }
    }
  }
}
