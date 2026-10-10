import Foundation
import BackgroundTasks
import SwiftData

/// Executes queued agents and owns the BGProcessingTask integration.
///
/// Two ways work gets done:
/// 1. **Background**: a `BGProcessingTask` the system fires at its discretion
///    (typically idle/charging). Scheduled whenever the app backgrounds with
///    queued work, and re-chained from the handler.
/// 2. **Foreground**: queued jobs also run immediately while the app is open —
///    this is the interactive path, and the only path on the simulator, where
///    BGTaskScheduler is unavailable.
final class AgentRunner: ObservableObject {
  static let shared = AgentRunner()
  static let taskIdentifier = "com.robsandhu.Agent.agentwork"

  @Published private(set) var isWorking = false
  @Published private(set) var lastScheduleNote: String?

  private var store: AgentStore?
  private var foregroundTask: Task<Void, Never>?

  private init() {}

  /// Must be called once, before the app finishes launching (BGTaskScheduler
  /// requires registration at launch).
  func configure(container: ModelContainer) {
    store = AgentStore(modelContainer: container)

    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier, using: nil
    ) { [weak self] task in
      guard let self, let processing = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.handle(processing)
    }

    // Recover jobs stranded in `running` by a previous process death.
    Task { [store] in
      try? await store?.requeueOrphanedRunningJobs()
    }
  }

  // MARK: - Foreground execution

  /// Runs all queued jobs now, in-process. Safe to call repeatedly.
  /// Main thread only — it owns `foregroundTask`, which the drain task also
  /// clears from the main actor.
  @MainActor
  func runQueuedJobsSoon() {
    guard foregroundTask == nil else { return }
    DispatchQueue.main.async { self.isWorking = true }
    foregroundTask = Task { [weak self] in
      await self?.drainQueue()
      guard let self else { return }
      await MainActor.run {
        self.isWorking = false
        self.foregroundTask = nil
      }
    }
  }

  // MARK: - Background scheduling

  /// Ask the system for a background slot. Call when the app backgrounds.
  ///
  /// The request goes in synchronously. iOS starts suspending us moments after
  /// `.background`, and asking the store whether anything is queued needs an
  /// actor hop — long enough that the process can be frozen before a deferred
  /// submit ever runs, leaving no request registered at all. So we claim the
  /// slot first and withdraw it afterwards if there turns out to be no work.
  @MainActor
  func scheduleBackgroundRun() {
    submit()

    guard let store else { return }
    Task { [weak self] in
      let queued = (try? await store.queuedJobIDs()) ?? []
      guard let self, queued.isEmpty else { return }
      await MainActor.run { self.cancelScheduledRun() }
    }
  }

  /// Withdraw the slot claimed up front once we know there is no work.
  @MainActor
  private func cancelScheduledRun() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    note("Nothing queued — no background run needed.")
  }

  private func submit() {
    let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
    // Agents that search the web need connectivity before iOS bothers
    // waking us; a purely on-device run doesn't.
    request.requiresNetworkConnectivity = WebSearchConfig.current.isUsable
    request.requiresExternalPower = false
    do {
      try BGTaskScheduler.shared.submit(request)
      note("Background run scheduled.")
    } catch {
      // Expected on the simulator (BGTaskScheduler is unavailable there).
      note("Background scheduling unavailable: \(error.localizedDescription)")
    }
  }

  private func handle(_ task: BGProcessingTask) {
    // Chain the next slot straight away so pending work keeps flowing even if
    // this run is cut short. The handler runs off the main actor, which owns
    // the scheduling state.
    Task { @MainActor in self.scheduleBackgroundRun() }

    let work = Task { [weak self] in
      await self?.drainQueue()
      task.setTaskCompleted(success: true)
    }
    task.expirationHandler = {
      work.cancel()  // drainQueue requeues the in-flight job on cancellation
    }
  }

  // MARK: - The actual work loop

  private func drainQueue() async {
    guard let store else { return }
    let brain = AgentBrains.best()
    // Preferences are read once per drain, so a job can't half-run with web
    // research toggled mid-flight.
    let research = WebSearchConfig.current.makeResearcher()

    while !Task.isCancelled {
      guard let jobID = try? await store.queuedJobIDs().first else { return }

      do {
        try await store.markRunning(jobID)
        try await store.appendProgress(jobID, line: "Started with \(brain.name).")
        if let research {
          try await store.appendProgress(
            jobID, line: "Web research on via \(research.providerName).")
        }

        let (title, prompt) = try await jobText(jobID, store: store)
        let result = try await brain.run(
          title: title, prompt: prompt, research: research
        ) { line in
          try? await store.appendProgress(jobID, line: line)
        }

        try await store.complete(jobID, result: result, brain: brain.name)
        await AgentNotifier.agentFinished(
          id: jobID, title: title, summary: result.summary,
          meetsRequest: result.meetsRequest, gaps: result.gaps.count)
      } catch is CancellationError {
        // Requeued, not finished — nothing to announce.
        try? await store.requeue(jobID)
        return
      } catch {
        try? await store.fail(jobID, message: error.localizedDescription)
        await AgentNotifier.agentFailed(
          id: jobID, title: (try? await store.titleAndPrompt(jobID).0) ?? "Agent",
          message: error.localizedDescription)
      }
    }
  }

  private func jobText(_ id: UUID, store: AgentStore) async throws -> (String, String) {
    try await store.titleAndPrompt(id)
  }

  private func note(_ text: String) {
    DispatchQueue.main.async { self.lastScheduleNote = text }
  }
}
