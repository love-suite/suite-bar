import AppKit
import DockGuard
import BarSettings
import ServiceManagement
import SuiteCore

/// The messages between two copies of the Dock: the new one asks the running one to leave.
enum BarRelaunch: String {
    case handOver

    var name: Notification.Name { Notification.Name("local.suite.bar." + rawValue) }

    func post() {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The Dock keeps itself up to date from its own releases, whenever one comes: the new copy takes over
    /// from this one (`--relaunch`), which leaves without putting the system Dock back.
    static let updater = SuiteUpdater(appName: "Dock", isBusy: { false }, relaunch: {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = ["--relaunch"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    })

    /// Leaving for a newer copy, or with the Mac: the system Dock stays hidden (Suite Guard puts it back
    /// should the Dock not come back), as each Dock restart leaves Spaces, ⌘Tab and Mission Control unusable
    /// for a minute or two.
    private var isHandingOver = false
    private var isPoweringOff = false
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: BarRelaunch.handOver.name, object: nil, queue: .main) {
            [weak self] _ in
            self?.isHandingOver = true
            NSApp.terminate(nil)
        })
        observers.append(BarMessage.applySettings.observe { _ in
            CFPreferencesAppSynchronize(BarSettings.domain as CFString)
            Self.updater.bringSettingsUpToDate()
            BarSettings.reloadFromDefaults()
        })
        observers.append(BarMessage.allowWindowFitting.observe { _ in WindowFitter.askForPermission() })
        observers.append(BarMessage.reportStatus.observe { [weak self] _ in self?.report() })
        for name in [BarSettings.didChange, WindowFitter.permissionDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.report()
            })
        }
        observers.append(BarSettings.didChange.observeHere { [weak self] in self?.quitIfTurnedOff() })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.isPoweringOff = true }
        quitOnSignals()
        BarController.shared.start()
        Self.updater.start()
        report()
        quitIfTurnedOff()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit by you or turned off: the system Dock comes back as it was, so the Mac is never left without
        // one. Not for a newer copy nor at logout or shutdown.
        if !isHandingOver && !isPoweringOff {
            BarController.restoreSystemDock()
        }
        BarController.shared.stop()
    }

    /// Turned off (Settings › Bar: System Dock): the system Dock back, and the Dock leaves until turned on.
    /// Turned on, it starts at login by itself (its own login item), whichever other app of the suite runs.
    private func quitIfTurnedOff() {
        let shown = BarSettings.current.isShown
        setLoginItem(shown)
        guard !shown else { return }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Bar's own login item: only the app itself can register it.
    private func setLoginItem(_ on: Bool) {
        let registered = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        guard on != registered else { return }
        do {
            on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            NSLog("Bar: could not change the login item: \(error)")
        }
    }

    /// Writes down what the Dock tab shows about the Dock, then says so.
    private func report() {
        BarSettings.defaults.set(WindowFitter.isPermitted, forKey: BarMessage.StatusKey.windowFittingAllowed)
        BarMessage.statusDidChange.post()
    }

    /// Ctrl+C, closing the terminal or `kill` would otherwise leave the user without a Dock.
    private func quitOnSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}

private extension Notification.Name {
    func observeHere(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: self, object: nil, queue: .main) { _ in handler() }
    }
}
