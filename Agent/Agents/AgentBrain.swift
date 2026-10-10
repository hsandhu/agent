import Foundation

struct AgentBrainResult {
  /// Short, spoken-style summary (this is what gets read aloud).
  let summary: String
  /// Full findings.
  let detail: String
  /// Pages the agent read, in citation order. Empty when it worked offline.
  var sources: [WebSource] = []
  /// Whether the model judged the request actually satisfied. A brain that
  /// can't review its own work reports what it produced at face value.
  var meetsRequest: Bool = true
  /// What the request asked for that the findings still don't deliver.
  /// Empty when `meetsRequest` is true.
  var gaps: [String] = []
  /// How many research-and-write rounds it took.
  var rounds: Int = 1
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
  /// With web research on, the model drives a loop rather than a single pass:
  /// plan search queries, reason over the retrieved pages, then **review its
  /// own findings against the original request**. A task is finished when the
  /// reviewer says the request is actually met — not when a pass completes and
  /// not on a clock. If it falls short, the reviewer names the gaps and the
  /// searches that would close them, and the loop goes round again.
  ///
  /// The model never reaches the network itself — the app does the fetching
  /// and decides what it gets to see.
  @available(iOS 26.0, *)
  struct FoundationModelsBrain: AgentBrain {
    let name = "Apple Intelligence (on-device)"

    /// Excerpt budgets to try, largest first. The on-device model has a small
    /// context window, so an over-long source block is a real failure mode;
    /// on overflow we retry with tighter excerpts before giving up on them.
    private static let excerptBudgets = [1100, 600, 300]

    /// Ceiling on research-and-write rounds for one task. A reviewer held to
    /// a high bar can almost always find something else to want, and each
    /// round costs searches, page reads, and on-device inference — so the
    /// loop stops and reports honestly rather than chasing perfection.
    private static let maxRounds = 3

    /// The model has no clock. Left unaided it anchors time-sensitive queries
    /// to whatever year its training suggests — a run observed writing
    /// "registration deadlines 2024" two years late — so every prompt that
    /// writes searches is told the date.
    private static var todayLine: String {
      "Today is \(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year()))."
    }

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

      var detail = try await findings(
        prompt: prompt, context: context, revising: nil, toClose: [], progress: progress)
      var verdict = try await review(prompt: prompt, detail: detail, progress: progress)
      var rounds = 1

      // The task is done when the reviewer says the request is met. Without
      // research there is nothing new to go and find, so one honest verdict
      // is all we can offer.
      if let research {
        while !verdict.meetsRequest, rounds < Self.maxRounds {
          try Task.checkCancellation()
          await progress("Not there yet — \(Self.describe(verdict.gaps)). Round \(rounds + 1)…")

          let more = await research.gather(
            queries: verdict.followUpQueries, progress: progress)
          guard !more.sources.isEmpty else {
            await progress("Nothing new found for those gaps; stopping with them on the record.")
            break
          }
          context = context.merging(more)

          detail = try await findings(
            prompt: prompt, context: context, revising: detail, toClose: verdict.gaps,
            progress: progress)
          verdict = try await review(prompt: prompt, detail: detail, progress: progress)
          rounds += 1
        }
      }

      await progress(
        verdict.meetsRequest
          ? "Request met after \(rounds) round\(rounds == 1 ? "" : "s")."
          : "Finishing with \(verdict.gaps.count) gap\(verdict.gaps.count == 1 ? "" : "s") unresolved.")

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
        sources: context.sources,
        meetsRequest: verdict.meetsRequest,
        gaps: verdict.gaps,
        rounds: rounds)
    }

    private static func describe(_ gaps: [String]) -> String {
      guard !gaps.isEmpty else { return "the findings don't cover the request yet" }
      return gaps.prefix(2).joined(separator: "; ")
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

      \(todayLine) Anchor anything seasonal or time-sensitive to that date. \
      Never write a year you assumed.

      Write at most \(limit) queries. Each is 3–8 words of keywords, the kind \
      of thing someone types into a search box: no markdown, no punctuation, \
      no place names or figures you invented.

      Example task: Find a reliable used minivan under $20k near Denver.
      Example queries: most reliable used minivans under 20000 / used minivan \
      reliability ratings / denver used minivan dealerships
      """
    }

    // MARK: The bar — does this actually answer the request?

    /// The reviewer's verdict on a draft. Guided generation because a
    /// free-form critique is not something the loop can act on.
    @Generable
    struct CompletionVerdict {
      @Guide(
        description:
          "True only when the findings fully deliver everything the request asked for, "
          + "with every specific claim backed by a cited source. False if anything is "
          + "missing, vague, uncited, guessed, or flagged unverified.")
      var meetsRequest: Bool

      @Guide(
        description:
          "Each thing the request asked for that the findings do not yet deliver, one "
          + "short phrase each. Empty when meetsRequest is true.")
      var gaps: [String]

      @Guide(
        description:
          "Keyword web search queries, 3 to 8 words each, that would close those gaps. "
          + "Empty when meetsRequest is true.")
      var followUpQueries: [String]
    }

    /// Asks the model to mark its own work, held to a deliberately high bar.
    /// A failed review is not an error — it is the signal to go round again.
    private func review(
      prompt: String,
      detail: String,
      progress: @Sendable (String) async -> Void
    ) async throws -> CompletionVerdict {
      try Task.checkCancellation()
      await progress("Checking the findings against the request…")
      let reviewer = LanguageModelSession(instructions: Self.reviewerInstructions)

      do {
        let verdict = try await reviewer.respond(
          to: """
            Request: \(prompt)

            Draft findings:
            \(WebResearcher.truncate(detail, to: 2500))
            """,
          generating: CompletionVerdict.self
        ).content
        return CompletionVerdict(
          meetsRequest: verdict.meetsRequest,
          gaps: verdict.meetsRequest ? [] : Self.tidy(verdict.gaps),
          followUpQueries: WebResearcher.clean(verdict.followUpQueries, limit: 3))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // No verdict means no evidence the bar was cleared. Accepting the
        // draft here would quietly turn every reviewer failure into a pass,
        // which is exactly the bar this is meant to hold.
        await progress("Couldn't review the findings; recording that the bar wasn't verified.")
        return CompletionVerdict(
          meetsRequest: false,
          gaps: ["The findings could not be checked against the request on this device."],
          followUpQueries: [])
      }
    }

    private static func tidy(_ gaps: [String]) -> [String] {
      var seen = Set<String>()
      let cleaned = gaps
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
      return Array(cleaned.prefix(5))
    }

    private static var reviewerInstructions: String {
      """
      You review research findings against the request that prompted them. You \
      do not rewrite them and you do not do the research yourself.

      \(todayLine) Judge currency against that date, and anchor any query you \
      write to it rather than to a year you assumed.

      Hold a high bar. Say the request is met only when all of this is true:
      - Every distinct thing the request asked for is delivered. Count them. A \
        request for three ranked options with deadlines is not met by two \
        options, nor by three without deadlines.
      - Every specific claim — a price, a date, a name, a ranking — is backed \
        by a cited source in the draft.
      - Nothing important is left vague, guessed at, or flagged as unverified.
      - Any constraint in the request (a budget, a location, an age, a \
        timeframe) is actually honoured, not just acknowledged.

      When it falls short, name each shortfall as a short phrase and write the \
      keyword search queries that would close it. Be specific: "no registration \
      deadlines for any camp", not "needs more detail".

      A draft that reads well but leaves an ask unanswered does not meet the \
      request.
      """
    }

    // MARK: Pass 2 — reason over what was read

    /// `revising` carries the previous round's draft and `toClose` the gaps
    /// the reviewer found in it, so a later round improves the draft instead
    /// of starting over and losing what already worked.
    private func findings(
      prompt: String,
      context: ResearchContext,
      revising previous: String?,
      toClose gaps: [String],
      progress: @Sendable (String) async -> Void
    ) async throws -> String {
      guard !context.isEmpty else {
        await progress("Thinking with the on-device model…")
        let session = LanguageModelSession(instructions: Self.offlineInstructions)
        return try await session.respond(to: prompt).content
      }

      await progress(
        previous == nil
          ? "Reasoning over \(context.sources.count) sources…"
          : "Rewriting to close the gaps, now over \(context.sources.count) sources…")
      var lastError: Error?
      for budget in Self.excerptBudgets {
        do {
          try Task.checkCancellation()
          let session = LanguageModelSession(
            instructions: previous == nil ? Self.groundedInstructions : Self.revisionInstructions)
          return try await session.respond(
            to: Self.findingsPrompt(
              task: prompt, context: context, budget: budget, previous: previous, gaps: gaps)
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

    private static func findingsPrompt(
      task: String, context: ResearchContext, budget: Int, previous: String?, gaps: [String]
    ) -> String {
      let sources = """
        Task: \(task)

        Sources:
        \(context.promptBlock(charsPerSource: budget))
        """
      guard let previous else { return sources }
      return """
        \(sources)

        Your previous draft:
        \(WebResearcher.truncate(previous, to: 1800))

        A reviewer found these gaps in it:
        \(gaps.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private static let revisionInstructions = """
      You are revising your own research findings. You are given the task, the \
      sources (now including newly read pages), your previous draft, and the \
      gaps a reviewer found in it.

      Close every gap. Keep what already worked — do not drop correct, cited \
      material to make room. Cite the new sources inline as [1], [2] the same \
      way, using the numbers given in the source list. If a gap still cannot \
      be closed from the sources available, say so explicitly rather than \
      papering over it with a guess.

      Format: a short ranked shortlist with the reasoning for each entry, then \
      concrete next steps.
      """

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
