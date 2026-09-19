import AppKit
import BasslineCore
import CoreAudio
import Foundation

/// Watches Spotify and keeps a process tap attached to it.
@available(macOS 14.2, *)
final class SpotifyWatcher {
    typealias EngineCallback = (AudioEngine?) -> Void

    private static let bundleIdentifier = "com.spotify.client"
    private static let retryInterval: TimeInterval = 2
    private static let maxRetries = 15

    private let onEngineChanged: EngineCallback
    private var tap: ProcessTap?
    private var engine: AudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var retryTimer: Timer?
    private var retryCount = 0
    private var hasStopped = false
    private var retryRequestObserver: NSObjectProtocol?

    init(onEngineChanged: @escaping EngineCallback) {
        self.onEngineChanged = onEngineChanged
    }

    func start() {
        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter

        retryRequestObserver = NotificationCenter.default.addObserver(
            forName: .basslineRetryRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconnect()
        }

        observers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: workspace,
                queue: .main
            ) { [weak self] note in
                guard Self.isSpotify(note) else { return }
                self?.retryCount = 0
                self?.attach()
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: workspace,
                queue: .main
            ) { [weak self] note in
                guard Self.isSpotify(note) else { return }
                self?.detach(status: .waitingForSpotify)
            },
        ]

        if isSpotifyRunning() {
            attach()
        } else {
            StatusCenter.shared.set(.waitingForSpotify)
        }
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let retryRequestObserver {
            NotificationCenter.default.removeObserver(retryRequestObserver)
        }
        retryRequestObserver = nil
        detach(status: .waitingForSpotify)
    }

    /// Tears the tap down and builds a new one. Used after the user grants the
    /// audio permission, which does not apply to an already-created tap.
    private func reconnect() {
        guard !hasStopped else { return }
        log.info("Reconnect requested")
        detach(status: .connecting)
        retryCount = 0
        guard isSpotifyRunning() else {
            StatusCenter.shared.set(.waitingForSpotify)
            return
        }
        attach()
    }

    private static func isSpotify(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == bundleIdentifier
    }

    private func isSpotifyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleIdentifier }
    }

    private func spotifyProcessObjectID() -> AudioObjectID? {
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == Self.bundleIdentifier })?
            .processIdentifier else { return nil }

        var objectID = AudioObjectID(kAudioObjectUnknown)
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func attach() {
        // Only tear down an existing tap once a replacement is ready, so a
        // retry never blanks the overlay that is already working.
        guard tap == nil else { return }

        guard let objectID = spotifyProcessObjectID() else {
            StatusCenter.shared.set(.connecting)
            scheduleRetry()
            return
        }

        let analyzer = SpectrumAnalyzer()
        let newTap = ProcessTap(targetProcessID: objectID, analyzer: analyzer)
        let newEngine = AudioEngine(analyzer: analyzer)

        newTap.onOutputLatencyChanged = { [weak newEngine] latency in
            newEngine?.outputLatency = latency
        }

        do {
            try newTap.start()
        } catch {
            let caError = error as? CoreAudioError
            log.error("Failed to attach to Spotify: \(String(describing: error), privacy: .public)")
            if caError?.isPermissionFailure == true {
                StatusCenter.shared.set(.permissionDenied)
                return
            }
            StatusCenter.shared.set(.failed(caError?.shortDescription ?? "unknown"))
            scheduleRetry()
            return
        }

        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
        tap = newTap
        engine = newEngine
        onEngineChanged(newEngine)
        StatusCenter.shared.set(.idle)
        log.info("Attached to Spotify audio (objectID: \(objectID, privacy: .public))")
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard retryCount < Self.maxRetries else {
            log.info("Giving up attaching to Spotify after \(Self.maxRetries, privacy: .public) attempts")
            StatusCenter.shared.set(.failed("could not reach Spotify audio"))
            return
        }
        retryCount += 1
        retryTimer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: false) { [weak self] _ in
            guard let self, self.isSpotifyRunning(), self.tap == nil else { return }
            self.attach()
        }
    }

    /// Safe to call from any thread: `stop()` runs on a background queue during
    /// termination so the HAL teardown never blocks the main thread, but the
    /// timer and the UI callback must still be touched on main.
    private func detach(status: AppStatus) {
        let stoppingTap = tap
        tap = nil
        engine = nil

        let finishOnMain = { [weak self] in
            self?.retryTimer?.invalidate()
            self?.retryTimer = nil
            self?.retryCount = 0
            self?.onEngineChanged(nil)
            StatusCenter.shared.set(status)
        }

        if Thread.isMainThread {
            finishOnMain()
        } else {
            DispatchQueue.main.sync(execute: finishOnMain)
        }

        stoppingTap?.stop()
    }
}
