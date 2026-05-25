import SwiftUI

/// A custom header bar shown via `.safeAreaInset(edge: .top)` instead of
/// SwiftUI's `.toolbar` modifier. Going through `.toolbar` on macOS 14/15
/// can crash during NavigationSplitView sidebar collapse — pure SwiftUI
/// layout via safeAreaInset bypasses the AppKit toolbar bridge entirely.
struct ToolbarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var permissions: PermissionMonitor

    var body: some View {
        HStack(spacing: 12) {
            Button {
                state.addRecording()
            } label: {
                Label("New", systemImage: "plus")
            }
            .disabled(state.isRecording || state.isPlayingAll)

            Divider().frame(height: 18)

            if state.isRecording {
                Button(role: .destructive) {
                    state.stopRecording()
                } label: {
                    Label("Stop Recording (F9)", systemImage: "stop.circle.fill")
                        .foregroundColor(.red)
                }
            } else {
                Button {
                    state.startRecording()
                } label: {
                    Label("Record (F9)", systemImage: "record.circle")
                }
                .disabled(state.selectedId == nil || state.isPlayingAll || !permissions.isTrusted)
            }

            Divider().frame(height: 18)

            if state.isPlayingAll {
                Button(role: .destructive) {
                    state.stopAllPlayback()
                } label: {
                    Label("Stop All (F10)", systemImage: "stop.fill")
                        .foregroundColor(.red)
                }
            } else {
                Button {
                    state.playAll()
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                .disabled(
                    state.isRecording
                    || !permissions.isTrusted
                    || (
                        !state.recordings.contains(where: { $0.enabled && !$0.events.isEmpty })
                        && !state.specialClicker.enabled
                    )
                )
            }

            Spacer()

            if let id = state.nowPlayingId,
               let rec = state.recordings.first(where: { $0.id == id }) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Now playing: \(rec.name)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
