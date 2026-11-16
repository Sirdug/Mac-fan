# Mac Fan

Menu bar fan control for Apple Silicon MacBooks on macOS 26 or newer,
including M1 Pro MacBook Pro. Spinning fan icon with a configurable
temperature readout, per-fan control, draggable fan curves, and savable
profiles — in a Liquid Glass UI.

The SMC access layer and root-daemon architecture are adapted from
[ThermalForge](https://github.com/ProducerGuy/ThermalForge) (MIT).

## Features

- **Menu bar**: fan icon spins while the fans run (speed matches RPM) next
  to a live temperature readout — click any temperature row to choose what
  it shows (CPU / GPU / RAM / SSD / Ambient / Battery or any raw sensor)
- **Live dashboard**: CPU, GPU, and RAM utilization with rolling 60-second
  graphs; whole-system draw, estimated wall input, battery charge/discharge
  power, charge level, and component temperatures; selectable 1 / 2 / 5 / 10
  second monitoring intervals (fan control keeps its independent safety rate)
- **Detailed monitors**: click CPU, GPU, or RAM to drill down inside the same
  menu-bar panel for per-core CPU activity and clocks, GPU renderer/tiler and
  memory statistics, or a complete unified-memory and swap breakdown
- **Power accuracy**: system and battery watts prefer live, read-only SMC sensors;
  wall input remains a labeled controller estimate. Remaining time uses
  [macOS’s power-source estimate](https://developer.apple.com/documentation/iokit/1523835-iopsgettimeremainingestimate),
  with a recent-current/capacity fallback when macOS is still calculating.
  Charge-time estimates come from the battery controller; missing readings stay
  unavailable instead of being filled with zero or unrelated chip power.
- **Apple-native telemetry**: CPU load uses Mach per-core counters, memory uses
  Activity Monitor-style anonymous + wired + compressed accounting, and GPU /
  CPU / ANE rail data comes from machine-readable `powermetrics` output
- **Per-fan control**: each fan can be Auto (Apple), Curve, or Fixed RPM;
  or link both fans to one setting
- **Curve editor**: drag control points on a temperature→speed graph,
  double-click to add, right-click to delete; live temp indicator; tune
  engage delay, hysteresis, and ramp rates
- **Profiles**: Silent / Balanced / Performance / Max built in; create,
  edit, and delete your own
- **Safety**: watchdog requests auto after 15 s without an app heartbeat
  (checked every second; hardware retries can take longer);
  daemon-side failsafe forces max fans if any sensor hits 95 °C; fans
  return to Apple control on quit, uninstall, daemon shutdown, and loss of
  all temperature readings. Wake starts in Apple auto until the app reapplies
  its current profile. Failed hardware writes are reported and resets retried.

## Install

```bash
./setup.sh
```

One-time admin password. This builds everything, installs a root daemon
(`com.macfan.daemon`, the only privileged part — it owns SMC writes so the
app never needs sudo), creates `/Applications/Mac Fan.app`, and **disables**
(does not delete) the ThermalForge and fancontrold daemons so they don't
fight over the fans.

### Installing from a release

Friends don't need the source: download `MacFan-<version>.zip` from the
[latest release](https://github.com/Sirdug/Mac-fan/releases/latest), unzip
it, and drag **Mac Fan** into Applications. The app is ad hoc signed, so the
first open is blocked: open System Settings › Privacy & Security and click
**Open Anyway**, or run `xattr -dr com.apple.quarantine "/Applications/Mac Fan.app"`.
The panel then shows **Install Fan Helper**, which installs the daemon with
the admin password.

## Updates

The panel footer shows the installed version, **Check Now** and an
**Automatic updates** switch (on by default). Mac Fan checks the latest
GitHub release every six hours. With automatic updates on, a new version
downloads, then installs and restarts the app the next time the panel and
curve editor are closed. If the new version has a changed fan daemon, Mac Fan
asks for the admin password once to update it, or shows **Update Fan Helper**.

To publish a version (needs `gh auth login` once):

```bash
Scripts/release.sh 1.1.0 "What changed"
```

This bumps the version in `Resources/Info.plist`, builds `build/Mac Fan.app`
with the daemon inside, signs the zip with your update key, and uploads the
zip and `update.json` to a release on `Sirdug/Mac-fan` (change it in
`Scripts/release.env`). The first run creates the key at
`~/.config/mac-fan/update-key`. **Back it up.** Installed copies only accept
updates signed with it, and a lost key means everyone has to reinstall by hand.
Commit the `Info.plist` change after each release.

## CLI

```
macfan status            fans + temperatures
macfan diagnose          read-only hardware and telemetry compatibility report
macfan set 3000          all fans to 3000 RPM
macfan setfan 1 4000     fan 1 to 4000 RPM
macfan auto              back to Apple control
macfan max               everything to 100%
```

## Uninstall

```bash
./uninstall.sh
```

## Development

```bash
swift build                                                # build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test                                               # unit tests
```

Use `Xcode-beta.app` instead if that is the installed full toolchain. To avoid
Finder extended attributes affecting test-bundle signing in a Desktop folder,
pass `--scratch-path /tmp/macfan-tests` to `swift test`.

## M1 Pro compatibility and verification

The M1 Pro path probes the available `F0Md`/`F0md` keys, attempts direct
manual control first, and uses `Ftst` only when firmware requires it. Each
fan uses its own reported minimum and maximum; accepted mode and target
writes are read back. Temperature decoding uses the reported SMC type,
including fixed-point battery sensors. CPU labels use actual CPU IDs from
`powermetrics`, and the parser handles M1-era GPU MHz and energy fields as
well as newer Hz and power fields.

These behaviors are covered by **synthetic hardware tests**, including two
independent fans, 8/10 CPU cores, both mode-key spellings, optional/rejected
unlocks, partial writes, sensor loss, failsafe hysteresis, watchdog recovery,
and wake recovery. They are not a claim of physical M1 Pro validation.
Hardware behavior was cross-checked against the upstream
[M1 Pro fan-control research](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md),
[Stats sensor catalog](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift),
and [asitop telemetry parser](https://github.com/tlkh/asitop/blob/main/asitop/parsers.py).

After installing on the target M1 Pro with `./setup.sh`:

1. Run `macfan diagnose`. It reads sensors and requests telemetry without
   changing fan speeds. Check that two fans have sensible, nonzero limits,
   CPU/GPU temperatures are present, and the helper supplies clocks/power.
2. In the app, check CPU/GPU/RAM details, temperature selection and °C/°F,
   refresh intervals, curve editing, and saving/reloading a custom profile.
3. Unlink fans, select a moderate Fixed speed for one fan at a time, and
   verify its actual RPM approaches the target. Check linked control, the
   built-in curves, Max, and return both fans to Auto afterward.
4. Verify quit returns fans to Apple control, sleep/wake reapplies the current
   profile, and Launch at Login starts the installed app after logging in.

The final on-device checks require an actual M1 Pro. Optional sensors and
power channels vary by firmware/macOS: unavailable values should appear as
unavailable, not invented zero readings or charging watts labeled as system
consumption. macOS 25 and earlier are not supported by the Liquid Glass UI.
