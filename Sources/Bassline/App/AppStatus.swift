import Foundation

extension Notification.Name {
    /// Posted by the menu when the user asks to reconnect after granting the
    /// audio recording permission.
    static let basslineRetryRequested = Notification.Name("com.NorEliYehShi.bassline.retryRequested")
}

enum AppStatus: Equatable {
    case waitingForSpotify
    case connecting
    case noAudioReceived
    case permissionDenied
    case failed(String)
    case idle
    case playing

    var title: String {
        switch self {
        case .waitingForSpotify:
            return "Spotify is not running"
        case .connecting:
            return "Connecting to Spotify…"
        case .noAudioReceived:
            return "No audio received from Spotify. If a track is playing, the System Audio Recording permission is probably missing."
        case .permissionDenied:
            return "Audio recording permission is needed"
        case .failed(let reason):
            return "Audio capture failed: \(reason)"
        case .idle:
            return "Connected — waiting for audio"
        case .playing:
            return "Visualizing"
        }
    }

    var needsPermissionAction: Bool {
        switch self {
        case .permissionDenied, .noAudioReceived: return true
        default: return false
        }
    }
}

final class StatusCenter: ObservableObject {
    static let shared = StatusCenter()

    @Published private(set) var status: AppStatus = .waitingForSpotify

    private init() {}

    func set(_ newStatus: AppStatus) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.set(newStatus) }
            return
        }
        guard newStatus != status else { return }
        status = newStatus
    }
}
