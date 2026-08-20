import SwiftUI
import SwiftData

/// Main screen, styled after Cursor's mobile agents app: a flat list of
/// agents with status dots, and a persistent composer pill at the bottom to
/// spawn new agents by typing or dictating.
struct AgentsView: View {
  @EnvironmentObject var tts: TtsEngine
  @EnvironmentObject var voices: VoiceProfileStore
  @ObservedObject private var runner = AgentRunner.shared
  @Environment(\.modelContext) private var context
  @Query(sort: \AgentJob.createdAt, order: .reverse) private var jobs: [AgentJob]

  var body: some View {
    NavigationStack {
      List {
        if jobs.isEmpty {
          Text("Describe a task below to spawn your first agent.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 80)
            .listRowSeparator(.hidden)
        }

        jobSection("Today", jobs: todayJobs)
        jobSection("Earlier", jobs: earlierJobs)
      }
      .listStyle(.plain)
      .navigationTitle("Agents")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            SettingsView()
          } label: {
            Image(systemName: "gearshape")
          }
        }
      }
      .navigationDestination(for: UUID.self) { id in
        if let job = jobs.first(where: { $0.id == id }) {
          AgentDetailView(job: job)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        ComposerBar()
      }
    }
  }

  private var todayJobs: [AgentJob] {
    jobs.filter { Calendar.current.isDateInToday($0.createdAt) }
  }

  private var earlierJobs: [AgentJob] {
    jobs.filter { !Calendar.current.isDateInToday($0.createdAt) }
  }

  @ViewBuilder
  private func jobSection(_ title: String, jobs sectionJobs: [AgentJob]) -> some View {
    if !sectionJobs.isEmpty {
      Section {
        ForEach(sectionJobs) { job in
          NavigationLink(value: job.id) {
            AgentRow(job: job, playAction: { play(job) })
          }
          .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
          .swipeActions {
            Button(role: .destructive) {
              context.delete(job)
              try? context.save()
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
        }
      } header: {
        Text(title)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textCase(nil)
      }
    }
  }

  private func play(_ job: AgentJob) {
    guard let summary = job.resultSummary else { return }
    tts.speak(text: summary, profile: voices.selected)
  }
}

// MARK: - Row: status dot · title · "brain · ✓ Done"

struct AgentRow: View {
  let job: AgentJob
  let playAction: () -> Void
  @EnvironmentObject var tts: TtsEngine

  var body: some View {
    HStack(spacing: 12) {
      statusIndicator
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 3) {
        Text(job.title)
          .fontWeight(.medium)
          .lineLimit(1)
        subtitle
          .font(.subheadline)
          .lineLimit(1)
      }

      Spacer()

      if job.status == .completed {
        Button(action: playAction) {
          Image(systemName: "play.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(tts.loadState != .ready)
        .accessibilityLabel("Play result")
      }
    }
  }

  @ViewBuilder private var statusIndicator: some View {
    switch job.status {
    case .running:
      Image(systemName: "sparkles")
        .font(.caption)
        .foregroundStyle(.purple)
        .symbolEffect(.pulse)
    case .completed:
      Circle().fill(.blue).frame(width: 8, height: 8)
    case .queued:
      Circle().fill(.quaternary).frame(width: 8, height: 8)
    case .failed:
      Circle().fill(.red).frame(width: 8, height: 8)
    }
  }

  private var subtitle: some View {
    HStack(spacing: 4) {
      Text(brainShortName)
        .foregroundStyle(.secondary)
      Text("·")
        .foregroundStyle(.secondary)
      switch job.status {
      case .completed:
        HStack(spacing: 3) {
          Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.green)
          Text("Done")
            .foregroundStyle(.secondary)
        }
      case .running:
        Text("Working")
          .foregroundStyle(.secondary)
      case .queued:
        Text("Queued")
          .foregroundStyle(.secondary)
      case .failed:
        Text("Failed")
          .foregroundStyle(.red)
      }
    }
  }

  private var brainShortName: String {
    guard let brain = job.brainUsed else { return "on-device" }
    // "Apple Intelligence (on-device)" → "Apple Intelligence"
    return brain.components(separatedBy: " (").first ?? brain
  }
}

// MARK: - Composer ("Plan, ask, build…")

/// Bottom composer pill: + menu with examples, a growing text field, mic
/// dictation (streamed partials shown in blue, like Cursor's voice mode),
/// and a send button that spawns the agent.
struct ComposerBar: View {
  @EnvironmentObject var stt: SttEngine
  @Environment(\.modelContext) private var context

  @State private var draft = ""
  @State private var livePartial = ""
  @State private var dictating = false
  @State private var startedEngine = false
  @State private var micDenied = false
  @FocusState private var focused: Bool

  private static let suggestions: [(label: String, prompt: String)] = [
    ("Find summer camps",
     "Find the best summer camps for my 9-year-old this summer. We're near Chicago, prefer outdoorsy programs with small groups, budget around $500 per week. Rank the top three and tell me registration deadlines."),
    ("Plan a birthday party",
     "Plan a birthday party for a 10-year-old: theme ideas, a simple schedule for two hours, and a shopping list under $150."),
    ("Weekly meal plan",
     "Create a one-week dinner meal plan for a family of four, healthy and quick, with a consolidated grocery list."),
    ("Weekend trip ideas",
     "Suggest three long-weekend trips within driving distance of Chicago for a family, with what to do in each and rough costs."),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if dictating && !livePartial.isEmpty {
        Text(livePartial)
          .font(.callout)
          .foregroundStyle(.blue)
          .lineLimit(2)
          .padding(.horizontal, 24)
          .transition(.opacity)
      }

      HStack(alignment: .bottom, spacing: 10) {
        Menu {
          ForEach(Self.suggestions, id: \.label) { suggestion in
            Button(suggestion.label) { draft = suggestion.prompt }
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color(.systemGray6)))
        }

        TextField("Plan, ask, build…", text: $draft, axis: .vertical)
          .lineLimit(1...4)
          .focused($focused)
          .padding(.vertical, 6)

        Button(action: toggleDictation) {
          Image(systemName: dictating ? "mic.fill" : "mic")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(dictating ? .red : .secondary)
            .frame(width: 30, height: 30)
        }
        .accessibilityLabel(dictating ? "Stop dictation" : "Dictate")

        if !trimmedDraft.isEmpty {
          Button(action: spawn) {
            Image(systemName: "arrow.up")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(Color(.systemBackground))
              .frame(width: 30, height: 30)
              .background(Circle().fill(Color.primary))
          }
          .accessibilityLabel("Spawn agent")
          .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .fill(Color(.systemBackground))
          .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .strokeBorder(Color.primary.opacity(dictating ? 0.35 : 0.12), lineWidth: 1)
      )
      .padding(.horizontal, 16)
      .padding(.bottom, 6)
    }
    .animation(.snappy(duration: 0.2), value: trimmedDraft.isEmpty)
    .animation(.default, value: dictating)
    .alert("Microphone access is required", isPresented: $micDenied) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access for Agent in Settings to dictate.")
    }
    .onDisappear { stopDictation() }
  }

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func spawn() {
    let text = trimmedDraft
    guard !text.isEmpty else { return }
    stopDictation()
    focused = false
    let job = AgentJob(title: Self.title(for: text), prompt: text)
    context.insert(job)
    try? context.save()
    AgentRunner.shared.runQueuedJobsSoon()
    draft = ""
  }

  /// First few words of the prompt become the agent's name.
  static func title(for prompt: String) -> String {
    let words = prompt.split(separator: " ")
    guard !words.isEmpty else { return "New agent" }
    let head = words.prefix(6).joined(separator: " ")
    return words.count > 6 ? head + "…" : head
  }

  // MARK: Dictation

  private func toggleDictation() {
    if dictating { stopDictation() } else { startDictation() }
  }

  private func startDictation() {
    Task {
      guard await AudioCapture.requestPermission() else {
        micDenied = true
        return
      }
      stt.dictationOnPartial = { text in livePartial = text }
      stt.dictationOnUtterance = { text in
        livePartial = ""
        draft = draft.isEmpty ? text : draft + " " + text
      }
      if !stt.isRunning {
        stt.start()
        startedEngine = true
      }
      dictating = true
    }
  }

  private func stopDictation() {
    guard dictating || stt.dictationOnPartial != nil else { return }
    stt.dictationOnPartial = nil
    stt.dictationOnUtterance = nil
    if startedEngine {
      stt.stop()
      startedEngine = false
    }
    livePartial = ""
    dictating = false
  }
}

// MARK: - Detail (prompt bubble → status → black play pill → findings)

struct AgentDetailView: View {
  let job: AgentJob
  @EnvironmentObject var tts: TtsEngine
  @EnvironmentObject var voices: VoiceProfileStore
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(job.title)
          .font(.title2.bold())
          .fixedSize(horizontal: false, vertical: true)

        chipsRow

        Text(job.prompt)
          .font(.callout)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        Text(statusLine)
          .font(.footnote)
          .foregroundStyle(.secondary)

        if job.status == .completed, let summary = job.resultSummary {
          Button {
            tts.speak(text: summary, profile: voices.selected)
          } label: {
            Label("Play Summary", systemImage: "play.fill")
              .font(.body.weight(.semibold))
              .foregroundStyle(Color(.systemBackground))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(Capsule().fill(Color.primary))
          }
          .disabled(tts.loadState != .ready)
          .opacity(tts.loadState == .ready ? 1 : 0.4)

          if tts.loadState != .ready {
            Text("Loading voice…")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if let stats = tts.lastStats {
            Text(stats)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          sectionHeader("Summary")
          MarkdownText(summary)
            .font(.callout)

          if let detail = job.resultDetail {
            sectionHeader("Full findings")
            MarkdownText(detail)
              .font(.callout)
          }

          if !job.sources.isEmpty {
            sectionHeader("Sources")
            VStack(alignment: .leading, spacing: 0) {
              ForEach(job.sources) { source in
                SourceRow(source: source)
                if source.index < job.sources.count {
                  Divider()
                }
              }
            }
          }
        }

        if let error = job.errorMessage {
          sectionHeader("Error")
          Text(error)
            .font(.callout)
            .foregroundStyle(.red)
        }

        if !job.progressLines.isEmpty {
          sectionHeader("Progress")
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(job.progressLines.enumerated()), id: \.offset) { index, line in
              HStack(spacing: 10) {
                Image(systemName: "checkmark")
                  .font(.caption.weight(.bold))
                  .foregroundStyle(.green)
                Text(line)
                  .font(.subheadline)
                Spacer(minLength: 0)
              }
              .padding(.vertical, 10)
              if index < job.progressLines.count - 1 {
                Divider()
              }
            }
          }
        }
      }
      .padding(20)
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            tts.stopPlayback()
          } label: {
            Label("Stop playback", systemImage: "stop.fill")
          }
          Button(role: .destructive) {
            context.delete(job)
            try? context.save()
            dismiss()
          } label: {
            Label("Delete agent", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis")
        }
      }
    }
  }

  private var chipsRow: some View {
    HStack(spacing: 8) {
      Text(job.status.label)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(chipColor.opacity(0.15)))
        .foregroundStyle(chipColor)

      if let brain = job.brainUsed {
        Text(brain)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Capsule().fill(Color(.systemGray6)))
      }

      if !job.sources.isEmpty {
        Label("\(job.sources.count)", systemImage: "globe")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Capsule().fill(Color(.systemGray6)))
          .accessibilityLabel("\(job.sources.count) sources")
      }
    }
  }

  private var chipColor: Color {
    switch job.status {
    case .completed: return .green
    case .running: return .blue
    case .queued: return .gray
    case .failed: return .red
    }
  }

  private var statusLine: String {
    switch job.status {
    case .completed:
      if let done = job.completedAt {
        return "Finished \(done.formatted(.relative(presentation: .named)))"
      }
      return "Finished"
    case .running:
      return job.progressLines.last ?? "Working…"
    case .queued:
      return "Queued \(job.createdAt.formatted(.relative(presentation: .named)))"
    case .failed:
      return "Failed"
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .padding(.top, 4)
  }
}

/// One cited page: citation number, title, host, and a tap that opens it.
struct SourceRow: View {
  let source: WebSource

  var body: some View {
    Group {
      if let url = source.url {
        Link(destination: url) { content }
      } else {
        content
      }
    }
    .buttonStyle(.plain)
  }

  private var content: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(source.index)")
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .trailing)
      VStack(alignment: .leading, spacing: 2) {
        Text(source.title)
          .font(.subheadline)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Text(source.host)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "arrow.up.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 10)
    .contentShape(.rect)
  }
}

/// Renders model output as markdown: headings, bullet and numbered lists, and
/// rules become real layout, while each line's inline markup (bold, italics,
/// links) is still parsed by `AttributedString`.
///
/// `AttributedString(markdown:)` alone can't do this — its full-document mode
/// discards the line structure findings depend on, and the inline-only mode
/// the app used before left `###` and `*` sitting in the text. Grounded web
/// research makes the on-device model lean heavily on both.
///
/// Body lines set no font of their own, so the caller's `.font(…)` still
/// applies; headings override it to establish hierarchy.
struct MarkdownText: View {
  let content: String

  init(_ content: String) {
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(Self.blocks(in: content).enumerated()), id: \.offset) { index, block in
        view(for: block, isFirst: index == 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Rendering

  @ViewBuilder
  private func view(for block: Block, isFirst: Bool) -> some View {
    switch block {
    case .heading(let level, let text):
      Self.inline(text)
        .font(Self.headingFont(level))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, isFirst ? 0 : 6)
        .padding(.bottom, 2)

    case .listItem(let marker, let ordered, let indent, let text):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        // Numbers are right-aligned in a fixed column so "10." lines up on
        // its period with "9." instead of shoving its text further right.
        // `fixedSize` keeps a marker too wide for the column (a three-digit
        // number, or any marker at a large Dynamic Type size) from wrapping
        // onto its own line — it just overhangs to the left instead.
        Text(marker)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: true, vertical: false)
          .frame(width: ordered ? 24 : 14, alignment: ordered ? .trailing : .leading)
        Self.inline(text)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.leading, Self.indentWidth(indent))
      .padding(.vertical, 2)

    case .paragraph(let indent, let text):
      Self.inline(text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Self.indentWidth(indent))
        .padding(.vertical, 2)

    case .rule:
      Divider().padding(.vertical, 6)

    case .blank:
      Color.clear.frame(height: 6)
    }
  }

  /// Model headings sit at or below the detail screen's own section headers,
  /// so a heading-happy answer can't out-shout the app's chrome.
  private static func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .title3.weight(.semibold)
    case 2: return .headline
    default: return .subheadline.weight(.semibold)
    }
  }

  private static func indentWidth(_ spaces: Int) -> CGFloat {
    min(CGFloat(spaces) * 3, 24)
  }

  private static func inline(_ text: String) -> Text {
    if let attributed = try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    {
      return Text(attributed)
    }
    return Text(text)
  }

  // MARK: - Parsing

  enum Block {
    case heading(level: Int, text: String)
    /// `marker` is the rendered bullet ("•") or number ("3."); `indent` is the
    /// source line's leading whitespace, in spaces.
    case listItem(marker: String, ordered: Bool, indent: Int, text: String)
    case paragraph(indent: Int, text: String)
    case rule
    case blank
  }

  /// One block per line. Runs of blank lines collapse to a single gap so the
  /// rhythm doesn't depend on how generously the model spaced its output.
  static func blocks(in content: String) -> [Block] {
    var blocks: [Block] = []
    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
      let block = parse(String(line))
      if case .blank = block {
        guard let last = blocks.last else { continue }  // no leading gap
        if case .blank = last { continue }
      }
      blocks.append(block)
    }
    if case .blank = blocks.last { blocks.removeLast() }
    return blocks
  }

  private static func parse(_ line: String) -> Block {
    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
    let rest = line.drop { $0 == " " || $0 == "\t" }
      .reversed().drop(while: \.isWhitespace).reversed()
    let body = String(rest)
    guard let first = body.first else { return .blank }

    // Thematic break: three or more of the same marker, nothing else.
    if body.count >= 3, "-*_".contains(first),
      body.allSatisfy({ $0 == first || $0 == " " }),
      body.filter({ $0 == first }).count >= 3
    {
      return .rule
    }

    // ATX heading: up to six hashes, then a space.
    if first == "#" {
      let hashes = body.prefix { $0 == "#" }
      let after = body.dropFirst(hashes.count)
      if hashes.count <= 6, after.first == " " {
        return .heading(
          level: hashes.count, text: String(after).trimmingCharacters(in: .whitespaces))
      }
    }

    // Unordered item. The space after the marker is what separates "- item"
    // from "**bold**" and "*emphasis*", which must stay paragraphs.
    if "-*+".contains(first) {
      let after = body.dropFirst()
      if after.first == " " || after.first == "\t" {
        return .listItem(
          marker: "•", ordered: false, indent: indent,
          text: String(after).trimmingCharacters(in: .whitespaces))
      }
    }

    // Ordered item: "1." or "1)".
    let digits = body.prefix(while: \.isNumber)
    if !digits.isEmpty, digits.count <= 3 {
      let afterDigits = body.dropFirst(digits.count)
      if let separator = afterDigits.first, separator == "." || separator == ")" {
        let text = afterDigits.dropFirst()
        if text.first == " " {
          return .listItem(
            marker: "\(digits).", ordered: true, indent: indent,
            text: String(text).trimmingCharacters(in: .whitespaces))
        }
      }
    }

    return .paragraph(indent: indent, text: body)
  }
}
