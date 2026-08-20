import SwiftUI
import SwiftData

@main
struct AgentApp: App {
  @StateObject private var stt = SttEngine()
  @StateObject private var tts = TtsEngine()
  @StateObject private var voices = VoiceProfileStore()
  @Environment(\.scenePhase) private var scenePhase

  private let container: ModelContainer

  init() {
    container = try! ModelContainer(for: AgentJob.self)
    // BGTaskScheduler requires registration before launch completes.
    AgentRunner.shared.configure(container: container)
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(stt)
        .environmentObject(tts)
        .environmentObject(voices)
        .task {
          // The ZipVoice model is ~250 MB of ONNX graphs; start warming it
          // up as soon as the app launches so playback is ready sooner.
          tts.loadIfNeeded()
        }
    }
    .modelContainer(container)
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        // Queued agents run immediately while the app is open.
        AgentRunner.shared.runQueuedJobsSoon()
      case .background:
        // And get a background slot for anything still pending.
        AgentRunner.shared.scheduleBackgroundRun()
      default:
        break
      }
    }
  }
}
