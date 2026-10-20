import SwiftUI
import AppKit

/// Two copies would fight over UDP 9007 and the device's client slots, so hand off to the running one.
private func exitIfAlreadyRunning() {
    guard let id = Bundle.main.bundleIdentifier else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me })
    else { return }
    let alert = NSAlert()
    alert.messageText = "Antenna Genius is already running"
    alert.informativeText = "Only one copy can control the device at a time. Switching to the one that's already open."
    alert.addButton(withTitle: "OK")
    alert.runModal()
    other.activate(options: [.activateAllWindows])
    exit(0)
}

/// Quitting must always work: closing the last window ends the process, and a stalled shutdown is forced.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: if the delegate hook above isn't honoured, quit when no real window remains.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let open = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }
                if !open { AppDelegate.quit() }
            }
        }
    }

    static func quit() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
}

@main
struct AntennaGeniusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() { exitIfAlreadyRunning() }

    @StateObject private var discovery = Discovery()
    @StateObject private var client = AGClient()

    var body: some Scene {
        WindowGroup("Antenna Genius") {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(client)
                                .onAppear { discovery.start() }
        }
        .windowResizability(.contentSize)
    }
}
