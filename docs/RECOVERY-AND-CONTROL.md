# Recovery, control center and acceptance

## Normal control

Launch `MeshClip控制中心.vbs` from the repository root. The current-user control center shows the watchdog intent, last heartbeat, next expected check and pending recovery, with buttons to pause for one hour, pause until resumed, resume, open diagnostics, inspect recovery and open the two-device acceptance guide. Closing the control center leaves the watchdog running. Pausing prevents automatic relaunch; it does not stop an existing KDE Connect process, its ordinary login startup or Tailscale.

The existing limited Task Scheduler supervisor remains the only supervisor. No additional service, public port or scheduler is installed. New watchdog source takes effect when that process is next started; an already running PowerShell process does not automatically reload imported functions.

## Interrupted installation or configuration

```powershell
pwsh -NoProfile -File .\scripts\recover.ps1 -AsJson
pwsh -NoProfile -File .\scripts\recover.ps1 -Apply
```

The first command only shows sanitized recovery metadata. Review it before applying. Each integration change has a durable pre-effect record. Reverse recovery checks the actual resource before restoring it; an external modification is preserved and remains pending for reconciliation. No incomplete marker is cleared to make diagnostics green. A new install/configure operation cannot overwrite an unfinished transaction. Legacy pending records without preimages require explicit local reconciliation, not invented history.

Official packages installed by WinGet are intentionally retained after an integration failure. The transaction covers integration settings, not uninstalling newly installed third-party software. KDE identity files and pairings are never backed up or removed by the integration journal. Backups and journals stay in ignored current-user local state and must not enter public Git or diagnostic output.

## Layered diagnosis

```powershell
pwsh -NoProfile -File .\scripts\doctor.ps1 -Summary
pwsh -NoProfile -File .\scripts\doctor.ps1 -Summary -StrictAcceptance
```

`-AsJson` retains the legacy array of checks; `-Summary` adds overall state, observation context and explicit `business_acceptance=not_tested`. A FAIL exits 1. Strict mode also exits 2 for unknown or warning checks. Some warnings deliberately require two-device human confirmation; strict diagnosis is not a substitute for that confirmation. The firewall check observes effective ActiveStore rules and enabled profiles. Session 0/SYSTEM results are not proof of desktop-user behavior.

## Two-device acceptance guide

```powershell
pwsh -NoProfile -File .\scripts\acceptance.ps1
# In a PowerShell 7 session, prepare synthetic fixtures. Keep the returned directory.
.\scripts\acceptance.ps1 -Action Prepare -SizesMiB 1,100,1024
.\scripts\acceptance.ps1 -Action Summary -RunDirectory '<run directory>'
```

Use the generated non-secret text markers, not real clipboard history. In each direction, copy the 100 unique markers using KDE Connect and record an observed marker with `RecordClipboard`, `SequenceIndex`, `ObservedMarker`, `Direction` and the measured `LatencyMilliseconds`. The default missing latency is not a measurement: supply it when claiming timing. Pairing, no echo loop and reboot recovery use `RecordCheck -Check <name> -Observed` only after a real observation.

Transfer the generated files with KDE Connect. Validate a distinct received copy with:

```powershell
.\scripts\acceptance.ps1 -Action VerifyFile -RunDirectory '<run directory>' -ReceivedPath '<received copy>' -FixtureName 'meshclip-1MiB.bin' -Direction Forward
```

Repeat for the reverse direction and larger files. Matching hashes prove content equality, not how the copy arrived. The summary labels local hash checks and operator observations separately and never issues an automatic business PASS. Reboot requires a separate safe opportunity; do not interrupt an active remote session merely to satisfy a checklist.

`Clean -RunDirectory <run>` deletes only unchanged generated fixtures. Foreign or modified files are preserved. Use `-WhatIf` to preview. A partial preparation remains visibly incomplete; inspect it before cleanup rather than deleting unknown content.

## Regression tests

`test-repository.ps1` runs parse/safety and behavioral tests. A zero-test discovery or failed container is a failure. Tests include late installation failure, recovery failure, external edits, pending-state preservation, preview without effects, heartbeat interval, pause/resume and synthetic fixture checks. Source/unit tests, UI construction, deployed process checks and real two-device behavior are independent evidence layers.
