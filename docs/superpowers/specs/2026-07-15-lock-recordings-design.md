# Lock Recordings — Design

## Problem

Pressing F9 toggles recording for the currently *selected* recording.
`AppState.stopRecording()` unconditionally overwrites that recording's
`events` with whatever was just captured. An accidental F9 press (or two,
to start then stop) silently destroys a recording the user cared about,
with no undo.

## Goal

Let the user mark individual recordings as **locked** so they can't be
accidentally overwritten, deleted, or edited via the event table, while
still allowing rename, interval changes, and the enabled toggle.

## Scope (confirmed with user)

Locking blocks:
- Starting a new capture over the recording (F9 / toolbar Record button)
- Deleting the recording (sidebar swipe-to-delete)
- Editing its event table (per-event fields + delete button in detail view)

Locking does **not** block:
- Renaming the recording
- Editing its interval
- Toggling "enabled" (used for Play All inclusion)

Lock toggle control lives in the sidebar row only — no separate control
in the detail view.

Blocked actions fail silently (disabled button / no-op) — no confirmation
dialogs or toast messages.

## Design

### 1. Data model — `Models.swift`

Add `var locked: Bool = false` to `Recording`.

`Recording` currently relies on Swift's compiler-synthesized `Decodable`
conformance. A synthesized decoder does **not** apply a property's default
value when a key is missing from the JSON — it calls `decode(Bool.self,
forKey: .locked)` and throws `DecodingError.keyNotFound` for any
`recordings.json` written before this feature ships (no `"locked"` key
exists yet). `Store.load()` swallows decode errors and returns `[]`,
which would silently wipe every saved recording on first launch after
upgrade.

To prevent this, `Recording` gets a custom `init(from decoder:)` that
decodes `locked` with `decodeIfPresent(Bool.self, forKey: .locked) ??
false`, while every other field keeps normal `decode(...)` (they've
always been present, no migration need). The synthesized `encode(to:)`
stays as-is — `locked` is always written going forward.

### 2. AppState guards — `AppState.swift`

- `startRecording()`: additionally refuses to start if the selected
  recording's `locked == true`.
- `stopRecording()`: additionally refuses to write captured events if
  the *currently selected* recording (re-read at stop time, not the
  recording selected when capture started) is locked.

  This closes a gap beyond the literal F9 case: nothing today prevents
  changing the sidebar selection while `isRecording == true` — the list
  selection binding has no recording-in-progress guard. Without this
  second check, a user could start recording on an unlocked item, switch
  selection to a locked one mid-capture, then press F9 — and the locked
  recording's events would be overwritten anyway, defeating the feature.
- `deleteRecording(id:)`: no-ops if the target recording is locked.
- New computed property `isSelectedRecordingLocked: Bool` (looks up
  `selectedId` in `recordings`, returns `false` if not found or
  unlocked) for the toolbar to read.

### 3. Sidebar row — `Views/RecordingListView.swift`

`RecordingRow` gains a trailing icon button:
- `lock.fill`, normal opacity, when `recording.locked == true`
- `lock.open`, dimmed (`.secondary.opacity(0.4)`), when `false`

Tapping toggles `recording.locked` through the same `state.update(_:)`
copy-and-write path the existing "enabled" checkbox uses. Disabled while
`state.isPlayingAll`, matching the enabled checkbox's existing rule (not
disabled during `isRecording`, since locking a *different* row while one
recording is in progress is harmless — and the `stopRecording()` guard
above covers the case where the locked row itself ends up selected).

Swipe-to-delete on a locked row: the trailing delete affordance still
appears (no per-row `.disabled` hook exists on `.onDelete`), but invoking
it calls `deleteRecording(id:)`, which now no-ops for locked recordings —
the row stays. The visible padlock is the cue for why nothing happened.

### 4. Toolbar — `Views/ToolbarView.swift`

Record button's `.disabled(...)` condition gains
`|| state.isSelectedRecordingLocked`. When disabled for that specific
reason, add `.help("Recording is locked")` so hovering explains it
(other disable reasons — no selection, playing all, no permission — keep
no tooltip, matching current behavior).

### 5. Event table — `Views/RecordingDetailView.swift`

`EventTable.isEditable` gains `&& !recording.locked`:

```swift
private var isEditable: Bool { !state.isRecording && !state.isPlayingAll && !recording.locked }
```

This disables every per-event `TextField` and the row delete button via
the same mechanism already used to freeze the table during active
recording/playback — no new disabling logic needed.

Name field, Interval field, and the Enabled toggle in
`RecordingDetailView` are untouched — they stay editable regardless of
lock state, per confirmed scope.

## Out of scope

- Confirmation dialogs or toast messages for blocked actions
- Lock toggle control in the detail view
- Bulk lock/unlock across multiple recordings
- Locking during active capture of that same recording (edge case
  covered defensively by the `stopRecording()` guard, not a UI feature)

## Testing

- Unit test (if a test target exists) or manual verification:
  - Lock a recording → Record button disables, F9 no-ops, tooltip shows.
  - Lock a recording → swipe-to-delete no-ops, row remains.
  - Lock a recording → event table fields/trash buttons disabled.
  - Unlock → all three re-enable.
  - Name/interval/enabled remain editable while locked.
  - Start recording on unlocked A, switch selection to locked B, press
    F9 → B's events unchanged, A still capturing/unaffected.
  - Old `recordings.json` (no `locked` key) loads without data loss;
    all recordings default to unlocked.
