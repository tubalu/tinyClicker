# tinyClicker

A native macOS recording clicker — record mouse clicks and key presses, then loop them back. Multiple recordings can run concurrently with **priority-based preemption**: the recording on top of the list takes priority; when it fires while a lower-priority one is mid-playback, the lower one pauses (releasing held inputs), the higher one runs to completion, then the lower one resumes from where it stopped.

## Features

- Records mouse-down / mouse-up (left/right/other) and key-down / key-up with modifier flags.
- Replays with timing fidelity (preserves original inter-event delays within a recording).
- Per-recording interval between iterations; loops indefinitely until stopped.
- Drag-to-reorder list — list order **is** the priority order (top = highest).
- Pause/resume preemption with held-input safety (releases stuck buttons/keys on pause, re-presses on resume).
- **Follow Cursor Clicker** — a separate auto-clicker that always clicks at the *current* cursor position (so it follows wherever the cursor is moved). Lowest priority: yields while any recording is mid-playback, fires during the gap between iterations. Configurable click rate (0.1–30 Hz) and button (left/right). The Enabled toggle is **armed state** — actual clicking only happens while a Play All session is running.
- **Yields to user input** — whenever you move the mouse, all playback (macros + Follow Cursor Clicker) silently pauses; it resumes ~0.5s after motion stops. tinyClicker's own posted events are filtered out via a source-data marker, so a macro's cursor teleports don't accidentally pause the macro.
- **Pauses when cursor is on tinyClicker's window** — so you can interact with the app while playback is armed without it stomping over you. (Caveat: if a macro is recorded to click somewhere inside tinyClicker, it will pause on that click and only resume when the cursor leaves the window — press F10 to fully stop.)
- Global hotkeys: **F9** toggles record start/stop (so the click that ends recording doesn't get captured); **F10** is a panic stop for all playback (macros + follow-cursor clicker).
- Persists recordings to `~/Library/Application Support/tinyClicker/recordings.json` and the Follow Cursor Clicker config to `UserDefaults`.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel
- Swift 5.9+ toolchain (ships with Xcode Command Line Tools)

## Build & run

```bash
make                      # build  ->  build/tinyClicker.app  (host arch; also wipes stale TCC entry)
make build-universal      # universal arm64+x86_64 .app (needs full Xcode; used by release pipeline)
make run                  # build + launch a fresh instance
make icon                 # regenerate Resources/icon.icns
make permission-reset     # manually wipe the Accessibility TCC entry
make clean                # remove build artifacts
```

Direct script equivalents (if you'd rather skip `make`): `./scripts/build-app.sh` and `swift scripts/generate-icon.swift`. The build script honors `UNIVERSAL=1` and `CONFIG=debug|release` env vars.

To open in Xcode (if installed):

```bash
open Package.swift
```

## CI / Releases

Two GitHub Actions workflows live under `.github/workflows/`:

- **`ci.yml`** — runs on every push to `main` and on pull requests. Builds the host-arch `.app` on a `macos-14` runner and uploads it as a workflow artifact for 7 days.
- **`release.yml`** — runs when you push a tag matching `v*` (e.g. `v0.1.0`), or via manual `workflow_dispatch`. Builds a universal `tinyClicker.app`, zips it with `ditto -c -k --sequesterRsrc --keepParent`, computes a SHA-256, and publishes a GitHub Release with both files attached.

To cut a release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow will pick it up, build, and publish. The published `.app` is ad-hoc signed — Intel/Apple-Silicon users will get the standard "unidentified developer" prompt on first launch (right-click → Open to bypass). For a smoother distribution experience, set up Developer ID signing (see the section above) and extend the release workflow to use it via repository secrets.

## Accessibility permission

The first launch triggers macOS's Accessibility permission prompt. Grant it under **System Settings → Privacy & Security → Accessibility**, then click **Relaunch** in the in-app banner — macOS only checks Accessibility at process start, so a running app cannot see a permission granted mid-life.

### Why the banner reappears after every rebuild

Each `make` produces a binary with a new ad-hoc code signature, which macOS treats as a fresh identity. The TCC database entry for the *previous* build's identity doesn't match the new one, so the toggle in Settings might still look ON but applies to a build that no longer exists. To make sure each new build starts from a clean slate, `make build` automatically runs `make permission-reset` before compiling. After launching, you'll just need to:

1. Click **Open Settings** in the banner.
2. Add tinyClicker to the Accessibility list (drag `build/tinyClicker.app` in, or use **+**).
3. Toggle it ON.
4. Click **Relaunch** in the banner.

### Making the permission persistent across rebuilds

Replace ad-hoc signing in `scripts/build-app.sh` with a stable code-signing identity:

```bash
codesign --force --sign "Developer ID Application: Your Name" "$APP_DIR"
# or, with a Personal Team cert created by Xcode:
codesign --force --sign "Apple Development: your@email.com (TEAM123)" "$APP_DIR"
```

With a stable signing identity the code requirement stays constant across rebuilds, so the TCC grant survives.

## Using

1. Click **New** in the toolbar (or ⌘N) to create a recording.
2. Select it, then press **F9** (or click **Record**) to start. Perform mouse clicks / key presses. Press **F9** again to stop — using the hotkey avoids capturing the stop click itself.
3. Set the interval (seconds between iterations) in the detail pane.
4. Check **Enabled** on each recording you want to participate in playback.
5. Drag rows in the sidebar to set priority (top = highest).
6. (Optional) In the **Follow Cursor Clicker** section at the bottom of the sidebar, set a rate, choose Left or Right button, and toggle **Enabled** to arm it for the next Play All session.
7. Click **Play All**. The first eligible recording starts immediately; others wait per priority. If the Follow Cursor Clicker is armed, it runs alongside the macros and yields to them.
8. Move the mouse → all playback pauses; stop moving for ~0.5s → it resumes.
9. Move the cursor over tinyClicker's window → all playback pauses; move it away → it resumes.
10. Press **F10** at any time to stop everything.

## Architecture

| File | Responsibility |
|---|---|
| `Models.swift` | `RecordedEvent`, `Recording` Codable structs |
| `Recorder.swift` | `CGEventTap` listener that captures global input |
| `Player.swift` | `CGEvent.post` with cooperative pause + held-input tracking; also owns `InputSource` (the marked event source used to tag our own posted events) |
| `Scheduler.swift` | Actor coordinating concurrent drivers + preemption (incl. follow-cursor driver at `Int.max` priority) |
| `SpecialClicker.swift` | Follow-cursor clicker config + UserDefaults persistence |
| `Store.swift` | JSON load/save for recordings |
| `Permissions.swift` | Accessibility trust check (uncached) + distributed-notification listener + Quit/Relaunch helpers |
| `HotKey.swift` | Carbon `RegisterEventHotKey` for F9 (record toggle) and F10 (panic stop) |
| `UserActivityMonitor.swift` | Singleton `CGEventTap` tracking user mouse-motion timestamps; filters out our own posted events via source-data marker |
| `WindowGuard.swift` | Static helper: is the cursor currently inside any of tinyClicker's visible windows? |
| `AppState.swift` | `@MainActor ObservableObject` tying it all together |
| `Views/` | SwiftUI sidebar list, detail pane, toolbar, Follow Cursor Clicker section, permission banner |

## Limitations (intentional, v1)

- Mouse movement paths are not captured — only click positions. Replay teleports the cursor between clicks.
- Scroll-wheel events are not recorded.
- Recordings cannot be edited after capture (only re-recorded).
- Hotkeys are hard-coded (F9 record toggle, F10 panic stop) and not user-configurable yet.
- The user-input pause and own-window pause both use fixed thresholds (0.5s settle for motion; immediate for window) — no slider to tune them.
- No automated tests — global input automation is awkward to test reliably; verification is manual (see `~/.claude/plans/plan-create-macos-quiet-flute.md`).
# tinyClicker
