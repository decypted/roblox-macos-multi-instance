import AppKit
import ApplicationServices

// Anti-AFK for every open Roblox window (ported from AntiAFK-RBX).
// Each cycle: wait until the user is idle, bring each Roblox window to the front,
// press the chosen keys, then hand focus back to whatever the user was using.

enum AfkAction: Int, CaseIterable, Identifiable {
    case space = 0, walk = 1, zoom = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .space: return "Jump (Space)"
        case .walk: return "Step (W / S)"
        case .zoom: return "Zoom (I / O)"
        }
    }
}

@MainActor
final class AfkController: ObservableObject {
    static let intervals: [(String, Int)] = [
        ("3 min", 180), ("6 min", 360), ("9 min", 540), ("11 min", 660),
        ("13 min", 780), ("15 min", 900), ("18 min", 1080),
    ]

    @Published private(set) var isRunning = false
    @Published private(set) var busy = false
    @Published private(set) var nextActionAt: Date?
    @Published private(set) var status = "Off"

    private let manager: InstanceManager
    private var timer: Timer?
    private let queue = DispatchQueue(label: "rbxmulti.antiafk")

    init(manager: InstanceManager) {
        self.manager = manager
        UserDefaults.standard.register(defaults: [
            "afkEnabled": false, "afkInterval": 540, "afkAction": 0, "afkWaitIdle": true, "afkReturnFocus": true,
        ])
        if UserDefaults.standard.bool(forKey: "afkEnabled") { start() }
    }

    private var interval: Int { max(30, UserDefaults.standard.integer(forKey: "afkInterval")) }
    private var action: AfkAction { AfkAction(rawValue: UserDefaults.standard.integer(forKey: "afkAction")) ?? .space }
    private var waitIdle: Bool { UserDefaults.standard.bool(forKey: "afkWaitIdle") }
    private var returnFocus: Bool { UserDefaults.standard.bool(forKey: "afkReturnFocus") }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Control

    func start() {
        guard Self.hasAccessibility else {
            status = "Needs Accessibility permission"
            UserDefaults.standard.set(false, forKey: "afkEnabled")
            Self.requestAccessibility()
            objectWillChange.send()
            return
        }
        isRunning = true
        UserDefaults.standard.set(true, forKey: "afkEnabled")
        status = "On"
        schedule()
    }

    func stop() {
        isRunning = false
        UserDefaults.standard.set(false, forKey: "afkEnabled")
        timer?.invalidate()
        timer = nil
        nextActionAt = nil
        status = "Off"
    }

    /// Restart the countdown after the interval changes.
    func reschedule() { if isRunning { schedule() } }

    func runNow() {
        guard Self.hasAccessibility else { Self.requestAccessibility(); return }
        runCycle()
    }

    private func schedule() {
        timer?.invalidate()
        let delay = TimeInterval(interval)
        nextActionAt = Date().addingTimeInterval(delay)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runCycle() }
        }
    }

    private func runCycle() {
        guard !busy else { return }
        manager.refresh()
        let pids = manager.instances.map(\.pid)
        guard !pids.isEmpty else {
            status = "No Roblox windows open, skipped"
            if isRunning { schedule() }
            return
        }
        busy = true
        nextActionAt = nil
        status = "Waiting for you to stop typing…"
        let action = self.action, waitIdle = self.waitIdle, returnFocus = self.returnFocus
        queue.async { [weak self] in
            let result = AfkWorker.run(pids: pids, action: action, waitIdle: waitIdle, returnFocus: returnFocus) { msg in
                DispatchQueue.main.async { self?.status = msg }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.status = result
                if self.isRunning { self.schedule() }
            }
        }
    }

    /// One-line status for the UI, e.g. "Next in 4:12 · Moved 3 windows at 9:41".
    func statusLine(now: Date) -> String {
        if busy { return status }
        if isRunning, let next = nextActionAt {
            let s = max(0, Int(next.timeIntervalSince(now)))
            let countdown = String(format: "Next in %d:%02d", s / 60, s % 60)
            return status == "On" ? countdown : "\(countdown) · \(status)"
        }
        return status
    }
}

// MARK: - Worker (runs off the main thread)

enum AfkWorker {
    static let idleThreshold: TimeInterval = 3
    static let maxIdleWait: TimeInterval = 60

    static func run(pids: [pid_t], action: AfkAction, waitIdle: Bool, returnFocus: Bool,
                    progress: (String) -> Void) -> String {
        if waitIdle {
            let start = Date()
            while userIdleSeconds() < idleThreshold && Date().timeIntervalSince(start) < maxIdleWait {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        let previous = onMain { NSWorkspace.shared.frontmostApplication }
        var sent = 0
        for (i, pid) in pids.enumerated() {
            guard let app = onMain({ NSRunningApplication(processIdentifier: pid) }), !app.isTerminated else { continue }
            progress("Moving window \(i + 1) of \(pids.count)…")
            onMain {
                if app.isHidden { app.unhide() }
                app.activate(options: [.activateAllWindows])
            }
            waitUntilFrontmost(pid, timeout: 1.5)
            Thread.sleep(forTimeInterval: 0.15)
            for _ in 0..<3 { perform(action) }
            sent += 1
            Thread.sleep(forTimeInterval: 0.3)
        }

        if returnFocus, let previous, previous.bundleIdentifier != "com.roblox.RobloxPlayer" {
            Thread.sleep(forTimeInterval: 0.05)
            onMain { _ = previous.activate(options: []) }
        }

        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        return "Moved \(sent) window\(sent == 1 ? "" : "s") at \(time)"
    }

    // MARK: Keys

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func tap(_ key: CGKeyCode, hold: TimeInterval = 0.06) {
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: hold)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }

    private static func perform(_ action: AfkAction) {
        switch action {
        case .space: tap(49)              // Space
        case .walk: tap(13); tap(1)       // W, S
        case .zoom: tap(34); tap(31)      // I, O
        }
    }

    private static func userIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    private static func waitUntilFrontmost(_ pid: pid_t, timeout: TimeInterval) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == pid { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func onMain<T>(_ block: () -> T) -> T {
        Thread.isMainThread ? block() : DispatchQueue.main.sync(execute: block)
    }
}
