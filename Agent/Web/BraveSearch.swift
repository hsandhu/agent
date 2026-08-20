import Foundation

/// Brave's Search API — a documented JSON endpoint, so it doesn't rot the way
/// HTML scraping does. Requires a (free-tier) subscription token, entered in
/// Settings and stored in the keychain.
struct BraveSearch: WebSearchProvider {
  let name = "Brave Search"
  let apiKey: String

  private static let endpoint = "https://api.search.brave.com/res/v1/web/search"

  func search(_ query: String, limit: Int) async throws -> [WebResult] {
    guard !apiKey.isEmpty else { throw WebSearchError.missingAPIKey(name) }

    var components = URLComponents(string: Self.endpoint)!
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "count", value: String(min(limit, 20))),
      URLQueryItem(name: "safesearch", value: "moderate"),
      URLQueryItem(name: "text_decorations", value: "false"),
    ]
    guard let url = components.url else { return [] }

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

    let (data, response) = try await WebClient.session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw WebSearchError.badResponse(status: http.statusCode)
    }
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    return (payload.web?.results ?? []).prefix(limit).compactMap { hit in
      guard let url = URL(string: hit.url) else { return nil }
      return WebResult(
        title: HTMLText.inlineText(from: hit.title),
        url: url,
        snippet: HTMLText.inlineText(from: hit.description ?? ""))
    }
  }

  private struct Payload: Decodable {
    let web: Web?

    struct Web: Decodable {
      let results: [Hit]
    }

    struct Hit: Decodable {
      let title: String
      let url: String
      let description: String?
    }
  }
}
