# Mac Fan

Menu bar fan control for Apple Silicon MacBooks (built and tested on a
MacBook Pro M5 Pro, macOS 26). Spinning fan icon with a configurable
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
- **Safety**: watchdog resets fans to auto within 15 s if the app dies;
  daemon-side failsafe forces max fans if any sensor hits 95 °C; fans
  return to Apple control on quit, uninstall, and daemon shutdown

## Install

```bash
./setup.sh
```

One-time admin password. This builds everything, installs a root daemon
(`com.macfan.daemon`, the only privileged part — it owns SMC writes so the
app never needs sudo), creates `/Applications/Mac Fan.app`, and **disables**
(does not delete) the ThermalForge and fancontrold daemons so they don't
fight over the fans.

## CLI

```
macfan status            fans + temperatures
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
