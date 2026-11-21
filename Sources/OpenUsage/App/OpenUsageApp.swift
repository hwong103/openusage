import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let processStartedAt = ProcessInfo.processInfo.systemUptime
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    private var singleInstanceLock: SingleInstanceLock.Token?
    private let updater = UpdaterController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.bootstrap()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        if let bundleID = Bundle.main.bundleIdentifier {
            switch SingleInstanceLock.acquire(bundleIdentifier: bundleID) {
            case .acquired(let token):
                singleInstanceLock = token
            case .alreadyRunning:
                // Hand the request to the copy that owns the lock. A menu-bar accessory has no normal
                // window to activate, so an activation alone leaves it running with nothing visible.
                // The owner observes this distributed notification and presents its panel.
                DistributedNotificationCenter.default().postNotificationName(
                    .openUsageShowPopover,
                    object: nil,
                    userInfo: nil,
                    options: [.deliverImmediately]
                )
                let myPID = NSRunningApplication.current.processIdentifier
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first { $0.processIdentifier != myPID && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }?
                    .activate()
                NSApp.terminate(nil)
                return
            case .failed(let message):
                AppLog.error(.lifecycle, "single-instance lock unavailable: \(message)")
            }
        }
        NSApp.disableRelaunchOnLogin()
        #if OPENUSAGE_DEVELOPMENT
        if Bundle.main.bundleIdentifier == DevelopmentDataMode.demoBundleID {
            let container = DemoSession.makeContainer(defaults: .standard)
            AppearanceSetting.applyCurrent()
            self.container = container
            container.startRefreshing()
            statusItemController = StatusItemController(container: container, updater: updater)
            return
        }
        #endif
        AppearanceSetting.applyCurrent()
        let container = AppContainer(telemetry: PostHogTelemetrySink(), telemetryDefaults: TelemetryRecorder.suite)
        self.container = container
        CommandCodeSpendHistoryStore.migrateLegacyIfUnaffected(
            existingAccountIDs: container.accounts.accounts
                .filter { $0.kind == .commandcode }
                .map(\.cardID)
        )
        Task { await CommandCodeV1Files.importOnce(into: container.accounts) }
        container.startRefreshing()
        Task { await APIKeyV1Files.importOnce(into: container.accounts) }
        statusItemController = StatusItemController(container: container, updater: updater)
        let launchDurationMS = Int((ProcessInfo.processInfo.systemUptime - processStartedAt) * 1_000)
        AppLog.info(.lifecycle, "launch to status item ready: \(launchDurationMS) ms")
        updater.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
    }

    public func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        statusItemController?.showPopover()
        return true
    }
}
