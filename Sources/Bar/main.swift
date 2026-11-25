import AppKit
import BarSettings
import SuiteCore


// Escape hatch if the Dock was force-killed or crashed while the system Dock was hidden.
if CommandLine.arguments.contains("--restore-bar") {
    BarController.restoreSystemDock()
    exit(0)
}

// One Dock at a time. A copy started with --relaunch (an update, make-app.sh) takes over from the running
// one, which quits without putting the system Dock back; any other copy leaves at once.
let me = ProcessInfo.processInfo.processIdentifier
let others = { NSRunningApplication.runningApplications(withBundleIdentifier: BarSettings.domain)
    .filter { $0.processIdentifier != me && !$0.isTerminated } }
if !others().isEmpty {
    guard CommandLine.arguments.contains("--relaunch") else { exit(0) }
    BarRelaunch.handOver.post()
    let deadline = Date().addingTimeInterval(10)
    while !others().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
