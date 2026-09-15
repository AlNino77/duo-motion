import SwiftUI
import AppKit

public struct LiquidGlassControlPanel: View {
    public static let preferredHeight: CGFloat = 680

    @ObservedObject private var settings: AppSettings = .shared
    @State private var startFoldDraft: Double
    @State private var pendingStartFoldAngle: Double?
    @State private var showingStartFoldWarning = false

    private let panelHeight: CGFloat

    public init(panelHeight: CGFloat = Self.preferredHeight) {
        self.panelHeight = panelHeight
        _startFoldDraft = State(initialValue: AppSettings.shared.startTiltAngle)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 14)

            statusTiles
                .padding(.horizontal, 22)
                .padding(.bottom, 18)

            Divider()

            settingsForm
        }
        .frame(width: 460, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            startFoldDraft = settings.startTiltAngle
            settings.refreshPermissions()
        }
        .onDisappear {
            settings.isTestModeActive = false
            settings.testTurnValue = 0
            OverlayWindowController.shared.stopOverlay()
        }
        .alert("Settings may become unavailable", isPresented: $showingStartFoldWarning) {
            Button(keepCurrentStartFoldLabel, role: .cancel) {
                startFoldDraft = settings.startTiltAngle
                pendingStartFoldAngle = nil
            }

            Button(usePendingStartFoldLabel) {
                if let pendingStartFoldAngle {
                    settings.startTiltAngle = pendingStartFoldAngle
                    startFoldDraft = pendingStartFoldAngle
                }
                self.pendingStartFoldAngle = nil
            }
        } message: {
            Text(startFoldWarningMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            Text("DuoMo")
                .font(.title3.weight(.semibold))

            Spacer()

            Text(versionText)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var statusTiles: some View {
        if #available(macOS 26.0, *) {
            NativeLiquidGlassStatusTiles(
                settings: settings,
                requestPermission: requestScreenRecordingPermission
            )
        } else {
            LegacyStatusTiles(
                settings: settings,
                requestPermission: requestScreenRecordingPermission
            )
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Angle") {
                SliderRow(
                    title: "Start Fold",
                    value: "\(Int(startFoldDraft.rounded()))\u{00B0}",
                    help: "The fold begins when the lid moves below this angle.",
                    selection: $startFoldDraft,
                    range: 40...120,
                    step: 1,
                    onEditingChanged: handleStartFoldEditing
                )

                SliderRow(
                    title: "Full Fold",
                    value: "\(Int(settings.endTiltAngle))\u{00B0}",
                    help: "The display reaches full darkness at this angle.",
                    selection: $settings.endTiltAngle,
                    range: 0...20,
                    step: 1
                )
            }

            Section("Motion") {
                SliderRow(
                    title: "Follow Response",
                    value: String(format: "%.0f", settings.followSpeed),
                    help: "Controls how quickly the rendered fold catches the physical lid movement.",
                    selection: $settings.followSpeed,
                    range: 6...30,
                    step: 1
                )

                SliderRow(
                    title: "Blur",
                    value: String(format: "%.1fx", settings.blurStrength),
                    help: "Controls the optical defocus as the display folds away.",
                    selection: $settings.blurStrength,
                    range: 0.2...2,
                    step: 0.1
                )

                SliderRow(
                    title: "Reflection",
                    value: String(format: "%.1fx", settings.reflectionIntensity),
                    help: "Controls the glass reflection across the moving display.",
                    selection: $settings.reflectionIntensity,
                    range: 0...2.5,
                    step: 0.1
                )
            }

            Section("Advanced") {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prioritize Wake Transition")
                            .font(.subheadline.weight(.medium))
                        Text("Keeps the fold layer above normal windows during wake.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    InfoButton(
                        "Wake transition",
                        content: "macOS protects the password screen. This setting raises the overlay where the system permits it, but it cannot bypass lock-screen security."
                    )

                    Spacer()

                    Toggle("", isOn: $settings.enableLockScreenPriority)
                        .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "1.0.0")"
    }

    private var keepCurrentStartFoldLabel: String {
        "Keep \(Int(settings.startTiltAngle.rounded()))\u{00B0}"
    }

    private var usePendingStartFoldLabel: String {
        "Use \(Int((pendingStartFoldAngle ?? startFoldDraft).rounded()))\u{00B0}"
    }

    private var startFoldWarningMessage: String {
        let currentAngle = Int(settings.currentLidAngle.rounded())
        let proposedAngle = Int((pendingStartFoldAngle ?? startFoldDraft).rounded())
        return "Your Mac is currently open to \(currentAngle)\u{00B0}. Setting Start Fold to \(proposedAngle)\u{00B0} will activate the fold effect now. The settings panel may remain hidden until you open the display beyond \(proposedAngle)\u{00B0}."
    }

    private func handleStartFoldEditing(_ isEditing: Bool) {
        guard !isEditing else { return }

        let proposedAngle = startFoldDraft
        guard abs(proposedAngle - settings.startTiltAngle) >= 0.5 else { return }

        if settings.isSensorConnected && proposedAngle > settings.currentLidAngle {
            pendingStartFoldAngle = proposedAngle
            showingStartFoldWarning = true
        } else {
            settings.startTiltAngle = proposedAngle
        }
    }

    private func requestScreenRecordingPermission() {
        if !ScreenCapture.shared.requestPermission() {
            ScreenCapture.shared.openSettings()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            settings.refreshPermissions()
        }
    }
}

@available(macOS 26.0, *)
private struct NativeLiquidGlassStatusTiles: View {
    @ObservedObject var settings: AppSettings
    let requestPermission: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                NativeStatusTile(title: "Status") {
                    SensorStatusValue(settings: settings)
                }

                NativeStatusTile(title: "Permission") {
                    PermissionStatusValue(
                        settings: settings,
                        requestPermission: requestPermission
                    )
                }

                NativeStatusTile(title: "Energy") {
                    EnergyStatusValue(settings: settings)
                }

                NativeStatusTile(title: "Angle") {
                    AngleStatusValue(settings: settings)
                }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct NativeStatusTile<Value: View>: View {
    let title: String
    let value: Value

    init(title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        StatusTileContent(title: title) {
            value
        }
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

private struct LegacyStatusTiles: View {
    @ObservedObject var settings: AppSettings
    let requestPermission: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            LegacyStatusTile(title: "Status") {
                SensorStatusValue(settings: settings)
            }

            LegacyStatusTile(title: "Permission") {
                PermissionStatusValue(
                    settings: settings,
                    requestPermission: requestPermission
                )
            }

            LegacyStatusTile(title: "Energy") {
                EnergyStatusValue(settings: settings)
            }

            LegacyStatusTile(title: "Angle") {
                AngleStatusValue(settings: settings)
            }
        }
    }
}

private struct LegacyStatusTile<Value: View>: View {
    let title: String
    let value: Value

    init(title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        StatusTileContent(title: title) {
            value
        }
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

private struct StatusTileContent<Value: View>: View {
    let title: String
    let value: Value

    init(title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Spacer(minLength: 0)
                value
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
    }
}

private struct SensorStatusValue: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Image(systemName: settings.isSensorConnected
              ? "checkmark.circle.fill"
              : "ellipsis.circle.fill")
            .foregroundStyle(settings.isSensorConnected ? Color.green : Color.orange)
            .help(settings.isSensorConnected ? "Lid sensor online." : "Looking for the lid sensor.")

        Text(settings.isSensorConnected ? "Active" : "Connecting")
    }
}

private struct PermissionStatusValue: View {
    @ObservedObject var settings: AppSettings
    let requestPermission: () -> Void

    var body: some View {
        if settings.hasScreenRecordingPermission {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .help("Screen recording permission is active.")

            Text("Screen Recording")
        } else {
            Button(action: requestPermission) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text("Screen Recording")
                }
            }
            .buttonStyle(.plain)
            .help("Screen recording permission is required. Click to allow access.")
        }
    }
}

private struct EnergyStatusValue: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Text(settings.isScreenCaptureDormant ? "Idle" : "Active")

        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help(energyDetail)
    }

    private var energyDetail: String {
        if settings.isScreenCaptureDormant {
            return "Rendering and live screen capture are dormant. The lid sensor remains active."
        }
        return "Live screen capture and fold rendering are active."
    }
}

private struct AngleStatusValue: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Text(angleValue)
            .monospacedDigit()
            .help(angleDetail)
    }

    private var angleValue: String {
        settings.isSensorConnected
            ? "\(Int(settings.currentLidAngle.rounded()))\u{00B0}"
            : "--\u{00B0}"
    }

    private var angleDetail: String {
        guard settings.isSensorConnected else { return "Lid angle is unavailable." }
        if settings.currentLidAngle >= settings.startTiltAngle { return "The lid is open." }
        if settings.currentLidAngle <= settings.endTiltAngle { return "The lid is closed." }
        return "The lid is folding."
    }
}

private struct SliderRow: View {
    let title: String
    let value: String
    let help: String
    @Binding var selection: Double
    let range: ClosedRange<Double>
    let step: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                InfoButton(title, content: help)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }

            Slider(
                value: $selection,
                in: range,
                step: step,
                onEditingChanged: onEditingChanged
            )
        }
        .padding(.vertical, 4)
    }
}

private struct InfoButton: View {
    let title: String
    let content: String
    @State private var isShowing = false

    init(_ title: String = "", content: String) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                if !title.isEmpty {
                    Text(title)
                        .font(.headline)
                }
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 260)
        }
    }
}
