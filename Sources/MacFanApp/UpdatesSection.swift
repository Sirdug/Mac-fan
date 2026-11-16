//
//  UpdatesSection.swift
//  Mac Fan
//
//  The panel's version line, update status, Check Now and the automatic
//  updates switch.
//

import SwiftUI

struct UpdatesSection: View {
    @EnvironmentObject var updates: UpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Version \(UpdateService.version)", systemImage: "info.circle")
                    .font(.system(size: 12))
                Spacer()
                if updates.isConfigured {
                    actionButton
                }
            }
            if updates.isConfigured {
                statusLine
                Toggle("Automatic updates", isOn: $updates.automaticUpdates)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Download new versions and install them when the panel is closed.")
            } else {
                Text("This build doesn't get updates. Builds from Scripts/release.sh do.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch updates.state {
        case .checking, .downloading:
            ProgressView().controlSize(.small)
        case .available(let release):
            Button("Update to \(release.version)") {
                Task { await updates.download(release) }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        case .ready:
            Button("Restart to Update") { updates.installAndRelaunch() }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .controlSize(.small)
        default:
            Button("Check Now") {
                Task { await updates.check() }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            status("Checking for updates…")
        case .upToDate:
            status("Mac Fan is up to date.")
        case .available(let release):
            releaseInfo("Version \(release.version) is available.", release)
        case .downloading(let release):
            status("Downloading version \(release.version)…")
        case .ready(let release):
            releaseInfo(
                updates.automaticUpdates
                    ? "Version \(release.version) installs when you close this panel."
                    : "Version \(release.version) is ready to install.",
                release)
        case .failed(let message):
            status(message, color: .orange)
        }
    }

    private func releaseInfo(_ text: String, _ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            status(text)
            if let notes = release.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func status(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
