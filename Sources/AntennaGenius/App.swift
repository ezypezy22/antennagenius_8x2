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

    /// Runs on every quit path (Cmd-Q, Dock, last window). The watchdog lives off the main thread so a stuck
    /// main thread or network teardown can't leave a zombie process holding UDP 9007.
    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.armWatchdog()
    }

    private static var watchdogArmed = false

    /// Idempotent: quit() and applicationWillTerminate both arm it, but one _exit timer is enough.
    private static func armWatchdog() {
        guard !watchdogArmed else { return }
        watchdogArmed = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { _exit(0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces: if the delegate hook above isn't honoured, quit when no real window remains.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // Closing the main panel ends the app even if Settings or the log window is still open.
            if (note.object as? NSWindow)?.title == "Antenna Genius" { AppDelegate.quit(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let open = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.level == .normal }
                if !open { AppDelegate.quit() }
            }
        }
    }

    static func quit() {
        armWatchdog()
        NSApp.terminate(nil)
    }
}

@main
struct AntennaGeniusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() { exitIfAlreadyRunning() }

    @StateObject private var discovery = Discovery()
    @StateObject private var client = AGClient()

    var body: some Scene {
        // A single-instance Window (not WindowGroup): the port choice and device session are app-wide, so no second window.
        Window("Antenna Genius", id: "main") {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(client)
                                .onAppear { discovery.start() }
        }
        .windowResizability(.contentSize)

        // Real windows (not sheets) so they can be moved, left open beside the panel, and resized.
        Window("Antenna Genius Settings", id: "settings") {
            SettingsWindowRoot().environmentObject(client)
        }
        .windowResizability(.contentMinSize)

        Window("Protocol log", id: "log") {
            LogWindowRoot().environmentObject(client)
        }
        .defaultSize(width: 680, height: 360)
    }
}
