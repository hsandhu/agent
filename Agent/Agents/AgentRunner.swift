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

  /// How often the foreground app re-checks whether a repeating agent has
  /// come due. The floor between runs is a day, so being a few minutes late
  /// costs nothing and this stays out of the way.
  private static let dueCheckInterval: Duration = .seconds(300)

  private var store: AgentStore?
  private var foregroundTask: Task<Void, Never>?
  private var dueWatcher: Task<Void, Never>?

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
  func runQueuedJobsSoon() {
    startDueWatcher()
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

  // MARK: - Repeating agents while the app is open

  /// Repeating agents can come due with the app already in the foreground,
  /// where no background slot is coming to notice it.
  private func startDueWatcher() {
    guard dueWatcher == nil, let store else { return }
    dueWatcher = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.dueCheckInterval)
        guard !Task.isCancelled, let self else { return }
        let requeued = (try? await store.requeueDueRepeatingJobs()) ?? 0
        if requeued > 0 { self.runQueuedJobsSoon() }
      }
    }
  }

  private func stopDueWatcher() {
    dueWatcher?.cancel()
    dueWatcher = nil
  }

  // MARK: - Background scheduling

  /// Ask the system for a background slot. Call when the app backgrounds.
  func scheduleBackgroundRun() {
    stopDueWatcher()
    guard let store else { return submit(earliestBeginDate: nil) }
    Task { [weak self] in
      let queued = (try? await store.queuedJobIDs()) ?? []
      let nextScheduled = (try? await store.nextScheduledRunDate()) ?? nil
      guard !queued.isEmpty || nextScheduled != nil else {
        self?.note("Nothing pending — no background run needed.")
        return
      }
      // Work already queued should run at the first opportunity; a repeating
      // agent shouldn't wake the device before its slot.
      self?.submit(earliestBeginDate: queued.isEmpty ? nextScheduled : nil)
    }
  }

  private func submit(earliestBeginDate: Date?) {
    let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
    // Agents that search the web need connectivity before iOS bothers
    // waking us; a purely on-device run doesn't.
    request.requiresNetworkConnectivity = WebSearchConfig.current.isUsable
    request.requiresExternalPower = false
    request.earliestBeginDate = earliestBeginDate
    do {
      try BGTaskScheduler.shared.submit(request)
      if let earliestBeginDate {
        note("Next run scheduled \(earliestBeginDate.formatted(.relative(presentation: .named))).")
      } else {
        note("Background run scheduled.")
      }
    } catch {
      // Expected on the simulator (BGTaskScheduler is unavailable there).
      note("Background scheduling unavailable: \(error.localizedDescription)")
    }
  }

  private func handle(_ task: BGProcessingTask) {
    // Chain the next slot first so pending work keeps flowing even if this
    // run is cut short.
    scheduleBackgroundRun()

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
    // Repeating agents whose slot has arrived join this pass.
    _ = try? await store.requeueDueRepeatingJobs()
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

        try await store.complete(
          jobID, summary: result.summary, detail: result.detail, brain: brain.name,
          sources: result.sources)
      } catch is CancellationError {
        try? await store.requeue(jobID)
        return
      } catch {
        try? await store.fail(jobID, message: error.localizedDescription)
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
