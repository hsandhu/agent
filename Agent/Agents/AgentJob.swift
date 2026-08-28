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

/// How often a repeatable agent re-runs itself.
///
/// Background execution is opportunistic and every run costs battery, network,
/// and (for research agents) somebody's rate limit, so a day is the floor —
/// see `AgentJob.minimumRepeatIntervalHours`.
enum AgentRepeat: Int, CaseIterable, Identifiable {
  case never = 0
  case daily = 24
  case everyThreeDays = 72
  case weekly = 168

  var id: Int { rawValue }

  /// Hours between runs, or nil for a one-shot agent.
  var hours: Int? { self == .never ? nil : rawValue }

  var label: String {
    switch self {
    case .never: return "Don't repeat"
    case .daily: return "Every day"
    case .everyThreeDays: return "Every 3 days"
    case .weekly: return "Every week"
    }
  }

  /// Compact form for the list row and the detail chip.
  var shortLabel: String {
    switch self {
    case .never: return "Once"
    case .daily: return "Daily"
    case .everyThreeDays: return "Every 3d"
    case .weekly: return "Weekly"
    }
  }

  init(hours: Int?) {
    guard let hours else {
      self = .never
      return
    }
    self = AgentRepeat(rawValue: hours) ?? .daily
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
  /// Hours between runs for a repeating agent; nil means it runs once.
  /// Optional so the store migrates lightweightly from one-shot-only jobs.
  var repeatIntervalHours: Int?
  /// When a repeating agent is next due. Nil while it is queued or running,
  /// and always nil for a one-shot agent.
  var nextRunAt: Date?
  /// How many times this agent has finished, successfully or not.
  var runCount: Int = 0

  init(title: String, prompt: String, repeats: AgentRepeat = .never) {
    self.id = UUID()
    self.title = title
    self.prompt = prompt
    self.statusRaw = AgentJobStatus.queued.rawValue
    self.createdAt = Date()
    self.progressLog = ""
    self.repeatIntervalHours = repeats.hours
  }

  /// The shortest repeat we accept. Anything below this is clamped up.
  static let minimumRepeatIntervalHours = 24

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

  // MARK: - Repeating

  var repeatSchedule: AgentRepeat { AgentRepeat(hours: repeatIntervalHours) }

  var repeats: Bool { repeatIntervalHours != nil }

  /// Seconds between runs, with the 24-hour floor applied. Nil when one-shot.
  var repeatInterval: TimeInterval? {
    guard let repeatIntervalHours else { return nil }
    return TimeInterval(max(Self.minimumRepeatIntervalHours, repeatIntervalHours) * 3600)
  }

  /// Whether the next run is due now.
  var isDueToRun: Bool {
    guard let nextRunAt, status == .completed || status == .failed else { return false }
    return nextRunAt <= Date()
  }

  /// Switch the schedule, keeping `nextRunAt` consistent with it.
  func applyRepeat(_ schedule: AgentRepeat) {
    repeatIntervalHours = schedule.hours
    guard let interval = repeatInterval else {
      nextRunAt = nil
      return
    }
    switch status {
    case .completed, .failed:
      // Measure from the last run, but never schedule into the past.
      nextRunAt = max((completedAt ?? Date()).addingTimeInterval(interval), Date())
    case .queued, .running:
      // It is about to run anyway; the next slot is booked when it finishes.
      nextRunAt = nil
    }
  }

  /// Records the end of a run and books the next one when repeating.
  func finishRun(at date: Date = Date()) {
    runCount += 1
    completedAt = date
    nextRunAt = repeatInterval.map { date.addingTimeInterval($0) }
  }
}
