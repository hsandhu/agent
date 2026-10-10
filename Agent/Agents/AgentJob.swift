import Foundation
import SwiftData

enum AgentJobStatus: String, Codable, CaseIterable {
  case queued
  case running
  case completed
  case failed

  var label: String {
    switch self {
    case .queued: return "Queued"
    case .running: return "Running"
    case .completed: return "Done"
    case .failed: return "Failed"
    }
  }

  var systemImage: String {
    switch self {
    case .queued: return "clock"
    case .running: return "gearshape.2"
    case .completed: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }
}

/// One background AI agent and everything it produced. All metadata lives
/// on-device in SwiftData; nothing leaves the phone.
@Model
final class AgentJob {
  @Attribute(.unique) var id: UUID
  var title: String
  var prompt: String
  var statusRaw: String
  var createdAt: Date
  var startedAt: Date?
  var completedAt: Date?
  /// Newline-separated progress notes appended while the agent works.
  var progressLog: String
  /// Short spoken-style summary — this is what the play button reads aloud.
  var resultSummary: String?
  /// Full findings.
  var resultDetail: String?
  /// Which brain produced the result (mock, Apple Intelligence, …).
  var brainUsed: String?
  /// Web pages the agent read, JSON-encoded `[WebSource]`. Optional so the
  /// store migrates lightweightly from jobs created before web research.
  var sourcesJSON: String?
  var errorMessage: String?
  /// Whether the model judged the request actually satisfied when it stopped.
  /// Defaults true so agents finished before this check existed aren't
  /// retroactively marked deficient.
  var meetsRequest: Bool = true
  /// Newline-separated shortfalls the reviewer named, when the bar wasn't
  /// met. Optional so the store migrates lightweightly.
  var outstandingGaps: String?
  /// Research-and-write rounds the agent spent before it stopped.
  var rounds: Int = 1

  init(title: String, prompt: String) {
    self.id = UUID()
    self.title = title
    self.prompt = prompt
    self.statusRaw = AgentJobStatus.queued.rawValue
    self.createdAt = Date()
    self.progressLog = ""
  }

  var status: AgentJobStatus {
    get { AgentJobStatus(rawValue: statusRaw) ?? .queued }
    set { statusRaw = newValue.rawValue }
  }

  var progressLines: [String] {
    progressLog.split(separator: "\n").map(String.init)
  }

  /// Sources the agent cited, in citation order.
  var sources: [WebSource] {
    guard let sourcesJSON, let data = sourcesJSON.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([WebSource].self, from: data)) ?? []
  }

  // MARK: - Completion

  /// The shortfalls the reviewer named, in the order it named them.
  var gaps: [String] {
    guard let outstandingGaps, !outstandingGaps.isEmpty else { return [] }
    return outstandingGaps.split(separator: "\n").map(String.init)
  }

  /// A finished agent that stopped short of what was asked. The findings are
  /// still worth reading — they're just not the whole job.
  var finishedShort: Bool { status == .completed && !meetsRequest }

  /// Records how a run ended, including the model's verdict on its own work.
  func finishRun(meetsRequest: Bool, gaps: [String], rounds: Int, at date: Date = Date()) {
    completedAt = date
    self.meetsRequest = meetsRequest
    self.outstandingGaps = gaps.isEmpty ? nil : gaps.joined(separator: "\n")
    self.rounds = max(1, rounds)
  }
}
