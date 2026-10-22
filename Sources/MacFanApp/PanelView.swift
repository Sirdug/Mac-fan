//
//  PanelView.swift
//  Mac Fan
//
//  The menu bar dropdown: fans, temperatures, profiles, settings.
//  Liquid Glass styling (macOS 26).
//

import MacFanCore
import SwiftUI

struct PanelView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // Capped height + scroll: the full panel can outgrow the screen
        // (long profile lists), which cut the popover off at the top.
        // Cap = visible screen height, so it scrolls only when it must.
        ScrollView {
            if let detail = state.expandedDetail {
                SystemDetailView(kind: detail, compact: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                panelContent
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: 360)
        .frame(maxHeight: max(400, (NSScreen.main?.visibleFrame.height ?? 800) - 40))
        .animation(.snappy(duration: 0.22), value: state.expandedDetail)
    }

    private var panelContent: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                header

                if !state.daemonUp {
                    daemonWarning
                }

                sectionLabel("Live Monitor")
                DashboardView()

                sectionLabel("Fans")
                fansCard

                sectionLabel("Temperatures")
                temperaturesCard

                HStack {
                    sectionLabel("Profile")
                    Spacer()
                    Button {
                        state.newProfile()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .help("New profile (copies the current one)")
                }
                profilesCard

                actionButtons

                Divider().padding(.vertical, 2)

                footer
            }
            .padding(14)
        }
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Mac Fan")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Image(systemName: state.failsafe ? "exclamationmark.triangle.fill" : "fanblades.fill")
                .font(.system(size: 11))
                .foregroundStyle(state.failsafe ? .red : (state.anyFanRunning ? .orange : .secondary))
                .rotationEffect(.degrees(state.anyFanRunning ? state.rotation : 0))
            Text(state.headerStatus)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(state.failsafe ? .red : .secondary)
        }
        .padding(.bottom, 2)
    }

    private var daemonWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Fan daemon not running", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("Run setup.sh in the Mac-fan folder to install it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Fans

    private var fansCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fans = state.status?.fans, !fans.isEmpty {
                ForEach(fans, id: \.index) { fan in
                    fanRow(fan)
                    if state.activeProfile.linkFans == false {
                        fanControls(for: fan)
                    }
                    if fan.index < fans.count - 1 {
                        Divider()
                    }
                }
                if state.activeProfile.linkFans, let first = fans.first {
                    Divider()
                    fanControls(for: first, label: "All fans")
                }
            } else {
                Text("No fan data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func fanRow(_ fan: FanInfo) -> some View {
        HStack {
            Text("Fan \(fan.index)")
                .font(.system(size: 13))
            if fan.mode == "manual" {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Under Mac Fan control")
            }
            Spacer()
            Text("\(Int(fan.actualRPM)) RPM")
                .font(.system(size: 13, design: .monospaced))
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private func fanControls(for fan: FanInfo, label: String? = nil) -> some View {
        let cfg = state.activeProfile.config(for: fan.index)
        let targetIndex = state.activeProfile.linkFans ? 0 : fan.index

        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: Binding(
                get: { cfg.mode },
                set: { newMode in
                    state.updateActiveProfile { $0.fans[targetIndex].mode = newMode }
                }
            )) {
                ForEach(FanMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()

            if cfg.mode == .fixed {
                let minRPM = fan.minRPM > 0 ? fan.minRPM : 1000
                let maxRPM = fan.maxRPM > 0 ? fan.maxRPM : 6000
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { min(max(cfg.fixedRPM, minRPM), maxRPM) },
                            set: { rpm in
                                state.updateActiveProfile(save: false) {
                                    $0.fans[targetIndex].fixedRPM = rpm
                                }
                            }
                        ),
                        in: minRPM...maxRPM,
                        onEditingChanged: { editing in
                            if !editing { state.updateActiveProfile { _ in } }
                        }
                    )
                    .controlSize(.small)
                    Text("\(Int(min(max(cfg.fixedRPM, minRPM), maxRPM)))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - Temperatures

    private var temperaturesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            let groups = SensorCatalog.groupedMaxima(state.temps)
            if groups.isEmpty {
                Text("No sensor data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.group) { entry in
                Button {
                    state.menuBarSource = .group(entry.group)
                } label: {
                    HStack {
                        Text(entry.group.displayName)
                            .font(.system(size: 13))
                        if state.menuBarSource == .group(entry.group) {
                            Image(systemName: "menubar.arrow.up.rectangle")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("Shown in the menu bar")
                        }
                        Spacer()
                        Text(formatTemp(entry.temp, fahrenheit: state.useFahrenheit))
                            .font(.system(size: 13, design: .monospaced))
                            .contentTransition(.numericText())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to show \(entry.group.displayName) in the menu bar")
            }

            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(state.temps.sorted(by: { $0.key < $1.key }), id: \.key) { key, temp in
                            Button {
                                state.menuBarSource = .key(key)
                            } label: {
                                HStack {
                                    Text(key)
                                        .font(.system(size: 11, design: .monospaced))
                                    if state.menuBarSource == .key(key) {
                                        Image(systemName: "menubar.arrow.up.rectangle")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(formatTemp(temp, fahrenheit: state.useFahrenheit))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 140)
            } label: {
                Text("All sensors")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Profiles

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(state.profiles) { profile in
                Button {
                    state.selectedProfileID = profile.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: state.selectedProfileID == profile.id
                              ? "inset.filled.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(state.selectedProfileID == profile.id
                                             ? Color.orange : Color.secondary)
                        Text(profile.name)
                            .font(.system(size: 13))
                        Spacer()
                        Text(profileHint(profile))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !profile.isBuiltIn {
                        Button("Delete \(profile.name)", role: .destructive) {
                            state.deleteProfile(profile)
                        }
                    }
                }
            }
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func profileHint(_ profile: Profile) -> String {
        let cfg = profile.config(for: 0)
        switch cfg.mode {
        case .auto: return ""
        case .fixed: return cfg.fixedRPM >= 99999 ? "100%" : "\(Int(cfg.fixedRPM)) RPM"
        case .curve:
            if let onset = cfg.curve.onsetTemp {
                let top = cfg.curve.points.last.map { Int($0.temp) } ?? 0
                return "\(Int(onset))→\(top)°C"
            }
            return ""
        }
    }

    // MARK: - Actions + Footer

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                state.openCurveEditor?()
            } label: {
                Label("Edit Curves", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)

            Button {
                state.selectedProfileID = "silent"
            } label: {
                Label("Default", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .help("Back to Silent — Apple controls the fans")
        }
        .controlSize(.regular)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Update interval", systemImage: "timer")
                    .font(.system(size: 12))
                Spacer()
                Picker("Update interval", selection: $state.monitoringInterval) {
                    ForEach(AppState.monitoringIntervals, id: \.self) { interval in
                        Text("\(Int(interval)) sec").tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 82)
                .help("How often CPU, GPU, RAM, and power readings update. Fan control stays on its safety cadence.")
            }
            Toggle("°F / °C", isOn: $state.useFahrenheit)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Toggle("Launch at Login", isOn: $state.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Button("Quit Mac Fan") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}
