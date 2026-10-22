//
//  AppState.swift
//  Mac Fan
//
//  Observable hub: keeps fan control on a fixed safety cadence while the
//  user-selectable monitor cadence drives CPU/GPU/RAM/power readouts.
//

import Combine
import MacFanCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    static let monitoringIntervals: [Double] = [1, 2, 5, 10]

    // MARK: - Published state

    @Published var status: ThermalStatus?
    @Published var daemonUp = false
    @Published var failsafe = false
    @Published var profiles: [Profile] = Profile.loadAll()
    @Published var rotation: Double = 0
    @Published private(set) var systemMetrics = SystemMetrics()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var powerHistory: [Double] = []
    @Published private(set) var performanceSnapshot: PerformanceSnapshot?
    @Published private(set) var performanceError: String?
    @Published var expandedDetail: SystemDetailKind?

    @Published var monitoringInterval: Double {
        didSet {
            let normalized = Self.normalizedInterval(monitoringInterval)
            if normalized != monitoringInterval {
                monitoringInterval = normalized
                return
            }
            UserDefaults.standard.set(monitoringInterval, forKey: "monitoringInterval")
            trimHistories()
            if monitoringActive { scheduleMonitoringTimer(sampleImmediately: true) }
        }
    }

    @Published var selectedProfileID: String {
        didSet {
            UserDefaults.standard.set(selectedProfileID, forKey: "selectedProfile")
            rebuildEngines(resetState: true)
        }
    }

    @Published var useFahrenheit: Bool {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }

    @Published var menuBarSource: SensorSource {
        didSet {
            if let data = try? JSONEncoder().encode(menuBarSource) {
                UserDefaults.standard.set(data, forKey: "menuBarSource")
            }
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Mac Fan: launch-at-login toggle failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    /// Set by the app delegate — opens the curve editor window.
    var openCurveEditor: (() -> Void)?
    // MARK: - Private

    private let client = DaemonClient()
    private let systemMonitor = SystemMonitor()
    private let ioQueue = DispatchQueue(label: "com.macfan.io")
    private var engines: [CurveEngine] = []
    private var controlTimer: Timer?
    private var monitorTimer: Timer?
    private var spinTimer: Timer?
    private var monitoringActive = false
    private var monitorPollInFlight = false

    // MARK: - Init

    init() {
        selectedProfileID = UserDefaults.standard.string(forKey: "selectedProfile") ?? "silent"
        useFahrenheit = UserDefaults.standard.bool(forKey: "useFahrenheit")
        let savedInterval = UserDefaults.standard.object(forKey: "monitoringInterval") as? NSNumber
        monitoringInterval = Self.normalizedInterval(savedInterval?.doubleValue ?? 2)
        if let data = UserDefaults.standard.data(forKey: "menuBarSource"),
           let source = try? JSONDecoder().decode(SensorSource.self, from: data) {
            menuBarSource = source
        } else {
            menuBarSource = .group(.cpu)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled

        rebuildEngines(resetState: true)

        controlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollFans()
        }
        controlTimer?.tolerance = 0.3
        pollFans()

        // Establish the first CPU counter baseline before the panel opens.
        ioQueue.async { [weak self] in _ = self?.systemMonitor.sample() }
    }

    // MARK: - Derived

    var activeProfile: Profile {
        profiles.first { $0.id == selectedProfileID } ?? .silent
    }

    var temps: [String: Float] { status?.temperatures ?? [:] }

    var menuBarTemp: Float? { menuBarSource.resolve(in: temps) }

    var fanCount: Int { status?.fans.count ?? 0 }

    var maxActualRPM: Float {
        status?.fans.map(\.actualRPM).max() ?? 0
    }

    var anyFanRunning: Bool { maxActualRPM > 0 }

    var headerStatus: String {
        if failsafe { return "Failsafe" }
        if !daemonUp { return "No daemon" }
        return anyFanRunning ? "\(Int(maxActualRPM)) RPM" : "Idle"
    }

    // MARK: - Fan-control poll (fixed cadence)

    private func pollFans() {
        let profile = activeProfile
        let engines = self.engines

        ioQueue.async { [weak self] in
            guard let self else { return }

            let status: ThermalStatus
            do {
                status = try self.client.status()
            } catch {
                DispatchQueue.main.async {
                    self.daemonUp = false
                    self.status = nil
                }
                return
            }

            let temps = status.temperatures
            let hottest = temps.values.max() ?? 0
            let curveTemp = profile.sensorSource.resolve(in: temps) ?? hottest
            var failsafe = false

            // App-side failsafe mirror (daemon enforces it independently)
            if hottest >= ThermalSafety.failsafeTemp {
                failsafe = true
                try? self.client.max()
            } else {
                for fan in status.fans {
                    let cfg = profile.config(for: fan.index)
                    let action: FanAction
                    switch cfg.mode {
                    case .auto:
                        action = .auto
                    case .fixed:
                        var rpm = cfg.fixedRPM
                        if fan.minRPM > 0 { rpm = max(rpm, fan.minRPM) }
                        if fan.maxRPM > 0 { rpm = min(rpm, fan.maxRPM) }
                        action = .rpm(rpm)
                    case .curve:
                        if fan.index < engines.count {
                            action = engines[fan.index].tick(
                                temp: curveTemp, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
                        } else {
                            action = .auto
                        }
                    }

                    // Only send when the daemon's state actually needs to change
                    switch action {
                    case .auto:
                        if fan.mode == "manual" {
                            try? self.client.autoFan(fan.index)
                        }
                    case .rpm(let rpm):
                        if fan.mode != "manual" || abs(fan.targetRPM - rpm) > 25 {
                            try? self.client.setFan(fan.index, rpm: rpm)
                        }
                    }
                }
            }

            // Heartbeat keeps the daemon's watchdog at bay — only needed
            // while some fan is actually under manual control
            if status.fans.contains(where: { $0.mode == "manual" }) {
                try? self.client.heartbeat()
            }

            DispatchQueue.main.async {
                self.daemonUp = true
                self.status = status
                self.failsafe = failsafe
                if status.fans.count > self.engines.count {
                    self.rebuildEngines(resetState: true)
                }
                self.updateSpinTimer()
            }
        }
    }

    // MARK: - Monitoring poll (user-selected cadence)

    func setMonitoringActive(_ active: Bool) {
        guard monitoringActive != active else { return }
        monitoringActive = active
        if active {
            scheduleMonitoringTimer(sampleImmediately: true)
        } else {
            monitorTimer?.invalidate()
            monitorTimer = nil
        }
    }

    private func scheduleMonitoringTimer(sampleImmediately: Bool) {
        monitorTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            self?.pollMonitoring()
        }
        timer.tolerance = min(0.5, monitoringInterval * 0.1)
        monitorTimer = timer
        if sampleImmediately { pollMonitoring() }
    }

    private func pollMonitoring() {
        guard monitoringActive, !monitorPollInFlight else { return }
        monitorPollInFlight = true
        ioQueue.async { [weak self] in
            guard let self else { return }
            var metrics = self.systemMonitor.sample()
            var snapshot: PerformanceSnapshot?
            var performanceError: String?

            do {
                snapshot = try self.client.performance(sampleMilliseconds: 500)
                if let gpuUsage = snapshot?.gpuUsage {
                    metrics.gpuUsage = gpuUsage
                    metrics.gpuUsageIsEstimated = false
                }
                // Whole-Mac battery telemetry should never be lower than the
                // simultaneously measured CPU+GPU+ANE rail estimate.
                if let chipPower = snapshot?.combinedPowerW {
                    metrics.chipPowerW = chipPower
                    metrics.systemPowerW = max(metrics.systemPowerW ?? 0, chipPower)
                }
            } catch {
                performanceError = "\(error)"
            }

            DispatchQueue.main.async {
                self.monitorPollInFlight = false
                guard self.monitoringActive else { return }
                self.performanceSnapshot = snapshot
                self.performanceError = performanceError
                self.applySystemMetrics(metrics)
            }
        }
    }

    private func applySystemMetrics(_ metrics: SystemMetrics) {
        systemMetrics = metrics
        append(metrics.cpuUsage, to: &cpuHistory)
        append(metrics.gpuUsage, to: &gpuHistory)
        append(metrics.memoryUsage, to: &memoryHistory)
        append(metrics.systemPowerW ?? 0, to: &powerHistory)
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        let limit = historyLimit
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }

    private var historyLimit: Int {
        max(2, Int(ceil(60 / monitoringInterval)) + 1)
    }

    private func trimHistories() {
        let limit = historyLimit
        if cpuHistory.count > limit { cpuHistory.removeFirst(cpuHistory.count - limit) }
        if gpuHistory.count > limit { gpuHistory.removeFirst(gpuHistory.count - limit) }
        if memoryHistory.count > limit { memoryHistory.removeFirst(memoryHistory.count - limit) }
        if powerHistory.count > limit { powerHistory.removeFirst(powerHistory.count - limit) }
    }

    private static func normalizedInterval(_ value: Double) -> Double {
        monitoringIntervals.min(by: { abs($0 - value) < abs($1 - value) }) ?? 2
    }

    /// Run the 12 fps spin timer only while a fan is actually turning —
    /// an always-on animation timer wastes wakeups when everything is idle.
    private func updateSpinTimer() {
        let shouldSpin = maxActualRPM > 0
        if shouldSpin && spinTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                self?.advanceSpin()
            }
            timer.tolerance = 0.02
            spinTimer = timer
        } else if !shouldSpin, let timer = spinTimer {
            timer.invalidate()
            spinTimer = nil
        }
    }

    private func advanceSpin() {
        let rpm = maxActualRPM
        guard rpm > 0 else { return }
        // Icon speed scales with fan speed: ~90°/s at low RPM up to ~450°/s
        let degreesPerSecond = 90 + Double(min(rpm / 6000, 1)) * 360
        rotation = (rotation + degreesPerSecond / 12).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Engines

    /// Rebuild or retune the per-fan curve engines from the active profile.
    /// `resetState: false` keeps engagement/ramp state across live curve edits.
    private func rebuildEngines(resetState: Bool) {
        let profile = activeProfile
        let count = max(fanCount, 2)

        if engines.count != count || resetState {
            engines = (0..<count).map { i in
                CurveEngine(config: engineConfig(profile, fan: i))
            }
        } else {
            for i in 0..<count {
                engines[i].config = engineConfig(profile, fan: i)
            }
        }
    }

    private func engineConfig(_ profile: Profile, fan: Int) -> CurveEngine.Config {
        .init(
            curve: profile.config(for: fan).curve,
            hysteresis: profile.hysteresis,
            sustainSec: profile.sustainSec,
            rampUpPerSec: profile.rampUpPerSec,
            rampDownPerSec: profile.rampDownPerSec
        )
    }

    // MARK: - Profile Editing

    /// Mutate the active profile. Built-ins are forked into a user profile
    /// on first edit. `save: false` keeps the change in memory (live drags);
    /// call once more with `save: true` to persist.
    func updateActiveProfile(save: Bool = true, _ mutate: (inout Profile) -> Void) {
        var profile = activeProfile
        profile.ensureFanCount(max(fanCount, profile.fans.count))

        if profile.isBuiltIn {
            profile = profile.forked()
            mutate(&profile)
            try? profile.save()
            profiles = Profile.loadAll()
            selectedProfileID = profile.id   // triggers engine rebuild
            return
        }

        mutate(&profile)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        }
        if save { try? profile.save() }
        rebuildEngines(resetState: false)
    }

    func newProfile() {
        var profile = activeProfile.forked()
        profile.name = uniqueName(base: "My Profile")
        try? profile.save()
        profiles = Profile.loadAll()
        selectedProfileID = profile.id
    }

    func deleteProfile(_ profile: Profile) {
        guard !profile.isBuiltIn else { return }
        profile.delete()
        profiles = Profile.loadAll()
        if selectedProfileID == profile.id {
            selectedProfileID = "silent"
        }
    }

    func renameActiveProfile(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateActiveProfile { $0.name = trimmed }
    }

    private func uniqueName(base: String) -> String {
        let names = Set(profiles.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
