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
                EventTable(events: recording.events)
            }
        }
        .padding(12)
    }
}

struct EventTable: View {
    let events: [RecordedEvent]

    var body: some View {
        Table(events) {
            TableColumn("Time") { ev in
                Text(String(format: "%.3fs", ev.timestamp))
                    .font(.system(.caption, design: .monospaced))
            }
            .width(min: 70, ideal: 80, max: 100)

            TableColumn("Kind") { ev in
                Text(ev.kind.rawValue)
                    .font(.caption)
            }
            .width(min: 80, ideal: 90, max: 110)

            TableColumn("Detail") { ev in
                Text(detail(for: ev))
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private func detail(for event: RecordedEvent) -> String {
        switch event.kind {
        case .mouseDown, .mouseUp:
            let x = event.position.map { String(format: "%.0f", $0.x) } ?? "?"
            let y = event.position.map { String(format: "%.0f", $0.y) } ?? "?"
            let btn = event.button.map(buttonName(_:)) ?? "?"
            return "\(btn) @ (\(x), \(y))"
        case .keyDown, .keyUp:
            let code = event.keyCode.map(String.init) ?? "?"
            return "keyCode \(code)"
        }
    }

    private func buttonName(_ idx: Int) -> String {
        switch idx {
        case 0: return "left"
        case 1: return "right"
        default: return "btn\(idx)"
        }
    }
}
