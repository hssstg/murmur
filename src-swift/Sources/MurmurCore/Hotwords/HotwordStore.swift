import Foundation

public class HotwordStore: ObservableObject {
    @Published public private(set) var words: [String] = []

    private let filePath: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("com.murmurtype")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        filePath = dir.appendingPathComponent("hotwords.json")
        load()
    }

    public func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !words.contains(w) else { return }
        words.append(w)
        words.sort()
        save()
    }

    public func remove(at offsets: IndexSet) {
        for index in offsets.reversed() {
            words.remove(at: index)
        }
        save()
    }

    public func remove(_ word: String) {
        words.removeAll { $0 == word }
        save()
    }

    public func replaceAll(_ newWords: [String]) {
        words = newWords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        words.sort()
        save()
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let loaded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        words = loaded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(words) else { return }
        try? data.write(to: filePath, options: .atomic)
    }
}
