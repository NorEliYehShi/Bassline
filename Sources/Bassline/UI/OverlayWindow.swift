import AppKit
import Combine
import Foundation

/// Owns the borderless overlay window and decides when it should be on screen
/// at all.
///
/// When audio stops, the renderer signals idle, the window is ordered out and
/// the display link is invalidated, so a paused track costs no CPU and no
/// compositor work. A low-frequency watchdog wakes everything back up when the
/// analyzer starts producing frames again.
final class OverlayController {
    private var window: NSWindow?
    private var waveView: WaveView?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var backdropTimer: Timer?
    private var wakeTimer: Timer?

    /// Polling interval while idle. Cheap enough to be invisible in Activity
    /// Monitor, fast enough that playback starts look instant.
    private static let wakeInterval: TimeInterval = 0.5
    private static let backdropInterval: TimeInterval = 60

    var engine: AudioEngine? {
        didSet {
            waveView?.engine = engine
            if engine != nil {
                wake()
            } else {
                goIdle()
            }
        }
    }

    init() {
        createWindow()
        observeScreenChanges()
        observeSettings()
        observeBackdrop()
        startWakeTimer()
    }

    func tearDown() {
        cancellables.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        screenObserver = nil
        spaceObserver = nil
        backdropTimer?.invalidate()
        backdropTimer = nil
        wakeTimer?.invalidate()
        wakeTimer = nil
        waveView?.stopDisplayLink()
        window?.orderOut(nil)
        window?.close()
        window = nil
        waveView = nil
    }

    // MARK: - Window

    private func createWindow() {
        let settings = Settings.shared
        guard let frame = stripFrame(for: settings.selectedScreen, height: settings.stripHeight) else {
            log.error("No display available, overlay not created")
            return
        }

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.alphaValue = CGFloat(settings.opacity)
        window.displaysWhenScreenProfileChanges = true

        let view = WaveView(frame: NSRect(origin: .zero, size: frame.size))
        view.style = settings.style
        view.tint = settings.tint
        view.lowPowerMode = settings.lowPowerMode
        view.engine = engine
        view.onIdle = { [weak self] in self?.goIdle() }
        window.contentView = view

        self.window = window
        waveView = view
    }

    private func stripFrame(for screen: NSScreen?, height: Double) -> NSRect? {
        guard let screen else { return nil }
        let screenFrame = screen.frame
        let clamped = min(CGFloat(height), screenFrame.height)
        return NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: screenFrame.width,
            height: clamped
        )
    }

    // MARK: - Idle and wake

    private func wake() {
        guard let window, let waveView else { return }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
        waveView.startDisplayLink()
    }

    private func goIdle() {
        waveView?.stopDisplayLink()
        window?.orderOut(nil)
    }

    private func startWakeTimer() {
        wakeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.wakeInterval, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine, let waveView = self.waveView else { return }
            guard !waveView.isRunning, engine.hasNewFrames() else { return }
            self.wake()
        }
        timer.tolerance = Self.wakeInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    // MARK: - Observation

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Settings.shared.clampStripHeight()
            self?.repositionWindow()
        }
    }

    private func observeSettings() {
        let settings = Settings.shared

        settings.$opacity
            .removeDuplicates()
            .sink { [weak self] value in
                self?.window?.alphaValue = CGFloat(value)
            }
            .store(in: &cancellables)

        settings.$style
            .removeDuplicates()
            .sink { [weak self] value in
                self?.waveView?.style = value
            }
            .store(in: &cancellables)

        settings.$tint
            .removeDuplicates()
            .sink { [weak self] value in
                self?.waveView?.tint = value
            }
            .store(in: &cancellables)

        settings.$lowPowerMode
            .removeDuplicates()
            .sink { [weak self] value in
                self?.waveView?.lowPowerMode = value
            }
            .store(in: &cancellables)

        settings.$stripHeight
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.repositionWindow()
            }
            .store(in: &cancellables)

        settings.$screenDisplayID
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.repositionWindow()
                self?.sampleBackdrop()
            }
            .store(in: &cancellables)
    }

    private func observeBackdrop() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sampleBackdrop()
        }

        // Wallpapers rarely change; a long interval with tolerance lets the
        // timer coalesce with other wakeups.
        let timer = Timer(timeInterval: Self.backdropInterval, repeats: true) { [weak self] _ in
            self?.sampleBackdrop()
        }
        timer.tolerance = Self.backdropInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        backdropTimer = timer

        sampleBackdrop()
    }

    private func sampleBackdrop() {
        guard Settings.shared.tint == .auto else { return }
        guard let screen = Settings.shared.selectedScreen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            waveView?.backdropLuminance = nil
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let luminance = BackdropSampler.bottomLuminance(ofWallpaperAt: url)
            DispatchQueue.main.async {
                self?.waveView?.backdropLuminance = luminance
            }
        }
    }

    private func repositionWindow() {
        let settings = Settings.shared
        guard let window,
              let frame = stripFrame(for: settings.selectedScreen, height: settings.stripHeight) else { return }
        window.setFrame(frame, display: true)
        waveView?.frame = NSRect(origin: .zero, size: frame.size)
    }
}
