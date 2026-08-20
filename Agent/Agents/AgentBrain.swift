import Foundation

struct AgentBrainResult {
  /// Short, spoken-style summary (this is what gets read aloud).
  let summary: String
  /// Full findings.
  let detail: String
  /// Pages the agent read, in citation order. Empty when it worked offline.
  var sources: [WebSource] = []
}

/// The model that does an agent's work. Swappable so Apple Intelligence,
/// a local GGUF/MLX model, or a mock can back the same pipeline.
///
/// `research` is the web-search half of the pipeline: when non-nil the brain
/// is expected to search first and ground its findings in what it read. It's
/// nil when the user has turned web research off (or the provider isn't
/// configured), in which case the brain falls back to what it already knows.
protocol AgentBrain: Sendable {
  var name: String { get }
  func run(
    title: String,
    prompt: String,
    research: WebResearcher?,
    progress: @Sendable (String) async -> Void
  ) async throws -> AgentBrainResult
}

enum AgentBrains {
  /// Picks the best brain available on this device: the on-device Apple
  /// Intelligence model when present and enabled, otherwise the mock.
  static func best() -> AgentBrain {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, *), FoundationModelsBrain.isAvailable {
        return FoundationModelsBrain()
      }
    #endif
    return MockAgentBrain()
  }
}

// MARK: - Mock brain

/// Placeholder brain for devices without Apple Intelligence.
///
/// With web research enabled it does real work — searches, reads the pages,
/// and reports what it found — it just can't reason over the results, so the
/// findings are a digest rather than an analysis. With research off it falls
/// back to simulating staged research, which is still enough to exercise
/// persistence, background execution, and TTS playback.
struct MockAgentBrain: AgentBrain {
  let name = "Mock brain (placeholder)"

  func run(
    title: String,
    prompt: String,
    research: WebResearcher?,
    progress: @Sendable (String) async -> Void
  ) async throws -> AgentBrainResult {
    if let research {
      return try await webDigest(title: title, prompt: prompt, research: research, progress: progress)
    }
    return try await simulated(title: title, prompt: prompt, progress: progress)
  }

  // MARK: Web path

  private func webDigest(
    title: String,
    prompt: String,
    research: WebResearcher,
    progress: @Sendable (String) async -> Void
  ) async throws -> AgentBrainResult {
    await progress("Planning searches…")
    let queries = WebResearcher.fallbackQueries(from: prompt, limit: research.config.maxQueries)
    let context = await research.gather(queries: queries, progress: progress)
    try Task.checkCancellation()

    guard !context.isEmpty else {
      return AgentBrainResult(
        summary:
          "I searched the web for \(title) but couldn't retrieve any readable results. Check the connection, or try a more specific task.",
        detail: """
          No sources could be retrieved.

          Queries tried:
          \(context.queries.map { "• \($0)" }.joined(separator: "\n"))

          \(context.notes.map { "• \($0)" }.joined(separator: "\n"))
          """)
    }

    let entries = context.sources.map { source in
      """
      **\(source.index). \(source.title)**
      \(source.host)
      \(WebResearcher.truncate(source.excerpt, to: 700))
      """
    }.joined(separator: "\n\n")

    let detail = """
      Searched with \(research.providerName) and read \(context.sources.count) \
      \(context.sources.count == 1 ? "page" : "pages").

      Queries:
      \(context.queries.map { "• \($0)" }.joined(separator: "\n"))

      \(entries)

      (This device has no on-device language model available, so these are raw \
      excerpts rather than analysed findings. On a device with Apple \
      Intelligence the same sources are read and reasoned over.)
      """

    let names = context.sources.prefix(3).map(\.host).joined(separator: ", ")
    return AgentBrainResult(
      summary:
        "I searched the web about \(title) and read \(context.sources.count) \(context.sources.count == 1 ? "page" : "pages"), including \(names). This device has no on-device model available, so open the details to read the excerpts yourself.",
      detail: detail,
      sources: context.sources)
  }

  // MARK: Offline path

  private func simulated(
    title: String,
    prompt: String,
    progress: @Sendable (String) async -> Void
  ) async throws -> AgentBrainResult {
    let steps = [
      "Breaking the task into research steps…",
      "Gathering candidate options…",
      "Comparing options against your criteria…",
      "Writing up recommendations…",
    ]
    for step in steps {
      try Task.checkCancellation()
      await progress(step)
      try await Task.sleep(for: .seconds(2))
    }

    if prompt.localizedCaseInsensitiveContains("camp") {
      return Self.summerCampsResult
    }
    return AgentBrainResult(
      summary:
        "I finished working on \(title). I explored the request, compared the leading options, and wrote up three recommendations with reasoning. Open the details to see the full findings.",
      detail: """
        Task: \(prompt)

        This is a placeholder result produced by the mock brain. When a real \
        model is wired in (Apple Intelligence on supported devices, or another \
        on-device model), its findings will appear here in the same format:

        1. Top recommendation — with the reasoning behind it.
        2. Strong alternative — and when it's the better pick.
        3. Budget/backup option — trade-offs to be aware of.
        """)
  }

  private static let summerCampsResult = AgentBrainResult(
    summary:
      "I finished researching summer camps. My top pick is Camp Kupugani for its small groups and strong reviews, with Steve and Kate's Camp as the most flexible option and YMCA Camp Duncan as the best value. All three still had availability when I checked.",
    detail: """
      Summer camp research — top three picks

      1. Camp Kupugani (overnight, 1–2 weeks)
         Small camper-to-counselor ratio, strong emphasis on confidence \
         building, consistently excellent parent reviews. Sessions fill \
         early; the two-week July session fits your dates best.

      2. Steve and Kate's Camp (day camp, flexible)
         Buy a bank of days and use them any time — the most flexible \
         schedule if your summer plans are still moving. Strong maker/media \
         programming; refunds for unused days.

      3. YMCA Camp Duncan (day or overnight, best value)
         Classic waterfront camp with financial assistance available. \
         Weekly themes; sibling discounts. Registration is open now.

      Next steps: confirm dates, then register for the top pick — most of \
      these fill 6–8 weeks before session start.

      (Placeholder findings from the mock brain — wire in a real model to \
      replace this with live research.)
      """)
}

// MARK: - Apple Intelligence brain

#if canImport(FoundationModels)
  import FoundationModels

  /// Runs the agent on Apple's on-device foundation model (Apple
  /// Intelligence). Only offered when the device supports it and the user has
  /// Apple Intelligence enabled.
  ///
  /// With web research on this is a three-pass pipeline: plan search queries,
  /// hand the retrieved pages back as context for the findings, then write a
  /// spoken summary. The model never reaches the network itself — the app
  /// does the fetching and decides what it gets to see.
  @available(iOS 26.0, *)
  struct FoundationModelsBrain: AgentBrain {
    let name = "Apple Intelligence (on-device)"

    /// Excerpt budgets to try, largest first. The on-device model has a small
    /// context window, so an over-long source block is a real failure mode;
    /// on overflow we retry with tighter excerpts before giving up on them.
    private static let excerptBudgets = [1100, 600, 300]

    static var isAvailable: Bool {
      if case .available = SystemLanguageModel.default.availability {
        return true
      }
      return false
    }

    func run(
      title: String,
      prompt: String,
      research: WebResearcher?,
      progress: @Sendable (String) async -> Void
    ) async throws -> AgentBrainResult {
      var context = ResearchContext.empty
      if let research {
        let queries = await planQueries(for: prompt, limit: research.config.maxQueries, progress: progress)
        context = await research.gather(queries: queries, progress: progress)
        try Task.checkCancellation()
      }

      let detail = try await findings(prompt: prompt, context: context, progress: progress)

      await progress("Writing the spoken summary…")
      let summarizer = LanguageModelSession(
        instructions: """
          You turn research findings into a short spoken briefing. Three \
          sentences at most, plain language, no markdown, no bracketed \
          citation numbers — it is going to be read aloud.
          """)
      let summary = try await summarizer.respond(
        to: "Summarize these findings to be read aloud:\n\n"
          + WebResearcher.truncate(detail, to: 2500)
      ).content

      return AgentBrainResult(
        summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
        detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
        sources: context.sources)
    }

    // MARK: Pass 1 — plan the searches

    private func planQueries(
      for prompt: String,
      limit: Int,
      progress: @Sendable (String) async -> Void
    ) async -> [String] {
      await progress("Planning web searches…")
      let planner = LanguageModelSession(instructions: Self.plannerInstructions(limit: limit))

      // Guided generation first: left to free-form text, the model tends to
      // answer the task instead of writing queries for it.
      do {
        let plan = try await planner.respond(to: "Task: \(prompt)", generating: SearchPlan.self)
        let queries = WebResearcher.clean(plan.content.queries, limit: limit)
        if !queries.isEmpty {
          await progress("Queries: \(queries.joined(separator: " · "))")
          return queries
        }
      } catch {
        await progress("Guided query planning unavailable; trying plain text.")
      }

      // Same ask, unguided — some model/OS combinations refuse the schema.
      do {
        let raw = try await planner.respond(to: "Task: \(prompt)").content
        let queries = WebResearcher.parseQueries(raw, limit: limit)
        if !queries.isEmpty {
          await progress("Queries: \(queries.joined(separator: " · "))")
          return queries
        }
      } catch {
        await progress("Query planning failed; searching the task text directly.")
      }
      return WebResearcher.fallbackQueries(from: prompt, limit: limit)
    }

    /// Forces the planner's output into a list of strings rather than prose.
    @Generable
    struct SearchPlan {
      @Guide(
        description:
          "Short keyword web search queries, 3 to 8 words each. Search-box text, not answers.")
      var queries: [String]
    }

    private static func plannerInstructions(limit: Int) -> String {
      """
      You write web search queries. You never answer the task yourself — \
      another system does that after reading what your queries find.

      Write at most \(limit) queries. Each is 3–8 words of keywords, the kind \
      of thing someone types into a search box: no markdown, no punctuation, \
      no place names or figures you invented.

      Example task: Find a reliable used minivan under $20k near Denver.
      Example queries: most reliable used minivans under 20000 / used minivan \
      reliability ratings / denver used minivan dealerships
      """
    }

    // MARK: Pass 2 — reason over what was read

    private func findings(
      prompt: String,
      context: ResearchContext,
      progress: @Sendable (String) async -> Void
    ) async throws -> String {
      guard !context.isEmpty else {
        await progress("Thinking with the on-device model…")
        let session = LanguageModelSession(instructions: Self.offlineInstructions)
        return try await session.respond(to: prompt).content
      }

      await progress("Reasoning over \(context.sources.count) sources…")
      var lastError: Error?
      for budget in Self.excerptBudgets {
        do {
          try Task.checkCancellation()
          let session = LanguageModelSession(instructions: Self.groundedInstructions)
          return try await session.respond(
            to: """
              Task: \(prompt)

              Sources:
              \(context.promptBlock(charsPerSource: budget))
              """
          ).content
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // Almost always a context-window overflow; retry with less text.
          lastError = error
          await progress("Sources didn't fit the context window; trimming and retrying…")
        }
      }

      // Everything read still wouldn't fit: fall back to general knowledge
      // rather than failing the job outright.
      await progress("Falling back to the model's own knowledge.")
      do {
        let session = LanguageModelSession(instructions: Self.offlineInstructions)
        return try await session.respond(to: prompt).content
      } catch {
        throw lastError ?? error
      }
    }

    private static let groundedInstructions = """
      You are a research agent. The user's task is followed by numbered \
      excerpts from web pages the app fetched for you.

      Base your answer on those excerpts. Cite them inline as [1], [2] — every \
      specific claim, price, date, or name needs a citation. If the excerpts \
      don't answer part of the task, say so plainly instead of guessing, and \
      mark anything you add from your own knowledge as unverified. Excerpts \
      are truncated web pages, so treat them as evidence, not gospel.

      Format: a short ranked shortlist with the reasoning for each entry, then \
      concrete next steps.
      """

    private static let offlineInstructions = """
      You are a diligent research agent working on the user's behalf. \
      Produce practical, well-organized findings: a ranked shortlist with \
      reasoning, then concrete next steps. Be specific and honest about \
      uncertainty — you have no internet access for this task, so base \
      recommendations on general knowledge and clearly say what the user \
      should verify.
      """
  }
#endif
