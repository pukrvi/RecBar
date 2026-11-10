import AppKit
import RecBarCore
import SwiftUI

// MARK: - Theme

private enum PanelTheme {
    static let backgroundTop = Color(red: 0.045, green: 0.060, blue: 0.095)
    static let backgroundBottom = Color(red: 0.075, green: 0.100, blue: 0.160)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.085)
    static let stroke = Color.white.opacity(0.085)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.52)
    static let red = Color(red: 1.00, green: 0.31, blue: 0.34)
    static let green = Color(red: 0.22, green: 0.84, blue: 0.53)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.30)
    static let blue = Color(red: 0.42, green: 0.60, blue: 1.00)
}

// MARK: - Panel

@MainActor
struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 10) {
            header
            primaryControls
            sectionHeader("CAPTURE")
            captureGrid
            sectionHeader("OPTIONS")
            optionsGrid
            keepSegmentsRow
            sectionHeader("QUICK ACTIONS")
            quickActions
            if model.recoverableCount > 0 {
                recoverBanner
            }
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(PanelTheme.red)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("RecBar")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(PanelTheme.textPrimary)
                Text(model.statusSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PanelTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                Text(model.statusLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(badgeColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(badgeColor.opacity(0.13)))
            .overlay(Capsule().stroke(badgeColor.opacity(0.30), lineWidth: 1))
        }
    }

    private var badgeColor: Color {
        switch model.state {
        case .idle: return PanelTheme.green
        case .recording: return PanelTheme.red
        case .paused: return PanelTheme.amber
        case .starting, .stopping, .merging, .recovering: return PanelTheme.blue
        }
    }

    // MARK: Primary controls

    @ViewBuilder
    private var primaryControls: some View {
        switch model.state {
        case .idle:
            ActionButton(
                title: "Start Recording",
                icon: "record.circle.fill",
                tint: PanelTheme.red,
                hint: "⌃⌥⌘R",
                isHovered: model.isHovered("start")
            ) {
                model.startOrStop()
            }
            .onHover { model.setHover($0, on: "start") }
        case .recording:
            HStack(spacing: 8) {
                ActionButton(
                    title: "Stop",
                    icon: "stop.fill",
                    tint: PanelTheme.red,
                    hint: "⌃⌥⌘R",
                    isHovered: model.isHovered("stop")
                ) {
                    model.startOrStop()
                }
                .onHover { model.setHover($0, on: "stop") }

                ActionButton(
                    title: "Pause",
                    icon: "pause.fill",
                    tint: PanelTheme.amber,
                    hint: "⌃⌥⌘P",
                    isHovered: model.isHovered("pause")
                ) {
                    model.pauseOrResume()
                }
                .onHover { model.setHover($0, on: "pause") }
            }
        case .paused:
            HStack(spacing: 8) {
                ActionButton(
                    title: "Stop",
                    icon: "stop.fill",
                    tint: PanelTheme.red,
                    hint: "⌃⌥⌘R",
                    isHovered: model.isHovered("stop")
                ) {
                    model.startOrStop()
                }
                .onHover { model.setHover($0, on: "stop") }

                ActionButton(
                    title: "Resume",
                    icon: "play.fill",
                    tint: PanelTheme.green,
                    hint: "⌃⌥⌘P",
                    isHovered: model.isHovered("resume")
                ) {
                    model.pauseOrResume()
                }
                .onHover { model.setHover($0, on: "resume") }
            }
        case .starting, .stopping, .recovering:
            BusyBar(label: model.state.displayName, progress: nil, tint: PanelTheme.blue)
        case .merging:
            BusyBar(label: "Joining tracks", progress: model.mergeProgress, tint: PanelTheme.blue)
        }
    }

    // MARK: Capture grid

    private var captureGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            SettingTile(
                icon: "waveform",
                title: "Audio",
                value: model.audioSummary,
                detail: "Separate tracks",
                tint: PanelTheme.blue,
                isHovered: model.isHovered("audio")
            )
            .onTapGesture { popUpMenu(audioMenu()) }
            .onHover { model.setHover($0, on: "audio") }

            SettingTile(
                icon: "video.fill",
                title: "Camera",
                value: model.cameraSummary,
                detail: model.settings.recordCamera
                    ? "\(model.settings.cameraWidth)×\(model.settings.cameraHeight)"
                    : "Separate file",
                tint: PanelTheme.green,
                isHovered: model.isHovered("camera")
            )
            .onTapGesture { popUpMenu(cameraMenu()) }
            .onHover { model.setHover($0, on: "camera") }

            SettingTile(
                icon: "display",
                title: "Display",
                value: model.displaySummary,
                detail: model.displayDetail,
                tint: PanelTheme.amber,
                isHovered: model.isHovered("display")
            )
            .onTapGesture { popUpMenu(displayMenu()) }
            .onHover { model.setHover($0, on: "display") }

            SettingTile(
                icon: "gauge.with.dots.needle.67percent",
                title: "Quality",
                value: model.settings.quality.shortName,
                detail: model.qualityDetail,
                tint: PanelTheme.blue,
                isHovered: model.isHovered("quality")
            )
            .onTapGesture { popUpMenu(qualityMenu()) }
            .onHover { model.setHover($0, on: "quality") }
        }
    }

    // MARK: Option toggles

    private var optionsGrid: some View {
        HStack(spacing: 8) {
            OptionTile(
                icon: "speaker.wave.2.fill",
                title: "System Audio",
                isOn: model.settings.recordSystemAudio,
                tint: PanelTheme.blue,
                isHovered: model.isHovered("system-audio")
            ) {
                model.toggleSystemAudio()
            }
            .onHover { model.setHover($0, on: "system-audio") }

            OptionTile(
                icon: "cursorarrow.rays",
                title: "Cursor",
                isOn: model.settings.showCursor,
                tint: PanelTheme.amber,
                isHovered: model.isHovered("cursor")
            ) {
                model.toggleShowCursor()
            }
            .onHover { model.setHover($0, on: "cursor") }

            OptionTile(
                icon: "power",
                title: "At Login",
                isOn: model.settings.launchAtLogin,
                tint: PanelTheme.green,
                isHovered: model.isHovered("at-login")
            ) {
                model.toggleLaunchAtLogin()
            }
            .onHover { model.setHover($0, on: "at-login") }
        }
    }

    private var keepSegmentsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PanelTheme.amber)
            Text("Keep segment files")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PanelTheme.textPrimary)
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { model.settings.keepSegments },
                    set: { _ in model.toggleKeepSegments() }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(model.isHovered("keep-segments") ? PanelTheme.cardHover : PanelTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    model.isHovered("keep-segments")
                        ? PanelTheme.amber.opacity(0.55)
                        : PanelTheme.stroke,
                    lineWidth: model.isHovered("keep-segments") ? 1.4 : 1
                )
        )
        .scaleEffect(model.isHovered("keep-segments") ? 1.015 : 1)
        .animation(.easeOut(duration: 0.16), value: model.isHovered("keep-segments"))
        .onHover { model.setHover($0, on: "keep-segments") }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            QuickActionTile(
                icon: "folder.fill",
                title: "Folder",
                tint: PanelTheme.blue,
                isHovered: model.isHovered("folder")
            ) {
                model.openRecordingsFolder()
            }
            .onHover { model.setHover($0, on: "folder") }

            QuickActionTile(
                icon: "play.rectangle.fill",
                title: "Last",
                tint: PanelTheme.green,
                enabled: model.hasLastRecording,
                isHovered: model.isHovered("last")
            ) {
                model.openLastRecording()
            }
            .onHover { model.setHover($0, on: "last") }

            QuickActionTile(
                icon: "magnifyingglass",
                title: "Reveal",
                tint: PanelTheme.amber,
                enabled: model.hasLastRecording,
                isHovered: model.isHovered("reveal")
            ) {
                model.revealLastRecording()
            }
            .onHover { model.setHover($0, on: "reveal") }
        }
    }

    private var recoverBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PanelTheme.amber)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.recoverableCount) interrupted recording\(model.recoverableCount == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelTheme.textPrimary)
                Text("Rebuild playable files from the saved segments")
                    .font(.system(size: 9.5))
                    .foregroundStyle(PanelTheme.textSecondary)
            }

            Spacer(minLength: 4)

            Button {
                model.recoverInterrupted()
            } label: {
                Text("Recover")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(PanelTheme.amber))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PanelTheme.amber.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PanelTheme.amber.opacity(0.28), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("RecBar \(appVersion)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(PanelTheme.textSecondary.opacity(0.75))

            Spacer()

            FooterButton(
                title: "Copy Path",
                enabled: model.hasLastRecording,
                isHovered: model.isHovered("copy-path")
            ) {
                model.copyLastPath()
            }
            .onHover { model.setHover($0, on: "copy-path") }

            FooterButton(
                title: "About",
                isHovered: model.isHovered("about")
            ) {
                model.showAbout()
            }
            .onHover { model.setHover($0, on: "about") }

            FooterButton(
                title: "Relaunch",
                isHovered: model.isHovered("relaunch")
            ) {
                model.relaunch()
            }
            .onHover { model.setHover($0, on: "relaunch") }

            FooterButton(
                title: "Quit",
                hint: "⌘Q",
                isHovered: model.isHovered("quit")
            ) {
                model.quit()
            }
            .onHover { model.setHover($0, on: "quit") }
        }
        .padding(.top, 1)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
    }

    // MARK: Menus

    private func audioMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(menuItem(
            "Record System Audio",
            checked: model.settings.recordSystemAudio
        ) {
            model.toggleSystemAudio()
        })

        menu.addItem(.separator())
        menu.addItem(menuItem(
            "System Default Microphone",
            checked: model.settings.microphoneIDs.isEmpty
        ) {
            model.useDefaultMicrophone()
        })

        if model.microphones.isEmpty {
            menu.addItem(disabledItem("No microphones found"))
        } else {
            menu.addItem(disabledItem("Microphones — select any number"))
            for microphone in model.microphones {
                menu.addItem(menuItem(
                    microphone.name,
                    checked: model.settings.microphoneIDs.contains(microphone.id)
                ) {
                    model.toggleMicrophone(microphone.id)
                })
            }
            menu.addItem(menuItem("Select All Microphones") {
                model.selectAllMicrophones()
            })
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Refresh Devices") {
            model.reloadDevices()
        })
        return menu
    }

    private func cameraMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(menuItem(
            "Record Camera",
            checked: model.settings.recordCamera
        ) {
            model.toggleCamera()
        })

        menu.addItem(.separator())
        menu.addItem(menuItem(
            "System Default Camera",
            checked: model.settings.cameraID == nil
        ) {
            model.setCamera(nil)
        })

        if model.cameras.isEmpty {
            menu.addItem(disabledItem("No cameras found"))
        } else {
            menu.addItem(disabledItem("Cameras"))
            for camera in model.cameras {
                menu.addItem(menuItem(
                    camera.name,
                    checked: model.settings.cameraID == camera.id
                ) {
                    model.setCamera(camera.id)
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Refresh Devices") {
            model.reloadDevices()
        })
        return menu
    }

    private func displayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(menuItem(
            "Main Display",
            checked: model.settings.captureDisplayID == nil
        ) {
            model.setDisplay(nil)
        })

        if model.displays.isEmpty {
            menu.addItem(disabledItem("No displays found"))
        } else {
            menu.addItem(disabledItem("Displays"))
            for display in model.displays {
                menu.addItem(menuItem(
                    "\(display.name) — \(display.width)×\(display.height)",
                    checked: model.settings.captureDisplayID == display.id
                ) {
                    model.setDisplay(display.id)
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Refresh Displays") {
            model.reloadDevices()
        })
        return menu
    }

    private func qualityMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for preset in QualityPreset.allCases {
            menu.addItem(menuItem(
                preset.displayName,
                checked: model.settings.quality == preset
            ) {
                model.setQuality(preset)
            })
        }
        return menu
    }

    private func menuItem(
        _ title: String,
        checked: Bool = false,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let box = MenuActionBox(handler)
        let item = NSMenuItem(
            title: title,
            action: #selector(MenuActionBox.run),
            keyEquivalent: ""
        )
        item.target = box
        item.representedObject = box
        item.state = checked ? .on : .off
        item.isEnabled = true
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Small pieces

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(PanelTheme.textSecondary)
            Rectangle()
                .fill(PanelTheme.stroke)
                .frame(height: 1)
        }
    }
}

// MARK: - Background

private struct PanelBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PanelTheme.backgroundTop, PanelTheme.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(PanelTheme.blue.opacity(0.14))
                .frame(width: 260, height: 260)
                .blur(radius: 90)
                .offset(x: -130, y: -190)

            Circle()
                .fill(PanelTheme.green.opacity(0.06))
                .frame(width: 220, height: 220)
                .blur(radius: 100)
                .offset(x: 150, y: 220)
        }
    }
}

// MARK: - Action button

private struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let hint: String?
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                if let hint {
                    Text(hint)
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .opacity(0.62)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(isHovered ? 1.0 : 0.92),
                                tint.opacity(isHovered ? 0.82 : 0.68)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        Color.white.opacity(isHovered ? 0.55 : 0.15),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(
                color: tint.opacity(isHovered ? 0.35 : 0),
                radius: isHovered ? 8 : 0,
                y: 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.025 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Busy bar

private struct BusyBar: View {
    let label: String
    let progress: Double?
    let tint: Color

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanelTheme.textPrimary)
                Spacer()
                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(PanelTheme.textSecondary)
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(tint)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PanelTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PanelTheme.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Setting tile

private struct SettingTile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String?
    let tint: Color
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(isHovered ? 0.26 : 0.16))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 27, height: 27)

            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(PanelTheme.textSecondary)
                Text(value)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PanelTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if let detail {
                    Text(detail)
                        .font(.system(size: 8.5))
                        .foregroundStyle(PanelTheme.textSecondary.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 1)

            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(isHovered ? tint : PanelTheme.textSecondary.opacity(0.75))
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovered ? PanelTheme.cardHover : PanelTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    isHovered ? tint.opacity(0.75) : PanelTheme.stroke,
                    lineWidth: isHovered ? 1.4 : 1
                )
        )
        .shadow(
            color: tint.opacity(isHovered ? 0.18 : 0),
            radius: isHovered ? 6 : 0,
            y: 2
        )
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.025 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Option tile

private struct OptionTile: View {
    let icon: String
    let title: String
    let isOn: Bool
    let tint: Color
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? tint : (isHovered ? tint.opacity(0.85) : PanelTheme.textSecondary))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isOn ? PanelTheme.textPrimary : (isHovered ? PanelTheme.textPrimary : PanelTheme.textSecondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isOn
                            ? tint.opacity(isHovered ? 0.24 : 0.14)
                            : (isHovered ? PanelTheme.cardHover : PanelTheme.card)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isOn
                            ? tint.opacity(isHovered ? 0.70 : 0.35)
                            : (isHovered ? tint.opacity(0.55) : PanelTheme.stroke),
                        lineWidth: isHovered ? 1.4 : 1
                    )
            )
            .shadow(
                color: tint.opacity(isHovered ? 0.20 : 0),
                radius: isHovered ? 6 : 0,
                y: 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Quick action tile

private struct QuickActionTile: View {
    let icon: String
    let title: String
    let tint: Color
    var enabled: Bool = true
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? tint : PanelTheme.textSecondary)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(enabled ? PanelTheme.textPrimary : PanelTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered && enabled ? PanelTheme.cardHover : PanelTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isHovered && enabled ? tint.opacity(0.60) : PanelTheme.stroke,
                        lineWidth: isHovered && enabled ? 1.4 : 1
                    )
            )
            .shadow(
                color: tint.opacity(isHovered && enabled ? 0.20 : 0),
                radius: isHovered && enabled ? 6 : 0,
                y: 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .scaleEffect(isHovered && enabled ? 1.03 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Footer button

private struct FooterButton: View {
    let title: String
    var hint: String? = nil
    var enabled: Bool = true
    var isHovered: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                if let hint {
                    Text(hint)
                        .font(.system(size: 8.5, design: .monospaced))
                        .opacity(0.6)
                }
            }
            .foregroundStyle(
                enabled
                    ? (isHovered ? PanelTheme.textPrimary : PanelTheme.textSecondary)
                    : PanelTheme.textSecondary.opacity(0.35)
            )
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    isHovered && enabled ? Color.white.opacity(0.09) : Color.clear
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .scaleEffect(isHovered && enabled ? 1.04 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}

// MARK: - Native menu popup helper

private extension PanelView {
    /// Native NSMenu gives the panel standard macOS menu behaviour (type-ahead,
    /// keyboard navigation, checkmarks) without SwiftUI's Menu control clipping
    /// a multi-line tile label. The point is in screen coordinates.
    func popUpMenu(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Retains the closure behind an NSMenuItem action. NSMenuItem's `target` is weak,
/// so the box is also stored in `representedObject` to keep it alive while the
/// menu is open.
private final class MenuActionBox: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}
