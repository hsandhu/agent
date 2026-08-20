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
}
