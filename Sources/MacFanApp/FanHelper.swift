//
//  FanHelper.swift
//  Mac Fan
//
//  The root fan daemon (/usr/local/bin/macfan) is installed separately from
//  the app. Release builds carry a copy of it in Contents/Resources/macfan,
//  so after an app update — or on a friend's Mac that only has the app — the
//  panel can install or update the daemon with one click and the admin
//  password, instead of running setup.sh from the source folder.
//

import CryptoKit
import Foundation
import MacFanCore

@MainActor
final class FanHelper: ObservableObject {
    enum Status: Equatable {
        /// This build doesn't carry a helper (for example a `swift run` build).
        case unknown
        case notInstalled
        /// The installed daemon differs from the one inside this app.
        case outdated
        case current
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var installing = false
    @Published private(set) var error: String?

    private var bundled: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/macfan")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func refresh() {
        guard let bundled else { status = .unknown; return }
        let installedPath = MacFanDaemon.installPath
        Task.detached(priority: .utility) {
            let result: Status
            if !FileManager.default.fileExists(atPath: installedPath) {
                result = .notInstalled
            } else if Self.digest(bundled.path) == Self.digest(installedPath) {
                result = .current
            } else {
                result = .outdated
            }
            await MainActor.run { self.status = result }
        }
    }

    /// Runs the bundled `macfan install` as root. macOS asks for the admin password.
    func install(completion: @escaping () -> Void = {}) {
        guard let bundled, !installing else { return }
        installing = true
        error = nil
        let escaped = bundled.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            do shell script (quoted form of "\(escaped)") & " install" with administrator privileges \
            with prompt "Mac Fan needs to install its fan helper."
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.terminationHandler = { [weak self] finished in
            let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.installing = false
                // -128 is "User canceled" from the password prompt: not an error worth showing.
                if finished.terminationStatus != 0, !output.contains("-128") {
                    self.error = "The fan helper didn't install."
                    NSLog("Mac Fan: helper install failed: \(output)")
                }
                self.refresh()
                completion()
            }
        }
        do {
            try process.run()
        } catch {
            installing = false
            self.error = "The fan helper didn't install."
        }
    }

    private nonisolated static func digest(_ path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return nil
        }
        return Data(SHA256.hash(data: data))
    }
}
