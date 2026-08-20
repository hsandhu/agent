import Foundation

/// Downloads a search result and reduces it to plain text the model can read.
struct PageReader: Sendable {
  /// Hard cap on downloaded bytes per page — a runaway response shouldn't
  /// blow up a background task's memory budget.
  static let maxBytes = 1_200_000

  /// Extensions we can't turn into text, skipped before spending a request.
  private static let unreadableExtensions: Set<String> = [
    "pdf", "zip", "gz", "mp4", "mp3", "wav", "png", "jpg", "jpeg", "gif",
    "webp", "svg", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "dmg",
  ]

  static func isReadable(_ url: URL) -> Bool {
    guard let scheme = url.scheme, scheme == "https" || scheme == "http" else { return false }
    return !unreadableExtensions.contains(url.pathExtension.lowercased())
  }

  /// Fetches `url` and returns what was actually read. `finalURL` differs
  /// from the request when the server redirected — that's the URL worth
  /// citing, and the one to dedupe on.
  func read(_ url: URL) async throws -> Page {
    var request = URLRequest(url: url)
    request.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    let (data, response) = try await WebClient.session.data(for: request)
    if let http = response as? HTTPURLResponse {
      guard (200..<300).contains(http.statusCode) else {
        throw WebSearchError.badResponse(status: http.statusCode)
      }
      let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
      guard type.isEmpty || type.contains("html") || type.contains("text") || type.contains("xml")
      else { throw WebSearchError.notHTML }
    }

    let capped = data.count > Self.maxBytes ? data.prefix(Self.maxBytes) : data[...]
    guard
      let html = String(data: capped, encoding: .utf8)
        ?? String(data: capped, encoding: .isoLatin1)
    else { throw WebSearchError.notHTML }

    let title = HTMLText.title(from: html)
    let text = HTMLText.plainText(from: Self.mainContent(of: html))
    guard !text.isEmpty else { throw WebSearchError.notHTML }
    return Page(finalURL: response.url ?? url, title: title, text: text)
  }

  struct Page: Sendable {
    let finalURL: URL
    let title: String?
    let text: String
  }

  /// Narrows to `<article>` or `<main>` when the page has one — it cuts most
  /// of the nav/footer boilerplate before the tag stripper has to guess.
  private static func mainContent(of html: String) -> String {
    for tag in ["article", "main"] {
      let matches = HTMLText.matches(
        #"(?is)<\#(tag)\b[^>]*>(.*?)</\#(tag)\s*>"#, in: html)
      // Longest match wins: some sites wrap teasers in <article> too.
      if let best = matches.map({ $0.groups[0] }).max(by: { $0.count < $1.count }),
        best.count > 600
      {
        return best
      }
    }
    return html
  }
}
