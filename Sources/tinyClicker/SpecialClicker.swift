import Foundation

enum ClickButton: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var mouseButtonIndex: Int { self == .left ? 0 : 1 }
    var displayName: String { self == .left ? "Left" : "Right" }
}

/// "Follow cursor" auto-clicker. Always clicks at the live cursor position
/// (so any cursor motion — user or another macro's playback — is followed).
/// Runs at the lowest priority: yields while any recording is in its
/// playback phase, fires freely during recordings' interval gaps.
struct SpecialClicker: Codable, Equatable {
    var enabled: Bool = false
    var clicksPerSecond: Double = 2.0
    var button: ClickButton = .left

    /// The only selectable rates (clicks/second). Max is 20.
    static let rateOptions: [Double] = [1, 2, 20]

    static let minRate: Double = rateOptions.first!
    static let maxRate: Double = rateOptions.last!

    /// Snap any stored value to the nearest allowed option so persisted
    /// or out-of-range values always resolve to a valid choice.
    var clampedRate: Double {
        Self.rateOptions.min(by: {
            abs($0 - clicksPerSecond) < abs($1 - clicksPerSecond)
        }) ?? Self.maxRate
    }

    var intervalSeconds: Double { 1.0 / clampedRate }
}

extension SpecialClicker {
    private static let defaultsKey = "tinyClicker.specialClicker"

    static func load() -> SpecialClicker {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SpecialClicker.self, from: data)
        else { return SpecialClicker() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
