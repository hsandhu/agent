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
    job.completedAt = Date()
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
    job.completedAt = Date()
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
