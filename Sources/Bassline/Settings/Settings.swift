import AppKit
import Combine
import Foundation
import ServiceManagement

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case wave
    case dots
    case aurora

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wave: return "Wave"
        case .dots: return "Dots"
        case .aurora: return "Aurora"
        }
    }
}

enum VisualizerTint: String, CaseIterable, Identifiable {
    case auto
    case light
    case gray
    case dark
    case accent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .gray: return "Gray"
        case .dark: return "Dark"
        case .accent: return "Accent"
        }
    }

    func resolvedColor(appearance: NSAppearance, backdropLuminance: CGFloat?) -> NSColor {
        switch self {
        case .light: return .white
        case .gray: return NSColor(white: 0.55, alpha: 1)
        case .dark: return NSColor(white: 0.15, alpha: 1)
        case .accent: return .controlAccentColor
        case .auto:
            let isLightBackdrop: Bool
            if let backdropLuminance {
                isLightBackdrop = backdropLuminance > 0.5
            } else {
                isLightBackdrop = appearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua
            }
            return isLightBackdrop ? NSColor(white: 0.18, alpha: 1) : .white
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    enum Limits {
        static let minStripHeight: Double = 40
        static let fallbackMaxStripHeight: Double = 160
        static let minOpacity: Double = 0.1
        static let maxOpacity: Double = 1.0
        static let syncOffsetRange: ClosedRange<Double> = -300...300
    }

    private enum Key {
        static let screenDisplayID = "screenDisplayID"
        static let opacity = "opacity"
        static let stripHeight = "stripHeight"
        static let style = "style"
        static let tint = "tint"
        static let syncOffsetMs = "syncOffsetMs"
        static let launchAtLogin = "launchAtLogin"
        static let lowPowerMode = "lowPowerMode"
    }

    @Published var screenDisplayID: UInt32 {
        didSet {
            defaults.set(Int(screenDisplayID), forKey: Key.screenDisplayID)
            clampStripHeight()
        }
    }
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: Key.opacity) }
    }
    @Published var stripHeight: Double {
        didSet { defaults.set(stripHeight, forKey: Key.stripHeight) }
    }
    @Published var style: VisualizerStyle {
        didSet { defaults.set(style.rawValue, forKey: Key.style) }
    }
    @Published var tint: VisualizerTint {
        didSet { defaults.set(tint.rawValue, forKey: Key.tint) }
    }
    @Published var syncOffsetMs: Double {
        didSet { defaults.set(syncOffsetMs, forKey: Key.syncOffsetMs) }
    }
    /// Caps the renderer at 20 fps instead of 30.
    @Published var lowPowerMode: Bool {
        didSet { defaults.set(lowPowerMode, forKey: Key.lowPowerMode) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            updateLoginItem()
        }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        screenDisplayID = UInt32(truncatingIfNeeded: defaults.integer(forKey: Key.screenDisplayID))
        opacity = defaults.object(forKey: Key.opacity) as? Double ?? 0.6
        stripHeight = defaults.object(forKey: Key.stripHeight) as? Double ?? 80
        style = VisualizerStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .wave
        tint = VisualizerTint(rawValue: defaults.string(forKey: Key.tint) ?? "") ?? .auto
        syncOffsetMs = defaults.object(forKey: Key.syncOffsetMs) as? Double ?? 0
        lowPowerMode = defaults.object(forKey: Key.lowPowerMode) as? Bool ?? false
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)

        opacity = min(Limits.maxOpacity, max(Limits.minOpacity, opacity))
        syncOffsetMs = min(Limits.syncOffsetRange.upperBound, max(Limits.syncOffsetRange.lowerBound, syncOffsetMs))
        clampStripHeight()
    }

    /// The screen the overlay is shown on. Falls back to the main display, then
    /// to any connected display. `nil` only when no display is attached.
    var selectedScreen: NSScreen? {
        if screenDisplayID != 0,
           let screen = NSScreen.screens.first(where: { $0.displayID == screenDisplayID }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    var maxStripHeight: Double {
        guard let height = selectedScreen?.frame.height, height > 0 else {
            return Limits.fallbackMaxStripHeight
        }
        return max(Limits.fallbackMaxStripHeight, (height / 2).rounded(.down))
    }

    /// Keeps the strip height valid when the display changes size, so a value
    /// stored for a 5K display does not stay oversized on a smaller one.
    func clampStripHeight() {
        let clamped = min(maxStripHeight, max(Limits.minStripHeight, stripHeight))
        if clamped != stripHeight {
            stripHeight = clamped
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item update failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var displayName: String { localizedName }
}
