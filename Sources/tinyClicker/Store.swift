import Foundation

struct Store {
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (appSupport ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("tinyClicker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("recordings.json")
    }

    func load() -> [Recording] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([Recording].self, from: data)) ?? []
    }

    func save(_ recordings: [Recording]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recordings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
