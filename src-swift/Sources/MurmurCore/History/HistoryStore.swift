import Foundation

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date

    public init(text: String) {
        self.id   = UUID()
        self.text = text
        self.date = Date()
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

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = loaded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: filePath, options: .atomic)
    }
}
