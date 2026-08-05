## Porthole

A "Fluid for Linux apps": install `Porthole.app` once, then install per-app presets that materialize
standalone "Linux <App>.app" viewers on your Mac. This file is the fallback release body.

## Setup reliability

- Porthole app launchers now show a **modal dialog** when a prerequisite is missing (Docker VM
  not set up/started, VMware Fusion absent, engine/transport/viewer missing) instead of exiting
  silently — the dialog names the exact command to run.
- The Mac-side viewer transport (`s6-ipcserver`) now ships inside Porthole; there is no separate
  `socat` install step on the Mac.
- **Already-installed apps:** re-run each app's installer (Signal, 1Password, …) once to
  re-materialize them onto the new launcher and pick up these fixes.
