import Foundation

/// What the agent learned from the web, ready to be handed to a model.
struct ResearchContext: Sendable {
  let queries: [String]
  let sources: [WebSource]
  /// Non-fatal problems worth showing in the progress log.
  let notes: [String]

  var isEmpty: Bool { sources.isEmpty }

  static let empty = ResearchContext(queries: [], sources: [], notes: [])

  /// The sources formatted for prompt stuffing, numbered so the model can
  /// cite them as [1], [2], … `charsPerSource` is the knob that keeps the
  /// block inside a small on-device context window.
  func promptBlock(charsPerSource: Int) -> String {
    sources.map { source in
      """
      [\(source.index)] \(source.title) — \(source.host)
      \(WebResearcher.truncate(source.excerpt, to: charsPerSource))
      """
    }.joined(separator: "\n\n")
  }
}

/// Runs the search-then-read half of an agent: turns queries into a handful
/// of read pages. Deliberately independent of any model, so the mock brain and
/// Apple Intelligence share exactly the same research step.
struct WebResearcher: Sendable {
  let provider: WebSearchProvider
  let config: WebSearchConfig
  private let reader = PageReader()

  /// Longest excerpt kept per source; the prompt block trims further.
  private static let maxExcerpt = 4000

  init(provider: WebSearchProvider, config: WebSearchConfig = .current) {
    self.provider = provider
    self.config = config
  }

  var providerName: String { provider.name }

  /// Searches, then downloads and extracts the most promising pages.
  func gather(
    queries requested: [String],
    progress: @Sendable (String) async -> Void
  ) async -> ResearchContext {
    let queries = Self.clean(requested, limit: config.maxQueries)
    guard !queries.isEmpty else { return .empty }

    var notes: [String] = []
    var hitsPerQuery: [[WebResult]] = []

    // Anything that went wrong is both shown live and kept on the context, so
    // a brain writing up the run can mention it without re-reporting it.
    func note(_ text: String) async {
      notes.append(text)
      await progress(text)
    }

    // Sequential: three queries is cheap, and hammering a scraped endpoint in
    // parallel is the fastest way to get rate-limited.
    for query in queries {
      if Task.isCancelled { break }
      do {
        let hits = try await provider.search(query, limit: config.maxResultsPerQuery)
        await progress("Searched \"\(query)\" — \(hits.count) result\(hits.count == 1 ? "" : "s").")
        hitsPerQuery.append(hits)
      } catch {
        await note("Search for \"\(query)\" failed: \(error.localizedDescription)")
      }
    }

    let candidates = Self.interleaveAndDedupe(hitsPerQuery)
    guard !candidates.isEmpty else {
      return ResearchContext(queries: queries, sources: [], notes: notes)
    }

    let toRead = Array(candidates.filter { PageReader.isReadable($0.url) }
      .prefix(config.maxPagesToRead))
    await progress("Reading \(toRead.count) page\(toRead.count == 1 ? "" : "s")…")

    let pages = await readPages(toRead)

    var sources: [WebSource] = []
    var readURLs: Set<String> = []
    for (offset, hit) in toRead.enumerated() {
      let page = pages[offset]
      // A page that wouldn't load is still a usable source at snippet depth —
      // the search result itself carries a summary.
      let excerpt = page?.text ?? hit.snippet
      guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      if page == nil {
        await note(
          "Couldn't open \(hit.url.host() ?? hit.url.absoluteString); used the search snippet.")
      }
      // Cite where we landed, not where we aimed: two hits can redirect onto
      // the same page, and a duplicate source wastes the context budget.
      let url = page?.finalURL ?? hit.url
      guard readURLs.insert(Self.canonical(url)).inserted else { continue }
      sources.append(
        WebSource(
          index: sources.count + 1,
          title: page?.title ?? hit.title,
          urlString: url.absoluteString,
          excerpt: Self.truncate(excerpt, to: Self.maxExcerpt)))
    }

    return ResearchContext(queries: queries, sources: sources, notes: notes)
  }

  /// Downloads the pages concurrently, preserving input order; a failure
  /// becomes nil rather than sinking the whole research step.
  private func readPages(_ hits: [WebResult]) async -> [PageReader.Page?] {
    await withTaskGroup(of: (Int, PageReader.Page?).self) { group in
      for (index, hit) in hits.enumerated() {
        group.addTask {
          do {
            return (index, try await reader.read(hit.url))
          } catch {
            return (index, nil)
          }
        }
      }
      var output = [PageReader.Page?](repeating: nil, count: hits.count)
      for await (index, page) in group {
        output[index] = page
      }
      return output
    }
  }

  // MARK: - Query handling

  /// Takes one hit from each query in turn, so a single query can't monopolize
  /// the read budget, and drops duplicate destinations.
  private static func interleaveAndDedupe(_ hitsPerQuery: [[WebResult]]) -> [WebResult] {
    var seen: Set<String> = []
    var merged: [WebResult] = []
    let depth = hitsPerQuery.map(\.count).max() ?? 0
    for rank in 0..<depth {
      for hits in hitsPerQuery where rank < hits.count {
        let hit = hits[rank]
        guard seen.insert(canonical(hit.url)).inserted else { continue }
        merged.append(hit)
      }
    }
    return merged
  }

  private static func canonical(_ url: URL) -> String {
    var host = url.host()?.lowercased() ?? ""
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    let path = url.path().hasSuffix("/") ? String(url.path().dropLast()) : url.path()
    return host + path.lowercased()
  }

  static func clean(_ queries: [String], limit: Int) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    for query in queries {
      let normalized = normalize(query)
      guard normalized.count >= 3, normalized.count <= 160 else { continue }
      guard seen.insert(normalized.lowercased()).inserted else { continue }
      output.append(normalized)
      if output.count == limit { break }
    }
    return output
  }

  /// Beats a model's line into something worth typing into a search box.
  ///
  /// Small models drift: asked for queries they hand back markdown-formatted
  /// *answers* ("**North Shore Trail** - 1.5 miles, parking available"), which
  /// make terrible queries. Stripping the formatting and the trailing dash
  /// clause recovers the useful keywords from those.
  private static func normalize(_ query: String) -> String {
    var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    text = HTMLText.replacing(#"[*_`#\[\]"“”]"#, in: text, with: "")
    text = HTMLText.replacing(#"\s+"#, in: text, with: " ")
    if let dash = text.range(of: #"\s+[-–—:]\s+"#, options: .regularExpression) {
      text = String(text[..<dash.lowerBound])
    }
    let words = text.split(separator: " ")
    if words.count > 12 {
      text = words.prefix(12).joined(separator: " ")
    }
    return text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:'-–—"))
  }

  /// Parses a model's answer to "give me search queries" — one per line,
  /// tolerating numbering, bullets, and a preamble line.
  static func parseQueries(_ raw: String, limit: Int) -> [String] {
    let lines = raw.split(whereSeparator: \.isNewline).map { line -> String in
      // "1. best summer camps" / "- best summer camps" / "• …"
      HTMLText.replacing(#"^\s*(?:\d+[\.\)]|[-–—•*])\s*"#, in: String(line), with: "")
    }
    // Drop conversational preamble ("Here are three queries:").
    let candidates = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasSuffix(":") }
    return clean(candidates, limit: limit)
  }

  /// Last-resort query when no model is available to plan one: the task's
  /// first sentence, shortened to something search-engine shaped.
  ///
  /// Only ever one query — `normalize` caps every query at 12 words, so a
  /// second one derived from the same prompt is a near-duplicate search for
  /// near-identical results.
  static func fallbackQueries(from prompt: String, limit: Int) -> [String] {
    let firstSentence =
      prompt.split(whereSeparator: { ".?!\n".contains($0) }).first.map(String.init) ?? prompt
    return clean([firstSentence], limit: max(1, limit))
  }

  /// Truncates on a word boundary so a source never ends mid-token.
  static func truncate(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    let cut = text.prefix(limit)
    guard let lastSpace = cut.lastIndex(of: " ") else { return String(cut) + "…" }
    return String(cut[..<lastSpace]) + "…"
  }
}
