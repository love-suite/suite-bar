import AppKit
import SuiteCore
import os

/// Temporary, to find why the Dock sometimes doesn't slide in when the pointer reaches its edge: a
/// listen-only event tap watches the pointer beside the Dock's mouse monitors, and each time the tap
/// sees the pointer arrive at the edge while the monitors didn't, it is logged, with an hourly count
/// of the pointer's visits to the edge (`log show --predicate 'category == "BarEdge"' --last 1d`).
/// Remove it once the cause is known.
final class BarEdgeProbe {
    private let log = Logger(subsystem: "local.suite.bar", category: "BarEdge")
    private var tap: CFMachPort?
    private var summaryTimer: Timer?
    private var atEdge: (NSPoint) -> Bool = { _ in false }
    private var describe: () -> String = { "" }

    /// System uptimes.
    private var lastMonitorEvent: TimeInterval = 0
    private var lastMonitorAtEdge: TimeInterval = 0
    /// The tap's pointer is at the edge since this visit began.
    private var tapAtEdge = false
    private var visits = 0
    private var misses = 0

    /// `atEdge`: whether a point (bottom-left origin) would slide the Dock in; `describe`: the state to log.
    func start(atEdge: @escaping (NSPoint) -> Bool, describe: @escaping () -> String) {
        self.atEdge = atEdge
        self.describe = describe
        guard tap == nil else { return }
        let mask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let probe = Unmanaged<BarEdgeProbe>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = probe.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    probe.tapSaw(event.location)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                          options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.notice("no event tap, nothing to compare")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        summaryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            log.notice("in the last hour: \(self.visits) visits to the edge, \(self.misses) missed by the monitors")
            visits = 0
            misses = 0
        }
        log.notice("watching the edge, build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", privacy: .public)")
    }

    /// From the Dock's mouse monitors, global and local.
    func monitorSaw(_ point: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        lastMonitorEvent = now
        if atEdge(point) { lastMonitorAtEdge = now }
    }

    /// The tap's point has its origin at the top left of the main screen.
    private func tapSaw(_ location: CGPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: location.x, y: height - location.y)
        guard atEdge(point) else {
            tapAtEdge = false
            return
        }
        guard !tapAtEdge else { return }
        tapAtEdge = true
        visits += 1
        let arrived = ProcessInfo.processInfo.systemUptime
        // The monitors get the same event a moment later, or not at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, lastMonitorAtEdge < arrived - 0.05 else { return }
            misses += 1
            let now = ProcessInfo.processInfo.systemUptime
            func ago(_ time: TimeInterval) -> String { time == 0 ? "never" : String(format: "%.2f s ago", now - time) }
            log.notice("""
                monitors missed the edge at \(point.debugDescription, privacy: .public) (miss \(self.misses) of \
                \(self.visits) visits this hour); monitors: last event \(ago(self.lastMonitorEvent), privacy: .public), \
                at edge \(ago(self.lastMonitorAtEdge), privacy: .public); \(self.describe(), privacy: .public)
                """)
        }
    }

    /// The Dock's own pointer check found the edge with no slide-in on its way (builds that have it).
    func pointerCheckCaught(_ point: NSPoint) {
        log.notice("pointer check caught the edge at \(point.debugDescription, privacy: .public); \(self.describe(), privacy: .public)")
    }
}
