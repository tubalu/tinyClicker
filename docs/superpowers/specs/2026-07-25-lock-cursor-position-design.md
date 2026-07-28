# Lock Cursor Position — Design

**Date:** 2026-07-25
**Status:** Approved

## Summary

Add an opt-in global toggle, **Lock Cursor Position**. When it is ON and the user
starts a Play All session (F10), the app remembers the cursor location at that
moment (the *anchor*) and returns the pointer to that anchor **after each macro
finishes a playback pass**. When OFF, playback behaves exactly as today.

This lets the user park the pointer at a chosen resting spot between macro runs,
even though individual macros move the mouse while they play.

## Motivation

Macros move the cursor as they replay recorded input. Between runs the pointer is
left wherever the last macro dropped it. The user wants the visible pointer to
return to a fixed spot after each macro pass instead of drifting.

An earlier idea — snapping the cursor back on a fixed 1-second timer — was
rejected because it would fight a macro *mid-click*. Restoring only on the
completion boundary is event-driven and never contends with an in-flight click.

## Behavior

- The anchor is captured **once**, at the moment Play All starts, only if the
  toggle is on.
- After every macro completes one playback pass (the `.completed` outcome in the
  scheduler's driver loop), the cursor is warped back to the anchor before that
  macro sleeps its interval.
- The anchor survives a mid-session driver restart (reordering or editing a
  recording re-runs `startAll`, but must not lose or re-capture the anchor).
- Stopping Play All (F10 again, or panic stop) clears the anchor.
- Default is **OFF** (opt-in).

## Design

### State — `AppState.swift`

- New `@Published var lockCursorPosition: Bool`, default `false`, persisted to
  `UserDefaults` key `tinyClicker.lockCursorPosition`. Mirrors the existing
  `pauseOnMouseMove` / `pauseOnOwnWindow` pattern (didSet persists; init loads
  with an `object(forKey:)` nil check).

### Capture — `AppState.playAll()`

```swift
let anchor = lockCursorPosition ? CGEvent(source: nil)?.location : nil
```

`CGEvent(source: nil)?.location` is the same global-display coordinate space the
scheduler already uses in `postClickAtCursor`, so it lines up with the warp API.
The anchor is handed to the scheduler through a dedicated `setCursorAnchor(_:)`
call — **not** a `startAll` parameter — because `update()` / `move()` also invoke
`startAll` mid-session and must neither re-capture nor drop the original anchor.

### Warp — `PlaybackScheduler` (`Scheduler.swift`)

- New actor state: `private var cursorAnchor: CGPoint? = nil`.
- New method: `func setCursorAnchor(_ anchor: CGPoint?) { cursorAnchor = anchor }`.
- In `driveRecording`, `.completed` branch (after `release()`, before the
  interval sleep):

  ```swift
  if let anchor = cursorAnchor { CGWarpMouseCursorPosition(anchor) }
  ```

- `panicStopAll()` and `stopAll()` clear it (`cursorAnchor = nil`).
- `stopAllInternal()` (called on reorder-restart) does **not** touch it, so the
  anchor persists across a mid-session restart.

### UI — `SpecialClickerView.swift`

Add `Toggle("Lock Cursor Position", isOn: $state.lockCursorPosition)` alongside
the existing global toggles, with a one-line caption explaining that it returns
the pointer to its start spot after each macro run.

## Key properties

- **Only real macros trigger it.** The Follow Cursor special clicker does not go
  through `driveRecording`, so it is unaffected — matching "after each macro
  played."
- **No conflict with `pauseOnMouseMove`.** `CGWarpMouseCursorPosition` teleports
  the pointer with no `mouseMoved` event, so `UserActivityMonitor` will not
  mistake the warp for user activity.
- **No polling loop / timer.** Purely event-driven off the completion path.

## Interaction with Follow Cursor (added v0.2.4)

When **both** Lock Cursor Position and the Follow Cursor Clicker are on, the
clicker clicks at the remembered anchor on **every** fire (a fixed target)
instead of following the live cursor. The per-macro warp is then skipped
(guarded by `specialActive` in `driveRecording`'s `.completed` branch) because
the clicker already keeps clicks landing on the anchor — warping would be
redundant.

- Lock off, clicker on → clicks at live cursor (original behavior).
- Lock on, clicker off → warps the pointer to the anchor after each macro.
- Lock on, clicker on → clicks at the anchor every fire; no per-macro warp.

Implementation: the anchor is captured into the special-clicker task in
`startSpecialClicker`; `postClickAtCursor` became `postClick(at:buttonIdx:)` so
the caller passes the resolved target (`anchor ?? live cursor`).

## Out of scope

- Re-capturing or editing the anchor mid-session.
- A visible on-screen marker for the anchor.
- Per-recording lock configuration (this is a single global toggle).
