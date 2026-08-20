import Foundation

/// Keyless search via DuckDuckGo's no-JavaScript HTML endpoint.
///
/// There is no official free search API, so this parses the same HTML a
/// browser would get. That's inherently brittle — markup changes break it —
/// which is why the parse is forgiving (it accepts the classes used by both
/// the `html.` and `lite.` front ends) and why there's a fallback to the
/// Instant Answer API, which is a real API but only covers topics with an
/// encyclopedia-style entry.
struct DuckDuckGoSearch: WebSearchProvider {
  let name = "DuckDuckGo"

  private static let endpoint = URL(string: "https://html.duckduckgo.com/html/")!
  private static let instantAnswers = "https://api.duckduckgo.com/"

  func search(_ query: String, limit: Int) async throws -> [WebResult] {
    let results = try await htmlSearch(query, limit: limit)
    if !results.isEmpty { return results }
    return try await instantAnswerSearch(query, limit: limit)
  }

  // MARK: - HTML front end

  private func htmlSearch(_ query: String, limit: Int) async throws -> [WebResult] {
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
    var form = URLComponents()
    // `kl=wt-wt` = no regional bias; `kd=-1` disables redirect interstitials.
    form.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "kl", value: "wt-wt"),
      URLQueryItem(name: "kd", value: "-1"),
    ]
    request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

    let (data, response) = try await WebClient.session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw WebSearchError.badResponse(status: http.statusCode)
    }
    guard let html = String(data: data, encoding: .utf8) else { return [] }
    return Self.parse(html: html, limit: limit)
  }

  /// Pulls result links and snippets out of the results page and pairs them
  /// up by document order.
  static func parse(html: String, limit: Int) -> [WebResult] {
    let links = HTMLText.matches(
      #"(?is)<a\b([^>]*class="[^"]*result(?:__a|-link)[^"]*"[^>]*)>(.*?)</a>"#, in: html)
    let snippets = HTMLText.matches(
      #"(?is)<(?:a|div|td)\b[^>]*class="[^"]*result(?:__snippet|-snippet)[^"]*"[^>]*>(.*?)</(?:a|div|td)>"#,
      in: html)

    var results: [WebResult] = []
    var seenHosts: Set<String> = []
    for (offset, link) in links.enumerated() {
      guard results.count < limit else { break }
      guard let href = attribute("href", in: link.groups[0]),
        let url = resolve(href)
      else { continue }
      let title = HTMLText.inlineText(from: link.groups[1])
      guard !title.isEmpty else { continue }

      // One hit per site keeps a single domain from crowding out the rest.
      let host = url.host() ?? url.absoluteString
      guard seenHosts.insert(host).inserted else { continue }

      // The snippet that follows this link in the document, if any.
      let snippetHTML =
        snippets.first { $0.start > link.start }?.groups[0]
        ?? (offset < snippets.count ? snippets[offset].groups[0] : nil)
      let snippet = snippetHTML.map { HTMLText.inlineText(from: $0) } ?? ""

      results.append(WebResult(title: title, url: url, snippet: snippet))
    }
    return results
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    let matches = HTMLText.matches(#"(?i)\#(name)="([^"]*)""#, in: tag)
    return matches.first?.groups.first
  }

  /// Turns an href from the results page into a real URL, unwrapping
  /// DuckDuckGo's `/l/?uddg=` redirect and dropping ad links.
  private static func resolve(_ href: String) -> URL? {
    var raw = HTMLText.decodeEntities(href)
    if raw.hasPrefix("//") { raw = "https:" + raw }

    guard let components = URLComponents(string: raw) else { return nil }
    if let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
      let url = URL(string: target)
    {
      return url
    }
    guard let url = components.url, let scheme = url.scheme,
      scheme == "https" || scheme == "http",
      let host = url.host(), !host.contains("duckduckgo.com")
    else { return nil }
    return url
  }

  // MARK: - Instant Answer fallback

  /// DuckDuckGo's supported JSON API. Narrow (it only answers for topics with
  /// an entry) but stable, so it's worth trying when the scrape comes up dry.
  private func instantAnswerSearch(_ query: String, limit: Int) async throws -> [WebResult] {
    var components = URLComponents(string: Self.instantAnswers)!
    components.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "no_html", value: "1"),
      URLQueryItem(name: "no_redirect", value: "1"),
      URLQueryItem(name: "t", value: "agent-ios"),
    ]
    guard let url = components.url else { return [] }
    let (data, _) = try await WebClient.session.data(from: url)
    guard let payload = try? JSONDecoder().decode(InstantAnswer.self, from: data) else { return [] }

    var results: [WebResult] = []
    if let text = payload.abstractText, !text.isEmpty,
      let source = payload.abstractURL, let url = URL(string: source)
    {
      results.append(
        WebResult(title: payload.heading ?? query, url: url, snippet: text))
    }
    for topic in payload.relatedTopics ?? [] {
      guard results.count < limit else { break }
      guard let text = topic.text, let link = topic.firstURL, let url = URL(string: link)
      else { continue }
      results.append(
        WebResult(
          title: text.components(separatedBy: " - ").first ?? text, url: url, snippet: text))
    }
    return results
  }

  private struct InstantAnswer: Decodable {
    let heading: String?
    let abstractText: String?
    let abstractURL: String?
    let relatedTopics: [Topic]?

    struct Topic: Decodable {
      let text: String?
      let firstURL: String?

      enum CodingKeys: String, CodingKey {
        case text = "Text"
        case firstURL = "FirstURL"
      }
    }

    enum CodingKeys: String, CodingKey {
      case heading = "Heading"
      case abstractText = "AbstractText"
      case abstractURL = "AbstractURL"
      case relatedTopics = "RelatedTopics"
    }
  }
}
