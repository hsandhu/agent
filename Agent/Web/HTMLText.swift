import Foundation

/// Minimal HTML → plain text conversion.
///
/// Deliberately hand-rolled rather than `NSAttributedString(html:)`: that
/// initializer is main-thread-only and spins up WebKit, which is a non-starter
/// inside a `BGProcessingTask`. We only need enough fidelity to feed a
/// language model, so structural tags become newlines and everything else is
/// dropped.
enum HTMLText {

  /// Strips scripts, styles, and markup, decodes entities, and collapses
  /// runaway whitespace.
  static func plainText(from html: String) -> String {
    var text = html

    // Drop anything whose contents are never prose.
    for tag in ["script", "style", "noscript", "svg", "head", "template", "form"] {
      text = removeElements(named: tag, in: text)
    }
    text = replacing(#"<!--[\s\S]*?-->"#, in: text, with: "")

    // Structural tags become line breaks so paragraphs and list items don't
    // run together into one wall of text.
    text = replacing(
      #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>"#, in: text, with: "\n")
    text = replacing(#"(?i)<li[^>]*>"#, in: text, with: "\n• ")
    text = replacing(#"<[^>]+>"#, in: text, with: " ")

    text = decodeEntities(text)

    // Collapse horizontal runs, then cap blank-line runs at one.
    text = replacing(#"[ \t\u{00A0}]+"#, in: text, with: " ")
    text = replacing(#" ?\n ?"#, in: text, with: "\n")
    text = replacing(#"\n{3,}"#, in: text, with: "\n\n")
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Inline text of a fragment (a link label, say) — no line breaks wanted.
  static func inlineText(from html: String) -> String {
    let stripped = replacing(#"<[^>]+>"#, in: html, with: "")
    return replacing(#"\s+"#, in: decodeEntities(stripped), with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Contents of `<title>`, when present.
  static func title(from html: String) -> String? {
    guard let range = html.range(of: #"(?i)<title[^>]*>([\s\S]*?)</title>"#, options: .regularExpression)
    else { return nil }
    let inner = html[range]
      .replacingOccurrences(of: #"(?i)^<title[^>]*>"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"(?i)</title>$"#, with: "", options: .regularExpression)
    let text = inlineText(from: String(inner))
    return text.isEmpty ? nil : text
  }

  static func decodeEntities(_ input: String) -> String {
    var text = input
    let named: [String: String] = [
      "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
      "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
      "&hellip;": "…", "&rsquo;": "'", "&lsquo;": "'", "&ldquo;": "\u{201C}",
      "&rdquo;": "\u{201D}", "&bull;": "•", "&middot;": "·", "&times;": "×",
      "&trade;": "™", "&copy;": "©", "&reg;": "®", "&deg;": "°", "&euro;": "€",
      "&pound;": "£", "&cent;": "¢",
    ]
    for (entity, replacement) in named {
      guard text.contains(entity) else { continue }
      text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }
    guard text.contains("&#") else { return text }
    return replacingMatches(#"&#(x?)([0-9a-fA-F]+);"#, in: text) { groups in
      let isHex = groups[0].lowercased() == "x"
      guard let value = UInt32(groups[1], radix: isHex ? 16 : 10),
        let scalar = Unicode.Scalar(value)
      else { return nil }
      return String(Character(scalar))
    }
  }

  // MARK: - Regex helpers

  /// Removes `<tag …> … </tag>` including the contents.
  private static func removeElements(named tag: String, in html: String) -> String {
    replacing(#"(?i)<\#(tag)\b[^>]*>[\s\S]*?</\#(tag)\s*>"#, in: html, with: " ")
  }

  static func replacing(_ pattern: String, in input: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
    return regex.stringByReplacingMatches(
      in: input, range: NSRange(input.startIndex..., in: input),
      withTemplate: NSRegularExpression.escapedTemplate(for: template))
  }

  /// Replaces each match using a closure over its capture groups; returning
  /// nil from the closure leaves that match untouched.
  static func replacingMatches(
    _ pattern: String, in input: String, transform: ([String]) -> String?
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
    let full = NSRange(input.startIndex..., in: input)
    var output = ""
    var cursor = input.startIndex
    for match in regex.matches(in: input, range: full) {
      guard let matchRange = Range(match.range, in: input) else { continue }
      var groups: [String] = []
      for index in 1..<match.numberOfRanges {
        if let range = Range(match.range(at: index), in: input) {
          groups.append(String(input[range]))
        } else {
          groups.append("")
        }
      }
      output += input[cursor..<matchRange.lowerBound]
      output += transform(groups) ?? String(input[matchRange])
      cursor = matchRange.upperBound
    }
    output += input[cursor...]
    return output
  }

  /// All matches of `pattern`, each as its list of capture groups plus the
  /// match's start offset in the source (used to pair links with snippets).
  static func matches(_ pattern: String, in input: String) -> [(groups: [String], start: Int)] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let full = NSRange(input.startIndex..., in: input)
    return regex.matches(in: input, range: full).map { match in
      var groups: [String] = []
      for index in 1..<match.numberOfRanges {
        if let range = Range(match.range(at: index), in: input) {
          groups.append(String(input[range]))
        } else {
          groups.append("")
        }
      }
      return (groups, match.range.location)
    }
  }
}
