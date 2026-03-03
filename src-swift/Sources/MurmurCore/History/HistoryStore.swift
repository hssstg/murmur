import Foundation

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let text: String       // original ASR output
    public var edited: String?    // user correction (nil = not edited)
    public let date: Date

    /// The text to use: correction if set, otherwise original
    public var effectiveText: String { edited ?? text }

    public init(text: String) {
        self.id     = UUID()
        self.text   = text
        self.edited = nil
        self.date   = Date()
    }
}

@MainActor
public class HistoryStore: ObservableObject {
    @Published public private(set) var entries: [HistoryEntry] = []

    private let filePath: URL
    private let maxEntries = 1000

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("com.locke.murmur")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        filePath = dir.appendingPathComponent("history.json")
        load()
    }

    public func add(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(HistoryEntry(text: trimmed), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    public func edit(id: UUID, newText: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear the correction if it's blank or identical to the original
        entries[idx].edited = (trimmed.isEmpty || trimmed == entries[idx].text) ? nil : trimmed
        save()
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: filePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([HistoryEntry].self, from: data) else { return }
        entries = loaded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        if (try? data.write(to: filePath, options: .atomic)) == nil {
            fputs("[murmur] HistoryStore: failed to save history\n", stderr)
        }
    }
}
