import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var permissions: PermissionMonitor

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            Divider()
            if !permissions.isTrusted {
                PermissionBanner()
                Divider()
            }
            HStack(spacing: 0) {
                RecordingListView()
                    .frame(width: 280)
                    .background(Color(NSColor.controlBackgroundColor))
                Divider()
                DetailPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct DetailPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let id = state.selectedId,
           let recording = state.recordings.first(where: { $0.id == id }) {
            RecordingDetailView(recording: recording)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("Select or create a recording")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var permissions: PermissionMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.subheadline.bold())
                Text("Step 1: Click Open Settings, toggle tinyClicker ON.   Step 2: Click Relaunch.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("macOS only checks Accessibility at process start. A running app cannot see a permission granted after launch — and every rebuild changes the binary's identity, so the previous grant no longer matches. If toggling ON + Relaunch still leaves this banner, the TCC entry is stale from a prior build: run `make permission-reset` in the project, then grant fresh.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Open Settings") { permissions.openSystemSettings() }
                Button("Relaunch") { permissions.relaunchApp() }
                    .keyboardShortcut("r", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                Button("Quit") { permissions.quitApp() }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
    }
}
