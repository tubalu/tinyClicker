import SwiftUI

struct RecordingDetailView: View {
    @EnvironmentObject var state: AppState
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: Binding(
                    get: { recording.name },
                    set: { newValue in
                        var copy = recording
                        copy.name = newValue
                        state.update(copy)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .disabled(state.isRecording || state.isPlayingAll)
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Interval")
                    TextField("", value: Binding(
                        get: { recording.intervalSeconds },
                        set: { newValue in
                            var copy = recording
                            copy.intervalSeconds = max(0, newValue)
                            state.update(copy)
                        }
                    ), format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .disabled(state.isPlayingAll)
                    Text("s")
                }

                Toggle("Enabled", isOn: Binding(
                    get: { recording.enabled },
                    set: { newValue in
                        var copy = recording
                        copy.enabled = newValue
                        state.update(copy)
                    }
                ))
                .disabled(state.isPlayingAll)

                Spacer()

                Text("\(recording.events.count) events · \(String(format: "%.2fs duration", recording.duration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            if recording.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No events recorded yet.")
                        .foregroundColor(.secondary)
                    Text("Press Record in the toolbar to capture mouse + key input.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EventTable(recording: recording)
            }
        }
        .padding(12)
    }
}

/// Inline-editable table of recorded events. Each cell edit funnels through
/// `state.update(_:)` — the same debounced-autosave path used by the name and
/// interval fields above — so edits persist automatically.
struct EventTable: View {
    @EnvironmentObject var state: AppState
    let recording: Recording

    /// Editing is locked while capturing or running so we never mutate a
    /// recording that the recorder/scheduler is actively touching.
    private var isEditable: Bool { !state.isRecording && !state.isPlayingAll }

    var body: some View {
        Table(recording.events) {
            TableColumn("Time") { ev in
                TextField("", value: binding(for: ev).timestamp,
                          format: .number.precision(.fractionLength(0...3)))
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEditable)
            }
            .width(min: 70, ideal: 80, max: 110)

            TableColumn("Kind") { ev in
                Text(ev.kind.rawValue)
                    .font(.caption)
            }
            .width(min: 80, ideal: 90, max: 110)

            TableColumn("Detail") { ev in
                EventDetailEditor(event: binding(for: ev), editable: isEditable)
            }

            TableColumn("") { ev in
                Button(role: .destructive) {
                    delete(ev)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this event")
                .disabled(!isEditable)
            }
            .width(28)
        }
    }

    /// A write-through binding for a single event, keyed by stable id so it
    /// survives re-renders and reorders.
    private func binding(for event: RecordedEvent) -> Binding<RecordedEvent> {
        Binding(
            get: { recording.events.first { $0.id == event.id } ?? event },
            set: { newValue in
                guard let idx = recording.events.firstIndex(where: { $0.id == event.id }) else { return }
                var copy = recording
                copy.events[idx] = newValue
                state.update(copy)
            }
        )
    }

    private func delete(_ event: RecordedEvent) {
        var copy = recording
        copy.events.removeAll { $0.id == event.id }
        state.update(copy)
    }
}

/// Renders the editable detail of one event: coordinates + button for mouse
/// events, keyCode for key events.
private struct EventDetailEditor: View {
    @Binding var event: RecordedEvent
    let editable: Bool

    var body: some View {
        Group {
            switch event.kind {
            case .mouseDown, .mouseUp:
                HStack(spacing: 4) {
                    Text("btn")
                    TextField("", value: buttonBinding, format: .number)
                        .frame(width: 32)
                    Text("@ (")
                    TextField("", value: xBinding, format: .number.precision(.fractionLength(0)))
                        .frame(width: 52)
                    Text(",")
                    TextField("", value: yBinding, format: .number.precision(.fractionLength(0)))
                        .frame(width: 52)
                    Text(")")
                }
            case .keyDown, .keyUp:
                HStack(spacing: 4) {
                    Text("keyCode")
                    TextField("", value: keyCodeBinding, format: .number)
                        .frame(width: 56)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .disabled(!editable)
    }

    private var xBinding: Binding<Double> {
        Binding(
            get: { Double(event.position?.x ?? 0) },
            set: { event.position = CGPoint(x: $0, y: Double(event.position?.y ?? 0)) }
        )
    }

    private var yBinding: Binding<Double> {
        Binding(
            get: { Double(event.position?.y ?? 0) },
            set: { event.position = CGPoint(x: Double(event.position?.x ?? 0), y: $0) }
        )
    }

    private var buttonBinding: Binding<Int> {
        Binding(
            get: { event.button ?? 0 },
            set: { event.button = max(0, $0) }
        )
    }

    private var keyCodeBinding: Binding<Int> {
        Binding(
            get: { Int(event.keyCode ?? 0) },
            set: { event.keyCode = UInt16(max(0, min(Int(UInt16.max), $0))) }
        )
    }
}
