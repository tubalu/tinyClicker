import SwiftUI

struct SpecialClickerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var permissions: PermissionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Follow Cursor Clicker")
                    .font(.subheadline.bold())
                Spacer()
                Text("lowest priority")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Toggle("Enabled", isOn: Binding(
                get: { state.specialClicker.enabled },
                set: { state.specialClicker.enabled = $0 }
            ))
            .disabled(!permissions.isTrusted)

            HStack {
                Text("Rate")
                    .frame(width: 50, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { state.specialClicker.clicksPerSecond },
                        set: { state.specialClicker.clicksPerSecond = $0 }
                    ),
                    in: SpecialClicker.minRate...SpecialClicker.maxRate,
                    step: 0.5
                )
                Text(String(format: "%.1f/s", state.specialClicker.clampedRate))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }

            HStack {
                Text("Button")
                    .frame(width: 50, alignment: .leading)
                Picker("", selection: Binding(
                    get: { state.specialClicker.button },
                    set: { state.specialClicker.button = $0 }
                )) {
                    ForEach(ClickButton.allCases) { button in
                        Text(button.displayName).tag(button)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Text("When armed, runs alongside Play All — clicks at the current cursor position, yielding while any recording is playing and firing during their interval gaps. Does nothing until Play All is started.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            Text("Safety Auto-Pauses")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            Toggle("Pause on Mouse Motion", isOn: $state.pauseOnMouseMove)
                .font(.caption)
            Toggle("Pause when Cursor Over Window", isOn: $state.pauseOnOwnWindow)
                .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.08))
        )
        .padding(8)
    }
}
