# Learning Swift by reading tinyClicker

This guide assumes you've never written a line of Swift. By the end, you should be able to open any file in `Sources/tinyClicker/` and follow what it does — not because you've memorized syntax, but because you've seen each construct in context.

The guide is laid out in five parts. Read them in order if you're starting from zero, or jump around if you're chasing a specific concept.

1. [What tinyClicker is, and why Swift](#1-what-tinyclicker-is-and-why-swift)
2. [Just enough Swift syntax to read the code](#2-just-enough-swift-syntax-to-read-the-code)
3. [The Apple frameworks you'll meet](#3-the-apple-frameworks-youll-meet)
4. [A file-by-file tour of the codebase](#4-a-file-by-file-tour-of-the-codebase)
5. [Making changes confidently](#5-making-changes-confidently)

---

## 1. What tinyClicker is, and why Swift

tinyClicker is a macOS app that:

- **records** sequences of mouse clicks and key presses by tapping into the system-wide input event stream,
- **replays** them at configurable intervals, with priority-based preemption so a higher-priority recording can pause a lower-priority one and resume it later,
- and adds a **"Follow Cursor Clicker"** that auto-clicks at the live cursor position, lowest priority, only while a Play All session is active.

It needs three things that any modern alternative (Electron, Python+Tk, Tauri) makes painful:

1. **Tapping the global event stream** — `CGEventTap` is a C API exposed through Apple's CoreGraphics framework. Swift talks to it directly.
2. **Posting synthetic input** — `CGEvent.post` is the inverse of the above, also CG-native.
3. **A native macOS UI** with a sidebar list, drag-to-reorder, and accessibility-permission flow — SwiftUI handles this in a couple hundred lines, and the resulting `.app` is ~600 KB.

Swift makes the C bridge cheap (the function call looks like a normal method) and gives you SwiftUI on top. That combination is why this codebase is ~1,900 lines instead of 5,000.

---

## 2. Just enough Swift syntax to read the code

Swift is C-family syntax with a heavy emphasis on **values are immutable by default** and **the type system tracks whether something can be `nil`**. The two ideas above explain the bulk of what you'll see.

### Variables: `let` and `var`

```swift
let name = "tinyClicker"   // immutable. Compiler error if you try to reassign.
var counter = 0            // mutable.
counter += 1
```

You should default to `let`. The codebase uses `var` only where state genuinely changes (a buffer being appended to, a cursor being advanced, etc.).

### Types are inferred but explicit when helpful

```swift
let count = 10                 // Int, inferred
let rate: Double = 5.0         // Double, explicit
let names: [String] = []       // empty array — type cannot be inferred, so you spell it out
```

You'll see the explicit form (`let x: SomeType = ...`) in three situations: empty collections, function signatures, and stored properties on types.

### Optionals — Swift's biggest single idea

A value of type `T` cannot be `nil`. A value of type `T?` *might* be `nil`. The compiler enforces this everywhere.

```swift
var name: String       = "yong"   // never nil
var nickname: String?  = nil      // can be nil
nickname = "y"
```

You unwrap an optional one of four ways. You'll see all four in this codebase.

| Form | Example | When to use |
|---|---|---|
| `if let` | `if let n = nickname { print(n) }` | "Do something only if there's a value." |
| `guard let` | `guard let n = nickname else { return }` | "Bail early if there's no value; below this line `n` is non-optional." |
| `?` (optional chaining) | `nickname?.uppercased()` | Returns optional. If `nickname == nil`, the whole expression is `nil`. |
| `??` (default) | `nickname ?? "anonymous"` | "Use this fallback if nil." |

You will almost never see force-unwrap (`!`) in this codebase, because it crashes when the value is `nil`. The places we do use it are explicit assertions, like inside `NSBitmapImageRep(...)!` in the icon generator where we know the call cannot fail with our inputs.

### Closures

A closure is a chunk of code you can pass around like a value.

```swift
let double: (Int) -> Int = { x in x * 2 }
double(3)   // 6
```

The most common shape you'll see is the **trailing closure**: when a function's last argument is a closure, you can write the body after the call's parentheses.

```swift
[1, 2, 3].map { $0 * 2 }
// equivalent to: [1, 2, 3].map({ x in x * 2 })
```

`$0`, `$1`, etc. are implicit parameter names when you don't bother naming them.

You'll also see **capture lists** like `{ [weak self] in ... }`. These tell Swift "inside this closure, hold `self` weakly so we don't create a reference cycle." Look at `Sources/tinyClicker/AppState.swift` — every timer and notification handler uses `[weak self]`.

### Structs, classes, actors, enums — the four "type kinds"

Swift has more kinds of types than most languages. The differences matter; you'll see each one in this codebase.

```swift
struct  Recording      { var name: String; var events: [RecordedEvent] }  // value type — copied on assignment
class   Recorder       { /* ... */ }                                       // reference type — shared
actor   PlaybackScheduler { /* ... */ }                                    // reference type, but isolated for concurrency
enum    RecordedEventKind { case mouseDown, mouseUp, keyDown, keyUp }      // tagged union
```

Mental model:

- **`struct`**: a record of values. When you assign or pass one, you get a copy. `Recording`, `RecordedEvent`, and `SpecialClicker` are all structs because copying them is cheap and clear.
- **`class`**: a reference. Two variables pointing to the same class instance see each other's mutations. `Recorder`, `Player`, `HotKey` are classes because they own long-lived state (a system event tap, an event-source pointer, etc.).
- **`actor`**: a class that the compiler guarantees can only be touched by one thread at a time. `PlaybackScheduler` is an actor so that two concurrent macro drivers calling `acquire`/`release` can't corrupt the internal queue.
- **`enum`**: a closed set of cases. Swift enums are more powerful than C: they can carry associated values (`case paused(at: Int, held: [HeldInput])`).

### Protocols — Swift's interfaces

A protocol is a list of requirements. A type "conforms to" a protocol by satisfying them.

```swift
struct Recording: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    // ...
}
```

- `Codable`: "I can be encoded to and decoded from JSON." Free to conform if all your stored properties are also `Codable`.
- `Identifiable`: "I have an `id`." SwiftUI's `List` and `ForEach` need this to track items efficiently.
- `Equatable`: "I can be compared with `==`."

These conformances are how `Store.swift` turns an array of `Recording`s into JSON for `~/Library/Application Support/tinyClicker/recordings.json` with two lines:

```swift
let encoder = JSONEncoder()
let data = try encoder.encode(recordings)
```

### Concurrency: `async`, `await`, `Task`, `actor`, `@MainActor`

This is the part that takes the longest to get comfortable with, but it's worth the effort because it's everywhere in this codebase.

#### `async` and `await`

A function marked `async` can suspend itself and come back later. You call it with `await`.

```swift
func play(_ recording: Recording) async -> PlaybackOutcome { /* ... */ }

// caller:
let outcome = await player.play(recording)
```

`await` is like `await` in JavaScript or Python: it pauses the current function, lets other work happen, and resumes when the awaited call returns.

#### `Task`

`Task { ... }` spawns concurrent work. The body is `async`. Use it whenever you want code to run "in parallel" with the rest of the app.

```swift
Task {
    let outcome = await scheduler.startAll(recordings)
    // back here once startAll returns
}
```

#### `actor`

An actor is a class whose state is protected. You can only touch its properties or methods from inside the actor or by `await`ing them from outside.

```swift
actor PlaybackScheduler {
    private var runningPriority: Int? = nil
    func acquire(priority: Int) async -> PauseSignal { /* ... */ }
}

// caller:
let signal = await scheduler.acquire(priority: 0)
```

The `await` isn't because the call takes a long time — it's because the caller might need to wait its turn to talk to the actor.

#### `@MainActor`

Some code can only run on the main thread (anything that touches AppKit/SwiftUI). Mark it with `@MainActor`:

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var recordings: [Recording] = []
}
```

Any method on `AppState` is implicitly main-thread-isolated. From an actor or a `Task`, you call it with `await`.

You'll also see `Task { @MainActor in ... }` — that says "start a task that begins on the main actor."

### Property wrappers (`@Published`, `@StateObject`, etc.)

Property wrappers are a way to attach behavior to a stored property. The ones in this codebase are all SwiftUI / Combine ergonomics:

- `@Published` on `AppState.recordings`: any change to this property emits a notification through Combine, which SwiftUI listens to for re-rendering.
- `@StateObject` on `tinyClickerApp.state`: "create this `ObservableObject` once, on first view appearance, and hold onto it for the view's lifetime."
- `@EnvironmentObject`: "find an instance of this type that some ancestor view injected into the environment."
- `@MainActor`: technically a global-actor attribute, not a wrapper, but you read it the same way — "this thing belongs to the main actor."

You don't need to understand the wrapping mechanism. Treat them as annotations that say "here's how SwiftUI should treat this."

---

## 3. The Apple frameworks you'll meet

A modern macOS app stitches together several frameworks. Here's the short version of which one does what.

### Foundation

Standard library, mostly. `String`, `Array`, `Dictionary`, `URL`, `Date`, `JSONEncoder`, `NSLock`. If you `import Foundation`, you're pulling all of these in.

### AppKit

The OG macOS UI framework, descended from NextStep. Class names start with `NS`. We touch it only sparingly — `NSApplication`, `NSWindow`, `NSScreen`, `NSColor`, `NSBitmapImageRep` (for icon generation). SwiftUI on macOS quietly sits on top of AppKit, so when something fails deep in SwiftUI you sometimes see `NSWindow` in the stack trace.

### SwiftUI

The declarative UI framework. Views are structs whose `body` describes what they look like; SwiftUI computes the difference on each state change and redraws.

```swift
struct ToolbarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            Button("Record") { state.startRecording() }
            Button("Play All") { state.playAll() }
        }
    }
}
```

You'll see this pattern everywhere in `Sources/tinyClicker/Views/`.

### CoreGraphics

The 2D drawing and event framework. We use it for two things:

- `CGEvent` + `CGEventTap`: the low-level event stream we observe (in `Recorder.swift`, `UserActivityMonitor.swift`) and post into (in `Player.swift`, `Scheduler.swift`).
- `CGPoint` / `CGFloat` / `CGEventSource`: coordinates and the marker we stamp on our own posted events.

### Combine

Apple's reactive-streams library. We use it minimally: `$recordings.debounce(...).sink { ... }` in `AppState.swift` to persist recordings to JSON 500 ms after the last edit. Treat it as "publishers + sinks, with operators between them."

### Carbon (yes, that Carbon)

The pre-Cocoa Mac API, still useful because `RegisterEventHotKey` lets you bind a global hotkey without Accessibility permission. `HotKey.swift` is a thin Swift wrapper around it. You won't see Carbon elsewhere.

### ApplicationServices

Contains `AXIsProcessTrustedWithOptions` — the Accessibility-permission check we run from `Permissions.swift`.

---

## 4. A file-by-file tour of the codebase

Now the payoff. Each file below introduces one or two Swift concepts in context.

### `Package.swift`

The Swift Package Manager manifest. It declares this directory as a package named `tinyClicker`, building an executable target whose source lives under `Sources/tinyClicker/`. SPM is to Swift what Cargo is to Rust or npm is to JavaScript.

```swift
let package = Package(
    name: "tinyClicker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "tinyClicker", path: "Sources/tinyClicker")
    ]
)
```

The single `swift build` command reads this, compiles all `.swift` files under `Sources/tinyClicker/`, and writes an executable. The `scripts/build-app.sh` wrapper then takes that executable and assembles it into a `tinyClicker.app` bundle.

### `tinyClickerApp.swift`

The entry point.

```swift
@main
struct tinyClickerApp: App {
    @StateObject private var state = AppState()
    @StateObject private var permissions = PermissionMonitor()

    var body: some Scene {
        WindowGroup("tinyClicker") {
            ContentView()
                .environmentObject(state)
                .environmentObject(permissions)
        }
    }
}
```

`@main` says "this struct's `main()` method is the entry point." `App` is a SwiftUI protocol; `body: some Scene` tells SwiftUI what windows to show. We create one `AppState` and one `PermissionMonitor`, then inject them into the environment so any child view can `@EnvironmentObject` them.

**Concepts on display**: `@main`, protocols (`App`), `@StateObject`, environment injection.

### `Models.swift`

Plain data types. Two structs (`RecordedEvent`, `Recording`) and an enum (`RecordedEventKind`). All `Codable` so they round-trip to JSON; `Identifiable` so SwiftUI lists can track them; `Equatable` so we can compare snapshots.

**Concepts on display**: `struct`, `enum`, protocol conformance (`Codable`, `Identifiable`, `Equatable`), optional properties (`position: CGPoint?`).

### `Recorder.swift`

Wraps a `CGEventTap` that listens to global mouse + key events while a recording session is active. The interesting bits:

```swift
let refcon = Unmanaged.passUnretained(self).toOpaque()
let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
    let recorder = Unmanaged<Recorder>.fromOpaque(refcon!).takeUnretainedValue()
    recorder.handle(type: type, event: cgEvent)
    return Unmanaged.passUnretained(cgEvent)
}
```

`CGEventTap` is a C API that wants a C-style function pointer and an opaque pointer for user data. Swift can't pass a method directly to a C function pointer, so we hand-roll the bridge: `Unmanaged.passUnretained(self).toOpaque()` produces a `void*` we hand to CG; inside the callback we reverse the operation to get our `Recorder` back. It looks gnarly, but you only have to write it once per tap.

**Concepts on display**: C interop via `Unmanaged`, raw pointers (`UnsafePointer` indirectly), function-pointer typealiases (`CGEventTapCallBack`).

### `Player.swift`

Replays a recording. The interesting Swift concepts here are:

1. **Sentinel signal via an actor**: `PauseSignal` is a tiny actor holding a single `Bool`. The scheduler flips it to ask the player to pause; the player checks it between events.
2. **Async function with rich return type**: `play(_:from:restoring:pauseSignal:) async -> PlaybackOutcome`. The outcome is an enum with associated values:

   ```swift
   enum PlaybackOutcome {
       case completed
       case paused(at: Int, held: [HeldInput])
       case cancelled
   }
   ```

   The caller pattern-matches with `switch` and gets exactly the right data for each case.
3. **`InputSource.marked`**: a static computed `CGEventSource?` stamped with our marker so the user-activity tap can recognize our own posted events and ignore them. Static lets you have a "one per type" lazy global.

**Concepts on display**: actors as flags, enums with associated values, `switch` exhaustive matching, `static let` lazy singletons.

### `Scheduler.swift`

The heart of the app. An `actor` that:

- spawns one `Task` per enabled recording (the "driver"),
- holds a queue of priority-ordered waiters,
- coordinates pause/resume when a higher-priority driver wants the slot,
- also drives the Follow Cursor Clicker as a special case at `Int.max` priority.

Read it slowly. The four methods you care about are:

- `startAll(_:)` — entry point from "Play All". Spawns drivers.
- `acquire(priority:recordingId:)` — driver blocks until it can take the slot.
- `release()` — driver hands the slot back; wakes the highest-priority waiter.
- `panicStopAll()` — F10 hits this; cancels all drivers and releases held inputs.

**Concepts on display**: `actor` keyword, `Task` + `Task.isCancelled`, `withCheckedContinuation` for bridging between callback APIs and async, weak captures (`[weak self]` inside the driver Task).

### `SpecialClicker.swift`

A struct holding the Follow Cursor Clicker's config (rate, button, enabled). Also defines `ClickButton`, a tiny enum, and provides `static func load() / func save()` to round-trip through `UserDefaults`. This is `Codable` doing real work: we encode the struct to JSON and stash it in `UserDefaults` under a single key.

**Concepts on display**: `enum: CaseIterable` (for SwiftUI pickers), nested static methods, `UserDefaults`.

### `Store.swift`

Persistence for recordings. A struct (`Store`) with `load()` and `save(_:)` methods that read/write a JSON file under `~/Library/Application Support/tinyClicker/`. Pure Foundation; no third-party JSON library because Swift ships one (`JSONEncoder`/`JSONDecoder`) in the standard library.

**Concepts on display**: `FileManager`, `URL` for file paths, `try?` (turns a throwing call into an optional — `nil` on failure).

### `Permissions.swift`

A `@MainActor` `ObservableObject` that monitors Accessibility permission. It exposes a `@Published` `isTrusted: Bool` so the SwiftUI banner re-renders when permission state changes. It:

- subscribes to `NSApplication.didBecomeActiveNotification` (recheck on foreground),
- subscribes to `com.apple.accessibility.api` via `DistributedNotificationCenter` (system-wide AX-state-changed notification),
- polls every second as a fallback,
- exposes `prompt()`, `openSystemSettings()`, `quitApp()`, and `relaunchApp()` for the banner buttons.

The Combine-style notification observers all use `Task { @MainActor [weak self] in self?.refresh() }`. Note the explicit `[weak self]` on the inner Task — Swift 6's strict concurrency requires this, since the Task is a separate concurrency domain from the closure that created it.

**Concepts on display**: `ObservableObject`, `@Published`, `@MainActor` on a class, `NotificationCenter`, `DistributedNotificationCenter`, `Timer.scheduledTimer`, `NSWorkspace`, `URL(string:)`.

### `HotKey.swift`

A thin wrapper around Carbon's `RegisterEventHotKey`. The interesting bit: Carbon callbacks are C functions, so we can't directly close over Swift state. The workaround is a `static var registry: [UInt32: HotKey]` that maps the hotkey's numeric ID back to the Swift object. The C callback looks up the right object and calls its `fire()`. This is the same C-bridge dance as `Recorder.swift` but with a different shape.

**Concepts on display**: static dictionaries for callback-routing, Carbon types (`EventHotKeyRef`, `EventTypeSpec`).

### `UserActivityMonitor.swift`

Singleton (`static let shared`) that runs a `CGEventTap` on `mouseMoved` and the three `mouseDragged` variants. Each event is checked against our source marker; if it's ours, we skip it, otherwise we update `lastUserActivity = CFAbsoluteTimeGetCurrent()` under an `NSLock`. Player and Scheduler call `isUserActive(within: 0.5)` between events.

**Concepts on display**: singleton via `static let shared`, `NSLock` for synchronizing across threads, `CFAbsoluteTimeGetCurrent()` for high-resolution timestamps.

### `WindowGuard.swift`

A `@MainActor` `enum` with one static method, `cursorIsInOwnWindow() -> Bool`. Using `enum` as a namespace for static functions is idiomatic Swift — it can't be instantiated, which makes the intent clear: "these methods don't belong to any value."

```swift
enum WindowGuard {
    @MainActor static func cursorIsInOwnWindow() -> Bool { /* ... */ }
}
```

**Concepts on display**: `enum` as namespace, coordinate-system conversion (CG top-left origin vs Cocoa bottom-left origin).

### `AppState.swift`

The top-level coordinator. Holds the published state (`recordings`, `selectedId`, `isRecording`, `isPlayingAll`, `nowPlayingId`, `specialClicker`), owns the service instances (`Recorder`, `PlaybackScheduler`, `Store`, `HotKey`, etc.), and exposes intent methods (`startRecording()`, `playAll()`, `stopAllPlayback()`).

Three patterns worth noting:

1. **Combine debounced persistence**:
   ```swift
   saveDebounce = $recordings
       .dropFirst()
       .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
       .sink { [store] recordings in store.save(recordings) }
   ```
   `$recordings` is the `@Published` projection (the publisher). We drop the initial value, wait 500 ms after the last change, then call `store.save(...)`.

2. **MainActor + Task bridging**: every hotkey callback does `Task { @MainActor [weak self] in self?.method() }`. The hotkey callback isn't main-isolated, but the method we want to call is.

3. **State snapshots**: in `playAll()` we copy `let snapshot = recordings` before spawning the Task, so the Task uses a stable value even if `recordings` mutates while it's running.

**Concepts on display**: `ObservableObject`, `@Published`, Combine sinks (`AnyCancellable`), `Task @MainActor [weak self]` pattern, value-type snapshots.

### `Views/`

All SwiftUI. Each view is a struct with a `body: some View`. Read them in this order:

1. **`ContentView.swift`** — top-level layout. A `VStack` (vertical stack) containing the custom toolbar, a permission banner (if needed), then an `HStack` (horizontal stack) of sidebar + detail. No `NavigationSplitView` because that triggered a bug on macOS 14+ when the sidebar collapsed.
2. **`ToolbarView.swift`** — the "New / Record / Play All" buttons with the "now playing" indicator.
3. **`RecordingListView.swift`** — the sidebar `List` with `.onMove` for drag-to-reorder. Embeds `SpecialClickerView` at the bottom.
4. **`RecordingDetailView.swift`** — the detail pane: name, interval, enabled toggle, and a `Table` of recorded events.
5. **`SpecialClickerView.swift`** — the Follow Cursor Clicker section: enabled toggle, rate slider, button picker, description.

You'll see one pattern over and over: `Binding(get: { ... }, set: { ... })`. This is a custom two-way binding into `AppState` — it reads from the current `recording` value and, on write, calls `state.update(copy)` with a modified struct.

**Concepts on display**: SwiftUI's declarative model, `HStack`/`VStack`/`ZStack`, `@EnvironmentObject`, custom `Binding`, `.onMove`/`.onDelete` modifiers.

---

## 5. Making changes confidently

Some patterns to keep in mind when you want to extend the app:

### Adding a new piece of state

If it should drive UI, put it on `AppState` as `@Published`. SwiftUI will re-render automatically. If it should persist, add it to `Store.swift` (for recordings) or use `UserDefaults` (for small configs, like `SpecialClicker` does).

### Adding a new playback mode

The Scheduler already knows how to coordinate priority-based playback. To add a new kind of "thing that plays", spawn a new driver `Task` from the scheduler, give it a priority, and have it `await acquire(...)` / `await release()` like the existing macro and special-clicker drivers.

### Touching UI from a background context

You can't. Always wrap UI-touching code in `Task { @MainActor in ... }` or call a `@MainActor` method via `await`.

### Posting input events

Always go through `InputSource.marked` (defined at the top of `Player.swift`). This stamps the event with our marker so the user-activity tap doesn't mistake it for the user moving the mouse.

### Adding a new file

Just drop it under `Sources/tinyClicker/` or `Sources/tinyClicker/Views/`. Swift Package Manager picks up every `.swift` file under the target's path automatically. No need to register it anywhere.

### Building and running

```bash
make            # build  ->  build/tinyClicker.app
make run        # build and launch
```

Each `make` does `tccutil reset Accessibility com.yong.tinyClicker` first so the previous build's Accessibility grant doesn't haunt the new binary. After launch, click Open Settings, toggle the new entry on, click Relaunch.

### Where to learn more Swift

- **The Swift Book** — Apple's official tour: <https://docs.swift.org/swift-book/>
- **SwiftUI tutorials** — Apple's interactive course: <https://developer.apple.com/tutorials/swiftui>
- **Hacking with Swift** — Paul Hudson's free book and 100-day course is the most popular self-taught path: <https://www.hackingwithswift.com/>
- **WWDC sessions** — once you know the basics, Apple's annual WWDC has deep dives on Combine, async/await, SwiftUI, and CoreGraphics that are worth your time.

Don't try to memorize the standard library. Use Xcode's autocomplete and the Swift book as a reference. You'll absorb the idioms by reading code, which — having gotten this far — is exactly what you've just done.
