//
//  UpdateService.swift
//  Mac Fan
//
//  Finds, downloads and installs new versions of the app, so people who
//  have it never need to download it again. Same design as Notch Island's
//  updater: the feed (`UpdateFeedURL` in Info.plist) is a small JSON file
//  published by Scripts/release.sh next to a zip of the app on a GitHub
//  release. Nothing in the feed is trusted: the zip must carry an Ed25519
//  signature made with the private half of `UpdatePublicKey`, and the app
//  inside must be Mac Fan with a higher build number.
//

import AppKit
import CryptoKit
import Foundation

/// What the update feed says the newest release is.
struct UpdateRelease: Decodable, Equatable {
    var version: String
    var build: Int
    var url: URL
    /// Ed25519 signature of the zip, base64.
    var signature: String
    var notes: String?
    var minimumSystemVersion: String?
}

@MainActor
final class UpdateService: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        /// Downloaded, verified and unpacked. Restarting swaps it in.
        case ready(UpdateRelease)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    /// New versions download and install on their own, when the panel isn't open.
    @Published var automaticUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticUpdates, forKey: "automaticUpdates")
            if automaticUpdates { resumeAutomatic() }
        }
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    /// True when restarting wouldn't interrupt anything: no panel or curve editor open.
    var isQuiet: () -> Bool = { true }

    private let feedURL: URL?
    private let publicKey: Curve25519.Signing.PublicKey?
    private var stagedApp: URL?
    private var scheduleTask: Task<Void, Never>?
    private var relaunchTask: Task<Void, Never>?

    private static let checkInterval: Duration = .seconds(6 * 60 * 60)
    private static let updatedFromKey = "updatedFromBuild"

    init() {
        UserDefaults.standard.register(defaults: ["automaticUpdates": true])
        automaticUpdates = UserDefaults.standard.bool(forKey: "automaticUpdates")
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["UpdateFeedURL"] as? String).flatMap { URL(string: $0) }
        feedURL = feed.flatMap { Self.isAllowed($0) ? $0 : nil }
        publicKey = (info["UpdatePublicKey"] as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// False for builds with no feed or key, such as one made before the first release.
    var isConfigured: Bool {
        feedURL != nil && publicKey != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// True once, on the first launch after an update installed itself.
    func consumeJustUpdated() -> Bool {
        let defaults = UserDefaults.standard
        let previous = defaults.integer(forKey: Self.updatedFromKey)
        defaults.removeObject(forKey: Self.updatedFromKey)
        return previous > 0 && previous < Self.build
    }

    /// Checks shortly after launch, then every few hours.
    func start() {
        guard isConfigured, scheduleTask == nil else { return }
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    // MARK: - Check

    func check(userInitiated: Bool = true) async {
        guard isConfigured, let feedURL else { return }
        switch state {
        case .checking, .downloading: return
        case .ready where !userInitiated: return
        default: break
        }
        let previous = state
        state = .checking
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.session.data(for: request)
            try Self.requireOK(response)
            let release = try JSONDecoder().decode(UpdateRelease.self, from: data)
            lastChecked = Date()
            guard release.build > Self.build, Self.isAllowed(release.url), Self.systemSupports(release) else {
                state = .upToDate
                return
            }
            if case .ready(let staged) = previous, staged == release, stagedApp != nil {
                state = previous
                return
            }
            state = .available(release)
            if automaticUpdates { await download(release) }
        } catch {
            // A failed background check isn't worth showing: it tries again later.
            state = userInitiated ? .failed("Couldn't check for updates.") : previous
        }
    }

    // MARK: - Download

    func download(_ release: UpdateRelease) async {
        guard let publicKey else { return }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            state = .failed("Move Mac Fan to Applications, then reopen it to update.")
            return
        }
        state = .downloading(release)
        do {
            let (file, response) = try await Self.session.download(from: release.url)
            defer { try? FileManager.default.removeItem(at: file) }
            try Self.requireOK(response)
            let installed = Installed(
                url: Bundle.main.bundleURL, identifier: Bundle.main.bundleIdentifier, build: Self.build)
            let app = try await Task.detached(priority: .utility) {
                try Self.unpack(zip: file, release: release, publicKey: publicKey, replacing: installed)
            }.value
            discardStaged()
            stagedApp = app
            state = .ready(release)
            if automaticUpdates { relaunchWhenQuiet() }
        } catch let error as UpdateError {
            state = .failed(error.message)
        } catch {
            state = .failed("The download failed. Check your connection.")
        }
    }

    /// Checks the zip's signature, unpacks it next to the installed app and makes sure it
    /// holds a newer build of this app. Returns the unpacked app.
    private nonisolated static func unpack(
        zip: URL, release: UpdateRelease, publicKey: Curve25519.Signing.PublicKey, replacing installed: Installed
    ) throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard let signature = Data(base64Encoded: release.signature),
              publicKey.isValidSignature(signature, for: data) else {
            throw UpdateError("The update didn't pass its signature check, so it wasn't installed.")
        }

        // On the same volume as the app, so swapping it in is a rename.
        let files = FileManager.default
        let staging: URL
        do {
            staging = try files.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed.url, create: true)
        } catch {
            throw UpdateError.notWritable
        }
        do {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, staging.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw UpdateError("The update couldn't be unpacked.") }

            let apps = try files.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let app = apps.first, let bundle = Bundle(url: app),
                  bundle.bundleIdentifier == installed.identifier,
                  let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
                  build > installed.build,
                  let executable = bundle.executableURL, files.isExecutableFile(atPath: executable.path) else {
                throw UpdateError("The update isn't a newer version of Mac Fan.")
            }
            return app
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    private struct Installed: Sendable {
        var url: URL
        var identifier: String?
        var build: Int
    }

    // MARK: - Install

    /// Swaps the downloaded app in for the running one and restarts.
    func installAndRelaunch() {
        guard case .ready = state, let stagedApp else { return }
        let files = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let staging = stagedApp.deletingLastPathComponent()
        let old = staging.appendingPathComponent("Previous.app")
        guard files.fileExists(atPath: stagedApp.path) else {
            // The system cleared the temporary copy. Fetch it again.
            self.stagedApp = nil
            state = .idle
            Task { await check(userInitiated: false) }
            return
        }
        do {
            try files.moveItem(at: bundleURL, to: old)
            do {
                try files.moveItem(at: stagedApp, to: bundleURL)
            } catch {
                try? files.moveItem(at: old, to: bundleURL)
                throw error
            }
        } catch {
            state = .failed(UpdateError.notWritable.message)
            return
        }

        UserDefaults.standard.set(Self.build, forKey: Self.updatedFromKey)

        // Waits for this process to exit, opens the new version, then clears the old one.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$2"; rm -rf "$3""#,
            "sh", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path, staging.path,
        ]
        try? helper.run()
        NSApp.terminate(nil)
    }

    private func resumeAutomatic() {
        switch state {
        case .available(let release): Task { await download(release) }
        case .ready: relaunchWhenQuiet()
        default: break
        }
    }

    private func relaunchWhenQuiet() {
        relaunchTask?.cancel()
        relaunchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, case .ready = self.state, self.automaticUpdates else { return }
                if self.isQuiet() {
                    self.installAndRelaunch()
                    return
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func discardStaged() {
        if let stagedApp {
            try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent())
        }
        stagedApp = nil
    }

    // MARK: - Helpers

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    private nonisolated static func requireOK(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    /// Release builds only talk to https. Debug builds may use a local test feed.
    private static func isAllowed(_ url: URL) -> Bool {
        #if DEBUG
        return ["https", "http", "file"].contains(url.scheme)
        #else
        return url.scheme == "https"
        #endif
    }

    private static func systemSupports(_ release: UpdateRelease) -> Bool {
        guard let minimum = release.minimumSystemVersion else { return true }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        let needed = OperatingSystemVersion(
            majorVersion: major,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(needed)
    }
}

private struct UpdateError: Error {
    var message: String
    init(_ message: String) { self.message = message }

    static let notWritable = UpdateError("Mac Fan couldn't replace itself. Move it to Applications and try again.")
}
