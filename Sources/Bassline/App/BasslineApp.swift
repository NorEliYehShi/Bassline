import AppKit
import SwiftUI

@main
struct BasslineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Bassline", systemImage: "waveform") {
            MenuView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var spotifyWatcher: SpotifyWatcher?
    private var overlayController: OverlayController?
    private var isTearingDown = false

    /// Hard limit on shutdown. Tearing down a Core Audio tap can block if the
    /// HAL is wedged, and a menu bar app that will not quit has to be force
    /// killed. Exiting late is better than hanging.
    private static let teardownTimeout: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard #available(macOS 14.2, *) else {
            log.error("Bassline requires macOS 14.2 or later")
            StatusCenter.shared.set(.failed("macOS 14.2 or later is required"))
            return
        }

        let controller = OverlayController()
        overlayController = controller

        let watcher = SpotifyWatcher { [weak controller] engine in
            controller?.engine = engine
        }
        watcher.start()
        spotifyWatcher = watcher
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTearingDown else { return .terminateNow }
        isTearingDown = true

        // Take the overlay down immediately so quitting always looks instant,
        // even if the audio teardown below is slow.
        overlayController?.tearDown()
        overlayController = nil

        let watchdog = DispatchWorkItem {
            log.error("Teardown exceeded \(Int(Self.teardownTimeout), privacy: .public)s, exiting anyway")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.teardownTimeout, execute: watchdog)

        // Stopping the tap talks to the HAL, so keep it off the main thread.
        let watcher = spotifyWatcher
        spotifyWatcher = nil
        DispatchQueue.global(qos: .userInitiated).async {
            watcher?.stop()
            DispatchQueue.main.async {
                watchdog.cancel()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController?.tearDown()
        overlayController = nil
    }
}
