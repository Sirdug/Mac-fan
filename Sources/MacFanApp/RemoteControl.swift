//
//  RemoteControl.swift
//  Mac Fan
//
//  Lets other apps on this Mac (Notch Island) change the fan settings through
//  the app itself, so the change shows up in Mac Fan's panel at once and the
//  app's own control loop keeps applying it.
//
//  Transport: distributed notifications, property-list payloads only.
//
//  Commands — name "com.macfan.app.command", userInfo["action"]:
//    "requestState"                                → Mac Fan answers with a state post
//    "selectProfile", "profile": <id>              → switches profile
//    "setMode", "mode": auto|curve|fixed|max,
//               "fan": <index> (optional; all fans when missing or linked),
//               "rpm": <number> (optional, for fixed)
//
//  State — name "com.macfan.app.state", posted after every change:
//    "selected": <id>, "linkFans": Bool,
//    "profiles": [["id", "name", "builtIn"]],
//    "fans": [["mode": String, "fixedRPM": Double]]   (one per fan, links resolved)
//
//  Same trust level as the daemon socket, which is open to every local user.
//

import Combine
import Foundation
import MacFanCore

@MainActor
final class RemoteControl {
    static let commandName = Notification.Name("com.macfan.app.command")
    static let stateName = Notification.Name("com.macfan.app.state")

    private unowned let state: AppState
    private var observer: NSObjectProtocol?
    private var cancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state
        let center = DistributedNotificationCenter.default()
        observer = center.addObserver(forName: Self.commandName, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        // @Published fires before the value is stored, so read it on the next pass.
        cancellable = state.$profiles.map { _ in () }
            .merge(with: state.$selectedProfileID.map { _ in () })
            .merge(with: state.$status.map { $0?.fans.count ?? 0 }.removeDuplicates().map { _ in () })
            .throttle(for: .milliseconds(60), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.broadcast() }
        broadcast()
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func handle(_ info: [AnyHashable: Any]) {
        switch info["action"] as? String {
        case "requestState":
            broadcast()
        case "selectProfile":
            guard let id = info["profile"] as? String,
                  state.profiles.contains(where: { $0.id == id }) else { return }
            if state.selectedProfileID != id { state.selectedProfileID = id }
            state.applyNow()
        case "setMode":
            guard let raw = info["mode"] as? String else { return }
            let fan = (info["fan"] as? NSNumber)?.intValue
            let rpm = (info["rpm"] as? NSNumber)?.floatValue
            setMode(raw, fan: fan, rpm: rpm)
        default:
            break
        }
    }

    private func setMode(_ raw: String, fan: Int?, rpm: Float?) {
        let mode: FanMode
        var fixedRPM = rpm
        switch raw {
        case "max":
            mode = .fixed
            fixedRPM = 99_999 // clamped to each fan's maximum by the control loop
        default:
            guard let parsed = FanMode(rawValue: raw) else { return }
            mode = parsed
        }
        if let value = fixedRPM, !(value.isFinite && value >= 0) { return }

        state.updateActiveProfile { profile in
            let indices: Range<Int>
            if profile.linkFans || fan == nil {
                indices = profile.fans.indices
            } else if let fan, profile.fans.indices.contains(fan) {
                indices = fan..<(fan + 1)
            } else {
                return
            }
            for index in indices {
                profile.fans[index].mode = mode
                if let fixedRPM { profile.fans[index].fixedRPM = fixedRPM }
            }
        }
        state.applyNow()
    }

    private func broadcast() {
        let profile = state.activeProfile
        let count = max(state.fanCount, profile.fans.count, 1)
        let fans: [[String: Any]] = (0..<count).map { index in
            let config = profile.config(for: index)
            return ["mode": config.mode.rawValue, "fixedRPM": Double(config.fixedRPM)]
        }
        let info: [String: Any] = [
            "selected": profile.id,
            "linkFans": profile.linkFans,
            "profiles": state.profiles.map { ["id": $0.id, "name": $0.name, "builtIn": $0.isBuiltIn] },
            "fans": fans,
        ]
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateName, object: nil, userInfo: info, deliverImmediately: true)
    }
}
