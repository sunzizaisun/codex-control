import Foundation
import WatchKit

/// Coordinates the small, system-granted background windows that watchOS gives
/// a companion app.  This is deliberately not an extended runtime session:
/// Codex Control is not a workout/navigation app, and watchOS would suspend it.
@MainActor
final class WatchBackgroundRefreshCoordinator {
    static let shared = WatchBackgroundRefreshCoordinator()

    private var handler: ((WKRefreshBackgroundTask) -> Void)?
    // watchOS can wake the extension before SwiftUI has run the WindowGroup
    // task that installs the controller. Keep that short system window alive
    // and hand it to the controller as soon as the scene is ready instead of
    // incorrectly completing it as a failed refresh.
    private var pendingTasks: [WKRefreshBackgroundTask] = []

    func install(handler: @escaping (WKRefreshBackgroundTask) -> Void) {
        self.handler = handler
        let pending = pendingTasks
        pendingTasks.removeAll()
        pending.forEach(handler)
    }

    func handle(_ task: WKRefreshBackgroundTask) {
        guard let handler else {
            pendingTasks.append(task)
            return
        }
        handler(task)
    }
}

final class CodexWatchApplicationDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            Task { @MainActor in
                WatchBackgroundRefreshCoordinator.shared.handle(task)
            }
        }
    }
}
