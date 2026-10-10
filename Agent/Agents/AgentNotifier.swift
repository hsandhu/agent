import Foundation
import UserNotifications

/// Tells the user an agent has finished.
///
/// Background agents are the whole point of the app, and a job that completes
/// while the app is closed is otherwise invisible until the user happens to
/// open it. Local notifications need no entitlement and no server — the
/// request is scheduled from whichever executor finished the work, foreground
/// or `BGProcessingTask`.
enum AgentNotifier {

  /// Asks for permission the first time it could actually be useful.
  ///
  /// Called when an agent is spawned rather than at launch: at that moment
  /// the user has just asked for work to happen in the background, so the
  /// system prompt arrives with its reason already obvious. Permission is the
  /// user's to give — a refusal is remembered by iOS and simply means no
  /// notifications, never a retry loop.
  static func requestAuthorizationIfNeeded() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
  }

  /// Posts the "finished" notification for a job, if the user allowed them.
  ///
  /// `meetsRequest` is carried through rather than inferred: an agent that
  /// stopped short of what was asked should not announce itself the same way
  /// as one that delivered, or the notification quietly overstates the work.
  static func agentFinished(
    id: UUID, title: String, summary: String?, meetsRequest: Bool, gaps: Int
  ) async {
    await post(
      id: id,
      title: title,
      subtitle: meetsRequest
        ? "Done — the request was met."
        : "Done, but short of the request\(gaps > 0 ? " · \(gaps) gap\(gaps == 1 ? "" : "s")" : "").",
      body: summary.map { Self.firstSentences(of: $0) } ?? "")
  }

  /// Posts the "failed" notification for a job.
  static func agentFailed(id: UUID, title: String, message: String) async {
    await post(id: id, title: title, subtitle: "Couldn't finish.", body: message)
  }

  // MARK: - Private

  private static func post(id: UUID, title: String, subtitle: String, body: String) async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized
      || settings.authorizationStatus == .provisional
    else { return }

    let content = UNMutableNotificationContent()
    content.title = title
    content.subtitle = subtitle
    content.body = body
    content.sound = .default
    // The job's own id, so a second run of the same agent replaces its
    // earlier notification instead of stacking another one up.
    content.userInfo = ["jobID": id.uuidString]

    // nil trigger delivers as soon as the system will take it, which is what
    // we want — the work is already done.
    let request = UNNotificationRequest(
      identifier: id.uuidString, content: content, trigger: nil)
    try? await center.add(request)
  }

  /// A notification body is a couple of lines at most, and the spoken summary
  /// is written to be read aloud in full — so take the opening of it rather
  /// than letting iOS cut a sentence in half.
  private static func firstSentences(of summary: String, limit: Int = 160) -> String {
    let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    let clipped = trimmed.prefix(limit)
    if let end = clipped.lastIndex(where: { ".!?".contains($0) }) {
      return String(clipped[...end])
    }
    guard let space = clipped.lastIndex(of: " ") else { return String(clipped) + "…" }
    return String(clipped[..<space]) + "…"
  }
}

/// Shows the banner even while the app is open.
///
/// Without this iOS silently drops the alert whenever the app is frontmost,
/// which would mean no notification at all for the foreground run path — the
/// only path on the simulator, and a common one on device.
final class AgentNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
  static let shared = AgentNotificationPresenter()

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
