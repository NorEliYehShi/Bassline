import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var statusCenter = StatusCenter.shared

    // System Settings > Privacy & Security > Screen & System Audio Recording.
    // System Audio Recording has no pane identifier of its own, so this opens
    // the one it is grouped under.
    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()

            screenPicker
            Divider()

            stylePicker
            tintPicker
            opacitySlider
            heightSlider
            syncOffsetSlider
            Divider()

            lowPowerToggle
            launchAtLoginToggle
            Divider()

            Button("Quit Bassline") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(10)
        .frame(width: 250)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bassline").font(.headline)
            Text(statusCenter.status.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if statusCenter.status.needsPermissionAction {
                HStack(spacing: 6) {
                    if let url = Self.privacySettingsURL {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Retry") {
                        NotificationCenter.default.post(name: .basslineRetryRequested, object: nil)
                    }
                }
                .font(.caption)
                .padding(.top, 2)

                Text("Find Bassline under Screen & System Audio Recording, turn it on, then press Retry.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var screenPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Screen").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $settings.screenDisplayID) {
                ForEach(NSScreen.screens, id: \.displayID) { screen in
                    Text(screen.displayName).tag(screen.displayID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Style").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $settings.style) {
                ForEach(VisualizerStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var tintPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Color").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $settings.tint) {
                ForEach(VisualizerTint.allCases) { tint in
                    Text(tint.displayName).tag(tint)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var opacitySlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Opacity: \(Int(settings.opacity * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: $settings.opacity,
                in: Settings.Limits.minOpacity...Settings.Limits.maxOpacity,
                step: 0.05
            )
        }
    }

    private var heightSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Height: \(Int(settings.stripHeight)) px")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: $settings.stripHeight,
                in: Settings.Limits.minStripHeight...settings.maxStripHeight,
                step: 10
            )
        }
    }

    private var syncOffsetSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sync offset: \(settings.syncOffsetMs >= 0 ? "+" : "")\(Int(settings.syncOffsetMs)) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $settings.syncOffsetMs, in: Settings.Limits.syncOffsetRange, step: 10)
        }
    }

    private var lowPowerToggle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle("Low Power Mode", isOn: $settings.lowPowerMode)
                .font(.caption)
            Text("Caps the visualizer at 20 fps instead of 30.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginToggle: some View {
        Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            .font(.caption)
    }
}
