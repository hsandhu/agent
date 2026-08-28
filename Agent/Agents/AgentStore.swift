import Foundation
import SwiftData

/// Serialized access to the agent database from any executor (the UI, the
/// foreground runner, or a BGProcessingTask) — SwiftData contexts are not
/// thread-safe, so all background mutations go through this actor.
@ModelActor
actor AgentStore {

  func queuedJobIDs() throws -> [UUID] {
    let queued = AgentJobStatus.queued.rawValue
    let descriptor = FetchDescriptor<AgentJob>(
      predicate: #Predicate { $0.statusRaw == queued },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    return try modelContext.fetch(descriptor).map(\.id)
  }

  func markRunning(_ id: UUID) throws {
    guard let job = try job(id) else { return }
    job.status = .running
    job.startedAt = Date()
    try modelContext.save()
  }

  func appendProgress(_ id: UUID, line: String) throws {
    guard let job = try job(id) else { return }
    job.progressLog += job.progressLog.isEmpty ? line : "\n" + line
    try modelContext.save()
  }

  func complete(
    _ id: UUID, summary: String, detail: String, brain: String, sources: [WebSource]
  ) throws {
    guard let job = try job(id) else { return }
    job.status = .completed
    job.finishRun()
    job.resultSummary = summary
    job.resultDetail = detail
    job.brainUsed = brain
    job.sourcesJSON = sources.isEmpty ? nil : Self.encode(sources)
    try modelContext.save()
  }

  private static func encode(_ sources: [WebSource]) -> String? {
    guard let data = try? JSONEncoder().encode(sources) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func fail(_ id: UUID, message: String) throws {
    guard let job = try job(id) else { return }
    job.status = .failed
    // A failed run still counts against the schedule: a repeating agent
    // retries on its next slot rather than hammering the same broken query.
    job.finishRun()
    job.errorMessage = message
    try modelContext.save()
  }

  /// Puts a job interrupted mid-run (task expired, app killed) back in line.
  func requeue(_ id: UUID) throws {
    guard let job = try job(id) else { return }
    job.status = .queued
    job.startedAt = nil
    try modelContext.save()
  }

  /// Any job stuck in `running` from a previous process death is requeued.
  func requeueOrphanedRunningJobs() throws {
    let running = AgentJobStatus.running.rawValue
    let descriptor = FetchDescriptor<AgentJob>(
      predicate: #Predicate { $0.statusRaw == running })
    for job in try modelContext.fetch(descriptor) {
      job.status = .queued
      job.startedAt = nil
    }
    try modelContext.save()
  }

  // MARK: - Repeating agents

  /// Puts every repeating agent whose next slot has arrived back in the
  /// queue. The previous result stays on the job until the new run replaces
  /// it, so the UI never shows a blank while it re-runs.
  @discardableResult
  func requeueDueRepeatingJobs() throws -> Int {
    // `nextRunAt` is only ever set on repeating jobs, so this is the whole
    // candidate set; the due/status check is cheap enough in memory.
    let descriptor = FetchDescriptor<AgentJob>(predicate: #Predicate { $0.nextRunAt != nil })
    let due = try modelContext.fetch(descriptor).filter(\.isDueToRun)
    guard !due.isEmpty else { return 0 }

    for job in due {
      job.status = .queued
      job.startedAt = nil
      job.errorMessage = nil
      job.nextRunAt = nil
      job.progressLog = ""
    }
    try modelContext.save()
    return due.count
  }

  /// When the earliest repeating agent is next due, if any.
  func nextScheduledRunDate() throws -> Date? {
    let descriptor = FetchDescriptor<AgentJob>(predicate: #Predicate { $0.nextRunAt != nil })
    return try modelContext.fetch(descriptor).compactMap(\.nextRunAt).min()
  }

  func titleAndPrompt(_ id: UUID) throws -> (String, String) {
    guard let job = try job(id) else {
      throw NSError(
        domain: "AgentStore", code: 404,
        userInfo: [NSLocalizedDescriptionKey: "Agent no longer exists."])
    }
    return (job.title, job.prompt)
  }

  private func job(_ id: UUID) throws -> AgentJob? {
    let descriptor = FetchDescriptor<AgentJob>(predicate: #Predicate { $0.id == id })
    return try modelContext.fetch(descriptor).first
  }
}
