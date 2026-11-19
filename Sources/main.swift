import Cocoa

// A borderless panel returns false from canBecomeKey, which blocks typing.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Single instance: a second copy splits windows, events, and permissions.
// Wait briefly so a launch-agent restart can replace the dying process.
let myPid = ProcessInfo.processInfo.processIdentifier
for _ in 0..<30 {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.meshvault.piorb")
        .filter { $0.processIdentifier != myPid && !$0.isTerminated }
    if others.isEmpty { break }
    Thread.sleep(forTimeInterval: 0.1)
}
if NSRunningApplication.runningApplications(withBundleIdentifier: "ai.meshvault.piorb")
    .contains(where: { $0.processIdentifier != myPid && !$0.isTerminated }) {
    print("Kodros Orb is already running. This copy exits.")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
