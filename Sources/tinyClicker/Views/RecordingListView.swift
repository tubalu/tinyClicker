import SwiftUI

struct RecordingListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings")
                    .font(.subheadline.bold())
                Spacer()
                Text("priority ↓")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            List(selection: Binding(
                get: { state.selectedId },
                set: { state.selectedId = $0 }
            )) {
                ForEach(state.recordings) { recording in
                    RecordingRow(recording: recording)
                        .tag(recording.id)
                }
                .onMove { from, to in state.move(from: from, to: to) }
                .onDelete { indexSet in
                    for idx in indexSet {
                        state.deleteRecording(id: state.recordings[idx].id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SpecialClickerView()
        }
    }
}

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
                // Its own line, not tacked onto the metadata — this is the
                // thing you actually watch for.
                if let due = state.nextFireAt[recording.id] {
                    NextRunCountdown(due: due)
                }
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
