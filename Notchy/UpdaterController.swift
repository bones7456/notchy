import Foundation
import Sparkle

@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    /// An update Sparkle has already downloaded and staged, waiting to be installed.
    struct PendingUpdate {
        let version: String
        /// Installs it and relaunches, with no UI of its own. Safe to call more
        /// than once (Sparkle 2.3+) — a cancelled termination leaves it valid.
        let install: () -> Void
    }

    /// Assigned in `init` right after `super.init()`, which is the earliest
    /// point `self` can be handed to Sparkle: `SPUUpdater` takes its delegate
    /// at construction and exposes no setter afterwards.
    private var controller: SPUStandardUpdaterController!

    /// Non-nil once Sparkle has staged an update to install on quit. Notchy is
    /// a menu-bar app that can go weeks without quitting, so this drives a
    /// badge on the status item rather than waiting for the user to terminate.
    private(set) var pendingUpdate: PendingUpdate?

    /// Fires on the main actor whenever `pendingUpdate` changes.
    var onPendingUpdateChanged: (() -> Void)?

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Install the staged update now and relaunch. No-op when nothing is staged.
    func installPendingUpdate() {
        pendingUpdate?.install()
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle downloads updates in the background and, by default, installs
    /// them silently the next time the app quits. That never happens for a
    /// menu-bar app left running for days — and Sparkle's own fallback is
    /// slow: once an update is staged, `SPUUpdater` stretches the next check to
    /// `MAX(checkInterval, impatientInterval)`, and the impatient interval
    /// defaults to a week.
    ///
    /// Returning `true` takes over installation: it stalls Sparkle's update
    /// cycle and hands us `immediateInstallHandler`, which installs and
    /// relaunches without any UI. That handler is only available to a delegate
    /// that returns `true`. Either way Sparkle still installs on quit, so the
    /// worst case is the behaviour we already had.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            pendingUpdate = PendingUpdate(version: version, install: immediateInstallHandler)
            onPendingUpdateChanged?()
        }
        return true
    }
}
