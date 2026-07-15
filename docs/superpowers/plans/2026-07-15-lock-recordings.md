# Lock Recordings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users mark individual recordings as locked so they can't be overwritten by F9/Record, deleted, or edited in the event table — while name, interval, and the enabled toggle stay editable.

**Architecture:** Add a `locked: Bool` field to the `Recording` model (with a hand-written `Decodable` initializer for backward compatibility with existing saved data), then add guard checks at every mutation point that could destroy a locked recording's data (`AppState.startRecording/stopRecording/deleteRecording`), and reflect lock state in the two relevant views (sidebar row toggle, toolbar Record button, detail event table).

**Tech Stack:** Swift 5.9, SwiftUI, macOS 13+, Swift Package Manager (`swift build`). No test target exists in this package — verification is via `swift build` (compiles) plus manual reasoning/checklist, matching the project's current lack of automated tests.

## Global Constraints

- Platform floor: macOS 13.0 (`Package.swift`, `Info.plist` `LSMinimumSystemVersion`).
- Swift tools version: 5.9 (`Package.swift` first line) — do not use newer-only syntax.
- Every feature-completing commit in this repo bumps `Resources/Info.plist`: `CFBundleShortVersionString` (patch +1, e.g. `0.1.5` → `0.1.6`) and `CFBundleVersion` (+1, e.g. `6` → `7`), per `CLAUDE.md`. Current values: `0.1.5` / `6`.
- Do not `git push` or create the `v<version>` tag as part of this plan — pushing a `v*` tag triggers a public GitHub Actions release build (`.github/workflows/release.yml`). That step requires separate explicit user confirmation and is out of scope for "implementation done."
- No confirmation dialogs/toasts for blocked actions (spec decision) — disabled controls / silent no-ops only.
- Lock toggle control lives in the sidebar row only, not in the detail view (spec decision).

---

### Task 1: `Recording` model gains `locked` with backward-compatible decoding

**Files:**
- Modify: `Sources/tinyClicker/Models.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Recording.locked: Bool` (defaults to `false` via memberwise init and via decode-if-missing), used by Tasks 2–4.

- [ ] **Step 1: Add the `locked` property and update the memberwise init**

In `Sources/tinyClicker/Models.swift`, change the `Recording` struct (currently lines 39–63) to:

```swift
struct Recording: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var events: [RecordedEvent]
    var intervalSeconds: Double
    var enabled: Bool
    var locked: Bool

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        events: [RecordedEvent] = [],
        intervalSeconds: Double = 2.0,
        enabled: Bool = false,
        locked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.events = events
        self.intervalSeconds = intervalSeconds
        self.enabled = enabled
        self.locked = locked
    }

    var duration: TimeInterval {
        events.last?.timestamp ?? 0
    }
}
```

- [ ] **Step 2: Add a hand-written `Decodable` initializer so old `recordings.json` files (no `"locked"` key) still load**

Adding a custom `init(from:)` does not remove the explicit memberwise init from Step 1 (only compiler-*synthesized* memberwise inits get dropped when you add other initializers). Add this directly below the memberwise init, still inside the `Recording` struct:

```swift
    enum CodingKeys: String, CodingKey {
        case id, name, events, intervalSeconds, enabled, locked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        events = try container.decode([RecordedEvent].self, forKey: .events)
        intervalSeconds = try container.decode(Double.self, forKey: .intervalSeconds)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
```

`encode(to:)` stays compiler-synthesized (declaring `CodingKeys` explicitly does not require a manual `encode(to:)`) — it will now always write `"locked"`.

- [ ] **Step 3: Verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Code-review the decode logic**

Confirm by inspection: every field except `locked` uses non-optional `decode(...)` (so old files failing to have those keys would still correctly throw — they always had those keys); only `locked` uses `decodeIfPresent(...) ?? false`. This is the intended asymmetry — don't "fix" it to be symmetric.

- [ ] **Step 5: Commit is deferred**

Per repo convention (confirmed via `git log`), commits in this repo represent one complete shippable change with a version bump, not per-task WIP snapshots. Do not commit yet — continue to Task 2. (Final commit + version bump happens in Task 6.)

---

### Task 2: `AppState` guards against mutating locked recordings

**Files:**
- Modify: `Sources/tinyClicker/AppState.swift:107-161`

**Interfaces:**
- Consumes: `Recording.locked` (Task 1).
- Produces: `AppState.isSelectedRecordingLocked: Bool`, used by Task 4 (toolbar).

- [ ] **Step 1: Guard `deleteRecording`**

In `Sources/tinyClicker/AppState.swift`, replace:

```swift
    func deleteRecording(id: UUID) {
        recordings.removeAll { $0.id == id }
        if selectedId == id { selectedId = recordings.first?.id }
    }
```

with:

```swift
    func deleteRecording(id: UUID) {
        guard recordings.first(where: { $0.id == id })?.locked != true else { return }
        recordings.removeAll { $0.id == id }
        if selectedId == id { selectedId = recordings.first?.id }
    }
```

- [ ] **Step 2: Guard `startRecording`**

Replace:

```swift
    func startRecording() {
        guard !isRecording else { return }
        guard let id = selectedId,
              recordings.firstIndex(where: { $0.id == id }) != nil else { return }
        let started = recorder.start()
        if started {
            isRecording = true
        }
    }
```

with:

```swift
    func startRecording() {
        guard !isRecording else { return }
        guard let id = selectedId,
              let idx = recordings.firstIndex(where: { $0.id == id }),
              !recordings[idx].locked else { return }
        let started = recorder.start()
        if started {
            isRecording = true
        }
    }
```

- [ ] **Step 3: Guard `stopRecording`**

Replace:

```swift
    func stopRecording() {
        guard isRecording else { return }
        let events = recorder.stop()
        isRecording = false
        guard let id = selectedId,
              let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].events = events
    }
```

with:

```swift
    func stopRecording() {
        guard isRecording else { return }
        let events = recorder.stop()
        isRecording = false
        guard let id = selectedId,
              let idx = recordings.firstIndex(where: { $0.id == id }),
              !recordings[idx].locked else { return }
        recordings[idx].events = events
    }
```

Note: this re-reads `selectedId` at stop time (matching existing behavior) — it deliberately protects against the case where the selection changed to a locked recording *while capturing was in progress*, not just the simple "selected a locked recording and pressed Record" case.

- [ ] **Step 4: Add the `isSelectedRecordingLocked` computed property**

Add this new computed property in the `// MARK: - Record` section, directly above `func startRecording()`:

```swift
    var isSelectedRecordingLocked: Bool {
        guard let id = selectedId else { return false }
        return recordings.first(where: { $0.id == id })?.locked ?? false
    }
```

- [ ] **Step 5: Verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

---

### Task 3: Sidebar lock toggle

**Files:**
- Modify: `Sources/tinyClicker/Views/RecordingListView.swift:42-78`

**Interfaces:**
- Consumes: `Recording.locked` (Task 1), `state.update(_:)` (existing, unchanged), `state.isPlayingAll` (existing).
- Produces: nothing consumed by later tasks — this is a leaf UI change.

- [ ] **Step 1: Add the lock button to `RecordingRow`**

In `Sources/tinyClicker/Views/RecordingListView.swift`, the `RecordingRow` body currently is:

```swift
struct RecordingRow: View {
    @EnvironmentObject var state: AppState
    let recording: Recording

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { recording.enabled },
                set: { newValue in
                    var copy = recording
                    copy.enabled = newValue
                    state.update(copy)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(state.isPlayingAll)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name)
                    .lineLimit(1)
                Text("\(recording.events.count) events · \(String(format: "%.1fs", recording.duration))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if state.nowPlayingId == recording.id {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 2)
    }
}
```

Replace it with (adds a trailing lock button after the now-playing indicator):

```swift
struct RecordingRow: View {
    @EnvironmentObject var state: AppState
    let recording: Recording

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { recording.enabled },
                set: { newValue in
                    var copy = recording
                    copy.enabled = newValue
                    state.update(copy)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(state.isPlayingAll)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name)
                    .lineLimit(1)
                Text("\(recording.events.count) events · \(String(format: "%.1fs", recording.duration))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if state.nowPlayingId == recording.id {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            Button {
                var copy = recording
                copy.locked.toggle()
                state.update(copy)
            } label: {
                Image(systemName: recording.locked ? "lock.fill" : "lock.open")
                    .foregroundColor(recording.locked ? .secondary : .secondary.opacity(0.4))
            }
            .buttonStyle(.borderless)
            .disabled(state.isPlayingAll)
            .help(recording.locked ? "Locked — click to unlock" : "Click to lock")
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

---

### Task 4: Toolbar Record button respects lock

**Files:**
- Modify: `Sources/tinyClicker/Views/ToolbarView.swift:29-36`

**Interfaces:**
- Consumes: `state.isSelectedRecordingLocked` (Task 2).
- Produces: nothing consumed by later tasks — leaf UI change.

- [ ] **Step 1: Disable Record and add a tooltip when the selection is locked**

In `Sources/tinyClicker/Views/ToolbarView.swift`, replace:

```swift
                Button {
                    state.startRecording()
                } label: {
                    Label("Record (F9)", systemImage: "record.circle")
                }
                .disabled(state.selectedId == nil || state.isPlayingAll || !permissions.isTrusted)
```

with:

```swift
                Button {
                    state.startRecording()
                } label: {
                    Label("Record (F9)", systemImage: "record.circle")
                }
                .disabled(
                    state.selectedId == nil
                    || state.isPlayingAll
                    || !permissions.isTrusted
                    || state.isSelectedRecordingLocked
                )
                .help(state.isSelectedRecordingLocked ? "Recording is locked" : "")
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

---

### Task 5: Event table becomes read-only when locked

**Files:**
- Modify: `Sources/tinyClicker/Views/RecordingDetailView.swift:88`

**Interfaces:**
- Consumes: `Recording.locked` (Task 1).
- Produces: nothing consumed by later tasks — leaf UI change.

- [ ] **Step 1: Add the lock check to `isEditable`**

In `Sources/tinyClicker/Views/RecordingDetailView.swift`, replace:

```swift
    private var isEditable: Bool { !state.isRecording && !state.isPlayingAll }
```

with:

```swift
    private var isEditable: Bool { !state.isRecording && !state.isPlayingAll && !recording.locked }
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

---

### Task 6: Full-app verification, version bump, and commit

**Files:**
- Modify: `Resources/Info.plist:21-24`

**Interfaces:**
- Consumes: all of Tasks 1–5.
- Produces: nothing (terminal task).

- [ ] **Step 1: Full clean build**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings introduced by this change.

- [ ] **Step 2: Manual code-review checklist against the spec**

Re-read `docs/superpowers/specs/2026-07-15-lock-recordings-design.md` "Testing" section and confirm by inspection of the diff:
- [ ] Lock a recording → `startRecording()` returns early (Task 2 Step 2) → Record button also visibly disabled (Task 4) with tooltip.
- [ ] Lock a recording → `deleteRecording()` returns early (Task 2 Step 1) → swipe-to-delete no-ops.
- [ ] Lock a recording → `EventTable.isEditable` is `false` (Task 5) → all per-event fields and trash buttons disabled.
- [ ] Unlocking (toggle button, Task 3) flips `recording.locked` back to `false` → all three re-enable, since all guards read `recording.locked`/`recordings[idx].locked` live off the `@Published var recordings`.
- [ ] Name field, Interval field, and Enabled toggle in `RecordingDetailView.swift` and `RecordingListView.swift` have no `locked` check added — confirmed untouched by Tasks 1–5.
- [ ] Start recording on unlocked A, switch selection to locked B, press F9 → `stopRecording()` re-reads `selectedId` (now B), sees `recordings[idx].locked == true`, returns before writing — B's `events` unchanged (Task 2 Step 3).
- [ ] Old-format `recordings.json` (no `"locked"` key) — `decodeIfPresent` in Task 1 Step 2 defaults it to `false`, so `Store.load()` no longer throws/returns `[]` for pre-existing files.

If any box doesn't check out, fix the relevant task's code before proceeding — do not bump the version on a broken build.

- [ ] **Step 3: Bump the version per `CLAUDE.md`**

In `Resources/Info.plist`, change:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.1.5</string>
    <key>CFBundleVersion</key>
    <string>6</string>
```

to:

```xml
    <key>CFBundleShortVersionString</key>
    <string>0.1.6</string>
    <key>CFBundleVersion</key>
    <string>7</string>
```

- [ ] **Step 4: Final build check after the version bump**

Run: `swift build`
Expected: `Build complete!` (Info.plist changes don't affect Swift compilation, but this confirms nothing else broke.)

- [ ] **Step 5: Review staged changes before committing**

Run: `git status --short` and `git diff -- Sources Resources`
Expected: only `Sources/tinyClicker/Models.swift`, `Sources/tinyClicker/AppState.swift`, `Sources/tinyClicker/Views/RecordingListView.swift`, `Sources/tinyClicker/Views/ToolbarView.swift`, `Sources/tinyClicker/Views/RecordingDetailView.swift`, and `Resources/Info.plist` are modified. No unrelated files.

- [ ] **Step 6: Commit**

```bash
git add Sources/tinyClicker/Models.swift Sources/tinyClicker/AppState.swift Sources/tinyClicker/Views/RecordingListView.swift Sources/tinyClicker/Views/ToolbarView.swift Sources/tinyClicker/Views/RecordingDetailView.swift Resources/Info.plist
git commit -m "$(cat <<'EOF'
feat: lock recordings to prevent accidental F9 overwrite

Recordings can now be locked from the sidebar (padlock icon). A locked
recording can't be re-recorded (F9/Record disabled), deleted, or have
its event table edited, while name/interval/enabled stay editable.
EOF
)"
```

Expected: commit succeeds; `git log -1 --stat` shows the six files above.

- [ ] **Step 7: Stop here — do not tag or push**

Per Global Constraints, tagging `v0.1.6` and pushing (which triggers the public release workflow) requires separate explicit user confirmation. Report completion and wait.

---

## Post-plan note for the executor

There is no way to interactively click-test this SwiftUI macOS app's UI from within an agent session (no Accessibility permission grant, no screen access, no browser tooling applies to a native AppKit/SwiftUI app). Task 6 Step 2's checklist is a code-level substitute for the manual QA checklist in the spec. If the user wants full interactive verification, they'll need to run `swift build && swift run` (or the `run` skill, if this project has one configured) themselves and click through the scenarios.
