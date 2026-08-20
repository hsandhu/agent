import SwiftUI

/// Observable wrapper over `WebSearchConfig` for the settings screen. Every
/// edit writes straight through to `UserDefaults`/keychain so the background
/// runner — which reads `WebSearchConfig.current` from its own executor —
/// always sees the latest preferences.
@MainActor
final class WebSearchSettings: ObservableObject {
  @Published var config: WebSearchConfig {
    didSet { config.save() }
  }

  init() {
    config = .current
  }
}

/// Settings › Web research: the switch that lets agents leave the device.
struct WebSearchView: View {
  @StateObject private var settings = WebSearchSettings()
  @State private var testState = TestState.idle

  private enum TestState: Equatable {
    case idle
    case running
    case success([WebResult])
    case failure(String)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 6) {
          SectionLabel("Web research")
          RowGroup {
            Toggle(isOn: enabledBinding) {
              Text("Search the web")
            }
            .padding(.vertical, 10)
          }
          Text(
            "When on, an agent searches the web and reads a few pages before the on-device model writes its findings. Your task text is sent to the search provider; results are processed on this device."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        if settings.config.isEnabled {
          providerSection
          if settings.config.provider == .brave {
            apiKeySection
          }
          depthSection
          testSection
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 32)
    }
    .navigationTitle("Web Research")
    .navigationBarTitleDisplayMode(.inline)
    .animation(.default, value: settings.config.isEnabled)
    .animation(.default, value: settings.config.provider)
  }

  // MARK: - Sections

  private var providerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionLabel("Provider")
      RowGroup {
        ForEach(Array(WebSearchConfig.Provider.allCases.enumerated()), id: \.element.id) {
          index, provider in
          if index > 0 { RowDivider(leading: 28) }
          SelectionRow(
            title: provider.displayName,
            subtitle: provider.blurb,
            isSelected: settings.config.provider == provider,
            select: {
              settings.config.provider = provider
              testState = .idle
            }
          ) {
            EmptyView()
          }
        }
      }
    }
  }

  private var apiKeySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionLabel("Brave API key")
      RowGroup {
        SecureField("Subscription token", text: apiKeyBinding)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .padding(.vertical, 13)
      }
      Text(
        "Free keys come from brave.com/search/api. Stored in this device's keychain, never in a backup of the app's settings."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private var depthSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionLabel("Depth")
      RowGroup {
        stepperRow(
          "Searches per task", value: bind(\.maxQueries), range: 1...5)
        RowDivider()
        stepperRow(
          "Results per search", value: bind(\.maxResultsPerQuery), range: 3...10)
        RowDivider()
        stepperRow(
          "Pages read", value: bind(\.maxPagesToRead), range: 1...8)
      }
      Text(
        "Reading more pages gives the model more to work with, but takes longer and can overflow its context window — it trims excerpts to fit."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private var testSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      PillButton(
        title: "Test Search", systemImage: "magnifyingglass",
        kind: .secondary, isLoading: testState == .running
      ) {
        runTest()
      }
      .disabled(testState == .running || !settings.config.isUsable)

      switch testState {
      case .idle, .running:
        EmptyView()
      case .success(let results):
        VStack(alignment: .leading, spacing: 10) {
          Text("\(results.count) result\(results.count == 1 ? "" : "s") for \"\(Self.testQuery)\"")
            .font(.footnote)
            .foregroundStyle(.secondary)
          ForEach(results.prefix(3), id: \.url) { result in
            VStack(alignment: .leading, spacing: 2) {
              Text(result.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
              Text(result.url.host() ?? result.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      case .failure(let message):
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
  }

  // MARK: - Helpers

  private static let testQuery = "best hiking trails near Chicago"

  private func runTest() {
    testState = .running
    let config = settings.config
    Task {
      guard let provider = config.makeProvider() else {
        testState = .failure("This provider isn't configured yet.")
        return
      }
      do {
        let results = try await provider.search(Self.testQuery, limit: 5)
        testState = results.isEmpty
          ? .failure("The provider replied, but no results could be parsed.")
          : .success(results)
      } catch {
        testState = .failure(error.localizedDescription)
      }
    }
  }

  private func stepperRow(
    _ title: String, value: Binding<Int>, range: ClosedRange<Int>
  ) -> some View {
    Stepper(value: value, in: range) {
      HStack {
        Text(title)
        Spacer()
        Text("\(value.wrappedValue)")
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8)
  }

  private func bind(_ keyPath: WritableKeyPath<WebSearchConfig, Int>) -> Binding<Int> {
    Binding(
      get: { settings.config[keyPath: keyPath] },
      set: { settings.config[keyPath: keyPath] = $0 })
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { settings.config.isEnabled },
      set: {
        settings.config.isEnabled = $0
        testState = .idle
      })
  }

  private var apiKeyBinding: Binding<String> {
    Binding(
      get: { settings.config.braveAPIKey },
      set: {
        settings.config.braveAPIKey = $0
        testState = .idle
      })
  }
}

#Preview {
  NavigationStack {
    WebSearchView()
  }
}
