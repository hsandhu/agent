import Foundation
import Security

/// A single search hit, before any page content has been fetched.
struct WebResult: Sendable, Hashable {
  let title: String
  let url: URL
  let snippet: String
}

/// One source the agent actually read, as persisted alongside the job and
/// cited in the findings. `index` is the citation number ([1], [2], …).
struct WebSource: Codable, Sendable, Hashable, Identifiable {
  let index: Int
  let title: String
  let urlString: String
  /// Plain-text excerpt pulled from the page (empty if only the search
  /// snippet was available).
  let excerpt: String

  var id: Int { index }
  var url: URL? { URL(string: urlString) }

  /// "example.com" — what the UI shows under the title.
  var host: String {
    guard let host = url?.host() else { return urlString }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

/// A search backend. Swappable so a keyless scrape, a keyed API, or a stub
/// can all feed the same research pipeline.
protocol WebSearchProvider: Sendable {
  var name: String { get }
  func search(_ query: String, limit: Int) async throws -> [WebResult]
}

enum WebSearchError: LocalizedError {
  case missingAPIKey(String)
  case badResponse(status: Int)
  case noResults
  case notHTML

  var errorDescription: String? {
    switch self {
    case .missingAPIKey(let provider):
      return "\(provider) needs an API key. Add one in Settings › Web research."
    case .badResponse(let status):
      return "The search service returned HTTP \(status)."
    case .noResults:
      return "The search returned no usable results."
    case .notHTML:
      return "That page isn't readable text."
    }
  }
}

// MARK: - Shared networking

enum WebClient {
  /// A desktop-browser UA. Both the DuckDuckGo HTML endpoint and many content
  /// sites serve a block page or an empty shell to the default
  /// `Agent/1.0 CFNetwork/...` string.
  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 25
    config.httpAdditionalHeaders = ["User-Agent": userAgent]
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()
}

// MARK: - Configuration

/// Immutable snapshot of the user's web-research preferences. Read straight
/// from `UserDefaults` (thread-safe) so the background runner doesn't have to
/// hop to the main actor to find out whether search is on.
struct WebSearchConfig: Sendable, Equatable {
  enum Provider: String, CaseIterable, Sendable, Identifiable {
    case duckDuckGo
    case brave

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .duckDuckGo: return "DuckDuckGo"
      case .brave: return "Brave Search API"
      }
    }

    var blurb: String {
      switch self {
      case .duckDuckGo: return "No account or key needed"
      case .brave: return "Needs a free API key"
      }
    }
  }

  var isEnabled: Bool
  var provider: Provider
  var braveAPIKey: String
  /// Search queries the agent may issue per task.
  var maxQueries: Int
  /// Hits kept per query.
  var maxResultsPerQuery: Int
  /// Pages actually downloaded and read (the expensive part).
  var maxPagesToRead: Int

  static let `default` = WebSearchConfig(
    isEnabled: true,
    provider: .duckDuckGo,
    braveAPIKey: "",
    maxQueries: 3,
    maxResultsPerQuery: 6,
    maxPagesToRead: 4)

  private enum Key {
    static let enabled = "websearch.enabled"
    static let provider = "websearch.provider"
    static let maxQueries = "websearch.maxQueries"
    static let maxResults = "websearch.maxResultsPerQuery"
    static let maxPages = "websearch.maxPagesToRead"
  }

  /// Current preferences. Safe to read from any thread.
  static var current: WebSearchConfig {
    let defaults = UserDefaults.standard
    var config = WebSearchConfig.default
    if defaults.object(forKey: Key.enabled) != nil {
      config.isEnabled = defaults.bool(forKey: Key.enabled)
    }
    if let raw = defaults.string(forKey: Key.provider),
      let provider = Provider(rawValue: raw)
    {
      config.provider = provider
    }
    config.braveAPIKey = Keychain.string(for: Keychain.braveAPIKey) ?? ""
    if let queries = defaults.object(forKey: Key.maxQueries) as? Int, queries > 0 {
      config.maxQueries = queries
    }
    if let results = defaults.object(forKey: Key.maxResults) as? Int, results > 0 {
      config.maxResultsPerQuery = results
    }
    if let pages = defaults.object(forKey: Key.maxPages) as? Int, pages > 0 {
      config.maxPagesToRead = pages
    }
    return config
  }

  func save() {
    let defaults = UserDefaults.standard
    defaults.set(isEnabled, forKey: Key.enabled)
    defaults.set(provider.rawValue, forKey: Key.provider)
    defaults.set(maxQueries, forKey: Key.maxQueries)
    defaults.set(maxResultsPerQuery, forKey: Key.maxResults)
    defaults.set(maxPagesToRead, forKey: Key.maxPages)
    Keychain.set(braveAPIKey.isEmpty ? nil : braveAPIKey, for: Keychain.braveAPIKey)
  }

  /// Whether the chosen provider has everything it needs to run.
  var isUsable: Bool {
    guard isEnabled else { return false }
    switch provider {
    case .duckDuckGo: return true
    case .brave: return !braveAPIKey.isEmpty
    }
  }

  /// Builds the backing provider, or nil when search is off/unconfigured.
  func makeProvider() -> WebSearchProvider? {
    guard isUsable else { return nil }
    switch provider {
    case .duckDuckGo: return DuckDuckGoSearch()
    case .brave: return BraveSearch(apiKey: braveAPIKey)
    }
  }

  /// The researcher the agent brains use, or nil when search is off.
  func makeResearcher() -> WebResearcher? {
    guard let provider = makeProvider() else { return nil }
    return WebResearcher(provider: provider, config: self)
  }
}

// MARK: - Keychain (the Brave key is a secret; UserDefaults isn't the place)

enum Keychain {
  static let braveAPIKey = "com.robsandhu.Agent.brave-api-key"

  static func string(for account: String) -> String? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func set(_ value: String?, for account: String) {
    let query = baseQuery(account)
    SecItemDelete(query as CFDictionary)
    guard let value, let data = value.data(using: .utf8) else { return }
    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(insert as CFDictionary, nil)
  }

  private static func baseQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Agent",
      kSecAttrAccount as String: account,
    ]
  }
}
