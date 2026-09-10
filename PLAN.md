# NvTeleGuard — NVIDIA Telemetry Disabler
### Planning Document (v1.0 — implemented; Phase 7 pending)

> **Status:** v1.0.0 built and smoke-tested read-only on this machine (driver 616.56 / NVIDIA App 11.0.8, RTX 5070 Laptop). A real apply → undo cycle still needs an elevated run (§9). GitHub release integration is stubbed (§7.4).

---

## 1. Summary

NvTeleGuard is a Windows desktop utility that gives the user a GUI to inspect and disable the telemetry/data-collection mechanisms bundled with NVIDIA's graphics drivers and companion software (legacy GeForce Experience and the newer NVIDIA App), with every change reversible and logged. It is a spiritual successor to [NateShoffner/Disable-Nvidia-Telemetry](https://github.com/NateShoffner/Disable-Nvidia-Telemetry) — same purpose, rebuilt from scratch for current driver architecture, with a nicer UI and safety features the original never had.

**Stack:** PowerShell 5.1 + WPF (XAML UI hosted from a `.ps1`). See [§5](#5-tech-stack).

---

## 2. Relationship to the original project

[NateShoffner/Disable-Nvidia-Telemetry](https://github.com/NateShoffner/Disable-Nvidia-Telemetry) is a C#/.NET WinForms app (583 stars, last tagged release v1.2) that toggles NVIDIA's telemetry services. It's the reason this project exists, but it's shown its age:

- Written for the driver architecture of the **GeForce Experience** era (pre-2024). It doesn't know about the **NVIDIA App**, which has since replaced GeForce Experience + NVIDIA Control Panel.
- On modern drivers NVIDIA moved telemetry into a **plugin loaded by the shared `NvContainerLocalSystem` service** — the original tool's "stop one service" approach no longer applies (that service doesn't even exist any more, see §4).
- 16+ open issues, no clear signs of active maintenance — several issues (e.g. [#5](https://github.com/NateShoffner/Disable-Nvidia-Telemetry/issues/5)) point out registry keys the tool never covered.
- No undo/rollback — changes are one-directional.
- No activity log — the user has to trust it did what it said.
- Plain, dated WinForms UI.

NvTeleGuard keeps the original's focus (a single-purpose telemetry toggle tool, not a general driver-debloat suite) but is rebuilt to cover the modern surface, in PowerShell instead of C#, with undo, logging, theming, a status test and a self-update check designed in from the start.

**Why PowerShell instead of a compiled language:** every action this app takes needs administrator rights and touches system services, the registry, junctions and Task Scheduler. A `.ps1` a user can open in Notepad and read line-by-line before granting it admin rights is a meaningful trust advantage for exactly this category of tool.

---

## 3. Goals / Non-Goals

**Goals**
- Toggle known NVIDIA telemetry mechanisms on/off individually, with a live status view. ✅
- Every change is undoable — both a single-step "Undo Last Action" and a full "Restore All Original Settings." ✅
- Every action is logged (in-app panel + persistent log file) with enough detail to audit exactly what happened. ✅
- A "Test Telemetry Status" diagnostic that reports what is installed, wired up and blocked, into the same log. ✅ (added during build at user request)
- Clean, modern GUI in a green/grey theme. ✅
- A "Check for Updates" button — **stubbed with placeholder data for now**; real GitHub Releases integration comes later. ✅ (stub)
- Idempotent: re-running detects drift (NVIDIA re-enabling things after a driver update) instead of pretending protection is permanent. ✅ (state is always read live)

**Non-Goals (v1)**
- Not a driver "debloat"/repackaging tool (NVCleanstall territory — that edits the driver package before install; NvTeleGuard only flips settings post-install).
- Not a general Windows telemetry disabler.
- No silent/CLI mode (candidate for later).
- No real GitHub API integration yet — explicitly deferred.

---

## 4. Phase 0 findings: what NVIDIA telemetry actually is on a 2026 driver

Verified read-only on this machine (RTX 5070 Laptop, driver 616.56, NVIDIA App 11.0.8.299, "NVIDIA Telemetry Client" 19.6.6.0) by reading NVIDIA's own installer manifests (`Installer2\*.nvi`), the registry, service/junction layout, and strings inside the telemetry DLLs.

### 4.1 The modern surface (what actually exists today)

| What | Where | Finding |
|---|---|---|
| **Telemetry client plugin** | `C:\Program Files\NVIDIA Corporation\NvContainer\plugins\LocalSystem\NvTelemetry` — a **directory junction** → `...\NvTelemetry\plugin\NvTelemetry64.dll` | `NvTelemetry.nvi` phase `createLinkToPlugins` creates this junction so `NvContainerLocalSystem` (`nvcontainer.exe -d "...\plugins\LocalSystem"`) loads the client. The other junctions in that folder (NvCpl, ShadowPlay, Watchdog, MessageBus) are unrelated. **Removing only this junction unplugs telemetry surgically → NvTeleGuard's primary modern toggle.** |
| Host service | `NvContainerLocalSystem` ("NVIDIA LocalSystem Container") | Hosts the plugin above *and* Control Panel / ShadowPlay / message-bus plugins. Disabling the whole service works but has side effects → Advanced only. |
| Display-driver telemetry | `NVDisplay.ContainerLocalSystem` loads `_DisplayDriverRAS.dll` and `_NvGSTPlugin.dll` (GameSessionTelemetry) from the DriverStore; registry `HKLM\SOFTWARE\NVIDIA Corporation\NVDisplay.Container\GameSessionTelemetry` | Lives inside the signed driver package under `System32\DriverStore` — **not controlled in v1** (reported by the status test as informational). Disabling that service kills the NVIDIA Control Panel. |
| Consent store | `%ProgramData%\NVIDIA Corporation\DisplayDriverRAS\NvTelemetry\telemetry_switch.ini` and `%ProgramData%\NVIDIA Corporation\NvTelemetry\telemetry_switch.ini` — JSON `{"GDPRDevice":{"<clientId>":<flags>}}` plus `events.dat` (queued events) | `NvTelemetry.log` shows the RAS plugin *re-asserts* consent (`levelFlags=0x1`) at every start, so editing the file is not a durable control → read by the status test only. On this machine: 13 of 13 NVIDIA App client IDs and 2 of 2 RAS IDs opted in. |
| Upload endpoints | Strings in `NvTelemetry64.dll` / `NvTelemetryAPI64.dll`, `NvTelemetry.log`, `NvConfig\LocalizedConfig.json` | `events.telemetry.data.nvidia.com`, `feedbacks.telemetry.data.nvidia.com`, `events.gfe.nvidia.com`, `telemetry.gfe.nvidia.com` (+ `-uat` staging variants, `activation.gfe.nvidia.com`). Endpoints come from a cloud config, so the hosts-file block is best-effort. |
| Update task | `\NVIDIA App SelfUpdate_{GUID}` (event-triggered, `NvApp.nvi` line 572) | Modern equivalent of `NvDriverUpdateCheck*`. Update-check category, not telemetry. |
| Install-time switch | `DisplayDriver.nvi`: `NvContainerSetup.exe -enableTelemetry:false` gated by `Global:EnableTelemetry` | Only honoured by the driver installer (this is the hook NVCleanstall uses). Not a runtime control. |

### 4.2 Legacy surface (GeForce Experience era — all **absent** on this machine, kept for older drivers)

| What | Identifier | NvTeleGuard action |
|---|---|---|
| Telemetry service | `NvTelemetryContainer` | Stop + Startup = Disabled |
| Telemetry tasks | any task named `NvTm*` (`NvTmMon`, `NvTmRep`, `NvTmRepOnLogon`) — enumerated live | Disable |
| Update tasks | `NvDriverUpdateCheck*`, `NvProfileUpdater*` — enumerated live | Disable (Update-Check category) |
| Registry | `HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client` → `OptInOrOutPreference = 0` | Set (only if the key exists) |
| Registry | `HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS` → `EnableRID44231/64640/66610 = 0` | Set (only if the key exists) |
| Hard block | IFEO `Debugger` for `NvTelemetryContainer.exe` → `systray.exe` | Advanced only |

The engine never *creates* legacy keys that don't exist — a missing key is reported as "not on this driver" rather than fabricated.

**Sources consulted (besides local inspection):**
[NateShoffner/Disable-Nvidia-Telemetry](https://github.com/NateShoffner/Disable-Nvidia-Telemetry) (+ [issue #5](https://github.com/NateShoffner/Disable-Nvidia-Telemetry/issues/5)) · [gHacks 2016](https://www.ghacks.net/2016/11/07/nvidia-telemetry-tracking/) · [gHacks 2017](https://www.ghacks.net/2017/06/07/software-to-disable-nvidia-telemetry/) · [Federico Dossena](https://fdossena.com/?p=nvtelemetry%2Fi.md) · [TechPowerUp](https://www.techpowerup.com/227598/nvidia-telemetry-spooks-privacy-sensitive-users-how-to-disable-it)

---

## 5. Tech stack

**Windows PowerShell 5.1 + WPF**, XAML loaded at runtime via `[Windows.Markup.XamlReader]::Load()`, one `.ps1` entry point, no dependencies beyond what ships with Windows.

- WPF over WinForms because the theme (rounded cards, status pills, toggle switches, dark scrollbars) is plain XAML styling.
- Ships as `.ps1` + `NvTeleGuard.bat` launcher (`-ExecutionPolicy Bypass -STA`). The script self-elevates via UAC; if elevation is declined it runs read-only and says so. A `ps2exe` build is an optional later convenience.
- Dev switches: `-NoElevate` (read-only), `-DryRun`, `-ShowConsole`, `-ScreenshotPath <png>` (renders the window and exits — used for the visual check in §9).

---

## 6. Application architecture

```
NvTeleGuard/
├── NvTeleGuard.ps1               # entry point: elevation, XAML load, card building, event wiring
├── NvTeleGuard.bat               # double-click launcher
├── UI\MainWindow.xaml        # layout + all styles (theme lives here)
├── Modules\
│   ├── TelemetryEngine.psm1  # Get-TelemetryTargets / Get-TargetState / Disable-Target / Restore-Target
│   ├── SnapshotStore.psm1    # first-touch original-state store (snapshot.json)
│   ├── ActionLog.psm1        # persistent log + session undo stack
│   ├── StatusReport.psm1     # "Test Telemetry Status" diagnostic
│   └── UpdateCheck.psm1      # version compare against (placeholder) release info
└── PLAN.md
```

Runtime data lives in **`%ProgramData%\NvTeleGuard\`** (falls back to `%LocalAppData%\NvTeleGuard\` if not writable). Changed from the original `%LocalAppData%` plan because every change is machine-wide (HKLM, services, Program Files) — the snapshot has to be visible to whichever admin runs the restore.

```
%ProgramData%\NvTeleGuard\
├── snapshot.json          # original state of every touched item (written once, on first change)
├── actions.log            # append-only history, one line per action
└── hosts.backup-<stamp>   # copy of the hosts file taken before the hosts block is applied
```

---

## 7. Feature spec (as built)

### 7.1 Telemetry engine
Targets are uniform objects (`Id`, `Category`, `Kind`, `Params`, `Advanced`, `Recommended`) dispatched by `Kind`: `PluginJunction`, `Service`, `ScheduledTask`, `RegistryValues`, `IFEOBlock`, `HostsBlock`, `Absent`. `Get-TargetState` always reads live system state (→ `Enabled` / `Disabled` / `NotPresent`), which is what makes drift after a driver update visible. Scheduled tasks are enumerated by name pattern, never hard-coded GUIDs. Every mutating path honours `-DryRun`, and `-DryRun` writes nothing — not even the snapshot.

Junction removal uses `[IO.Directory]::Delete()` on the reparse point after asserting it *is* a reparse point, so the target plugin folder is never touched; restore recreates it with `New-Item -ItemType Junction`.

### 7.2 Batch apply, Undo / Restore
- **Batch model** (changed from per-toggle after user review): flipping a switch only marks the card *pending* (amber "pending" tag; the pill keeps showing confirmed live state). **Apply Changes** shows a confirmation listing what will be blocked / restored (Advanced items called out separately), applies the batch, then every card re-reads live state — a pill turns BLOCKED only once Windows confirms it. **Select Recommended** just flips the recommended switches to pending. Refresh discards pending selections (logged).
- **Session undo stack** — "Undo Last Action" reverses the whole last batch, in reverse order, without pushing again.
- **Restore All Original** — walks `snapshot.json` immediately (own confirmation). A snapshot entry is written only on first touch and removed on successful restore, so a later re-apply captures a fresh original. Cards that have a snapshot say "changed by NvTeleGuard" in their detail line.
- **Dry run** keeps pending selections after a dry-run apply so they can be applied for real after switching dry run off.

### 7.3 Activity log
`actions.log` line format: `2026-09-10 12:33:55  [Category]  message  [Result]  - detail`. The in-app panel shows the same lines colour-coded (green OK, amber Warn/DryRun, red Failed, dim Skipped).

### 7.4 Check for updates
`UpdateCheck.psm1` → `Get-LatestReleaseInfo` calls `https://api.github.com/repos/derpfinger/NvTeleGuard/releases/latest` (TLS 1.2 forced for Windows PowerShell 5.1; a 404 means "no releases yet" and is reported as up to date). `Test-ForUpdates` does a real `[version]` compare against the release tag. Result shows in a banner under the header ("You're already on the latest version (1.0.0)" / "Update available: x → y" + link to the release page) and is logged. Bump `$script:AppVersion` in `NvTeleGuard.ps1` and tag the release `vX.Y.Z` to ship an update.

### 7.5 GUI / theme
Palette avoids NVIDIA's trademarked `#76B900`: accent `#4CAF50`, window `#1E1E1E`, cards `#2D2D30`, text `#F0F0F0` / `#B0B0B0`, amber `#FFB300` for the Advanced section and "ACTIVE" pills, red `#E53935` for failures. Layout: header (admin pill, version, Check for Updates) → update banner → action bar (summary, **Test Telemetry Status**, Refresh, Select Recommended, **Apply Changes**, Restore All Original) → scrollable sections of cards (name, description, live detail, pill, pending tag, switch) → activity log (Undo Last Action, Open Log File, Clear View) → status bar with a **Dry run** switch. The Advanced section is collapsed and requires an acknowledgement dialog the first time it is expanded; Advanced items are listed under their own warning heading in the Apply Changes confirmation.

### 7.6 Test Telemetry Status
Read-only, no network. Logs: GPU/driver/NVIDIA App/Telemetry Client versions; every target's live state (`ACTIVE` / `BLOCKED` / `n/a`); whether `NvTelemetry*.dll` is loaded in any process (needs admin to see services); container service states; consent flags and `events.dat` queue size from both `telemetry_switch.ini` stores; which endpoints the hosts file blocks; a one-line summary.

---

## 8. Elevation & permissions
- Self-elevates at launch; declined UAC → read-only mode with a warning in the header pill, summary line and log.
- Advanced items are never part of Apply Recommended and always get their own confirmation.
- No network calls except the (currently placeholder) update check — and the UI says so.

---

## 9. Testing

Done (read-only, non-elevated, this machine):
- [x] Module dry-run of every Disable/Restore path — correct results, zero snapshot writes.
- [x] Status report end-to-end.
- [x] GUI launched via `-ScreenshotPath`, rendered and inspected: theme, cards, pills, log colouring, update banner, dry-run switch all correct.

Done (elevated, by the user, 2026-09-10 12:44, on the per-toggle build):
- [x] Plugin-junction removal and hosts block applied for real — log shows both `[OK]`, junction gone, `NvTelemetry64.dll` untouched, both originals captured in `snapshot.json`, hosts backup written.

Still to do (needs an elevated run — a real change to the system):
- [ ] Undo Last Action on a batch, then confirm the junction is back with the same target and the hosts block is gone; Restore All returns every touched item to its snapshot value.
- [ ] Re-launch after an NVIDIA App / driver update: recreated junction shows as ACTIVE again (drift).
- [ ] Advanced hosts block + restore, confirming the backup file and `ipconfig /flushdns`.

---

## 10. Risks / edge cases
- **Driver and NVIDIA App updates recreate the junction / tasks.** NvTeleGuard shows the drift and lets you re-apply; it cannot prevent it.
- **Display-driver telemetry (RAS / GameSessionTelemetry) is not controlled in v1** — it lives in the signed DriverStore package and its host service is the Control Panel's host. The status test reports it so the gap is visible.
- **Consent file is not a durable switch** (re-asserted by the plugin at start), so it is reported, not edited.
- **IFEO and hosts-file techniques can trip antivirus heuristics** — both are Advanced, opt-in, explained and logged.
- **No official NVIDIA API** — this remains a reverse-engineered, community-maintained approach that needs re-verification after major driver changes.
- **Branding** — no NVIDIA logo, no exact brand green.

---

## 11. Build phases

- [x] **Phase 0 — Research & verify targets.** See §4. Key result: the legacy targets are gone on modern drivers; the junction is the real control point.
- [x] **Phase 1 — Core engine.** `TelemetryEngine.psm1`, `SnapshotStore.psm1`.
- [x] **Phase 2 — GUI shell.** `MainWindow.xaml`, theme, dark scrollbars.
- [x] **Phase 3 — Wire engine to GUI.** Cards, pills, switches, summary.
- [x] **Phase 4 — Undo + persistent log.** `ActionLog.psm1`, undo stack, Restore All.
- [x] **Phase 5 — Check for Updates.** `UpdateCheck.psm1` placeholder + banner.
- [x] **Phase 5b — Test Telemetry Status.** `StatusReport.psm1` + button (user request).
- [x] **Phase 6 — Packaging & publish.** Renamed to NvTeleGuard, README + MIT license, published to [github.com/derpfinger/NvTeleGuard](https://github.com/derpfinger/NvTeleGuard) with a portable zip on release v1.0.0. Still open: icon, optional `ps2exe` build, batch-undo elevated test (§9).
- [x] **Phase 7 — Real GitHub integration.** `Get-LatestReleaseInfo` now calls the GitHub Releases API for `derpfinger/NvTeleGuard` (TLS 1.2 forced, 404 = "no releases yet" handled gracefully).

---

## 12. Open questions / future enhancements
- Automatic drift check on launch with a "re-apply" prompt.
- Control for display-driver RAS / GameSessionTelemetry if a safe, non-DriverStore switch turns up.
- CLI/silent mode (`NvTeleGuard.ps1 -Apply Recommended`) for post-driver-update scripting.
- Code-signing to reduce SmartScreen friction.
- Automatic update check on launch once GitHub integration lands (currently manual only).
