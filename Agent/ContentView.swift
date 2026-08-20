import SwiftUI

struct ContentView: View {
  var body: some View {
    AgentsView()
  }
}

#Preview {
  ContentView()
    .environmentObject(SttEngine())
    .environmentObject(TtsEngine())
    .environmentObject(VoiceProfileStore())
}
