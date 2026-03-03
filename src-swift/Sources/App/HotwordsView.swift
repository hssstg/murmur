import SwiftUI
import MurmurCore

// MARK: - Wrap layout

private struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0

        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                y += rowH + vSpacing; x = 0; rowH = 0
            }
            x += sz.width + hSpacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0

        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                y += rowH + vSpacing; x = bounds.minX; rowH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + hSpacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - HotwordsView

struct HotwordsView: View {
    @ObservedObject var store: HotwordStore
    @ObservedObject var historyStore: HistoryStore
    let config: AppConfig

    @State private var newWord      = ""
    @State private var syncStatus   = ""
    @State private var syncing      = false
    @State private var fetching     = false
    @State private var extracting   = false
    @State private var suggestions: [String] = []
    @State private var extractError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Add word bar
            HStack {
                TextField("添加热词...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                Button("添加", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            Divider()

            // Tag cloud
            if fetching {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("从火山引擎加载中...").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else if store.words.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "textformat.abc")
                            .font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("暂无热词").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    FlowLayout(hSpacing: 8, vSpacing: 8) {
                        ForEach(store.words, id: \.self) { word in
                            WordChip(word: word) { store.remove(word) }
                        }
                    }
                    .padding()
                }
            }

            // AI suggestions
            if !suggestions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AI 建议热词")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("全部添加") {
                            for w in suggestions { store.add(w) }
                            suggestions = []
                        }
                        .font(.caption)
                    }
                    FlowLayout(hSpacing: 8, vSpacing: 8) {
                        ForEach(suggestions, id: \.self) { word in
                            SuggestionChip(word: word) {
                                store.add(word)
                                suggestions.removeAll { $0 == word }
                            } onDismiss: {
                                suggestions.removeAll { $0 == word }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            // Footer
            HStack {
                Text("\(store.words.count) 个热词")
                    .font(.caption).foregroundStyle(.secondary)
                if !extractError.isEmpty {
                    Text(extractError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Button {
                    Task { await extractHotwords() }
                } label: {
                    if extracting { ProgressView().controlSize(.small) }
                    else { Label("AI 提取热词", systemImage: "wand.and.stars") }
                }
                .disabled(extracting || config.llm_base_url.isEmpty)
                .help(config.llm_base_url.isEmpty ? "请先在设置中配置大模型" : "根据历史修正记录 AI 提取热词")
                Spacer()
                if !syncStatus.isEmpty {
                    Text(syncStatus)
                        .font(.caption)
                        .foregroundStyle(syncStatus.hasPrefix("失败") || syncStatus.hasPrefix("加载失败") ? .red : .green)
                        .lineLimit(1)
                }
                Button {
                    Task { await syncToVolcengine() }
                } label: {
                    if syncing { ProgressView().controlSize(.small) }
                    else { Label("同步到火山引擎", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(syncing || store.words.isEmpty || config.hotwords_ak.isEmpty || config.hotwords_sk.isEmpty)
                .help(config.hotwords_ak.isEmpty ? "请先在设置中填写热词 AK/SK" : "上传词表到火山引擎自学习平台")
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 320)
        .onAppear {
            guard !config.hotwords_ak.isEmpty, store.words.isEmpty else { return }
            Task { await fetchFromVolcengine() }
        }
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        store.add(w)
        newWord = ""
    }

    private func syncToVolcengine() async {
        syncing = true; syncStatus = ""
        defer { syncing = false }
        do {
            syncStatus = try await VolcHotwordsClient.sync(
                ak: config.hotwords_ak, sk: config.hotwords_sk,
                appId: config.api_app_id, tableName: config.asr_vocabulary,
                words: store.words)
        } catch {
            syncStatus = "失败：\(error.localizedDescription)"
        }
    }

    private func fetchFromVolcengine() async {
        fetching = true; syncStatus = ""
        defer { fetching = false }
        do {
            guard let words = try await VolcHotwordsClient.fetchWords(
                ak: config.hotwords_ak, sk: config.hotwords_sk,
                appId: config.api_app_id, tableName: config.asr_vocabulary)
            else { syncStatus = "词表不存在（未同步过）"; return }
            store.replaceAll(words)
            syncStatus = "已从火山加载 \(words.count) 个词"
        } catch {
            syncStatus = "加载失败：\(error.localizedDescription)"
        }
    }

    private func extractHotwords() async {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recentTexts = historyStore.entries
            .filter { $0.date >= sevenDaysAgo }
            .map { $0.effectiveText }
        let corrections = historyStore.entries.compactMap { e -> (original: String, edited: String)? in
            guard let edited = e.edited else { return nil }
            return (e.text, edited)
        }
        guard !recentTexts.isEmpty || !corrections.isEmpty else {
            extractError = "暂无历史记录"
            return
        }
        extracting = true; extractError = ""
        defer { extracting = false }
        do {
            let words = try await LLMClient.extractHotwords(
                corrections: corrections,
                recentTexts: recentTexts,
                existing: store.words,
                config: config
            )
            suggestions = words
            if words.isEmpty { extractError = "未发现新热词" }
        } catch {
            extractError = "提取失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - SuggestionChip

private struct SuggestionChip: View {
    let word: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(word).font(.callout)
            Button { onAdd() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("添加到热词库")
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("忽略")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
    }
}

// MARK: - WordChip

private struct WordChip: View {
    let word: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(word)
                .font(.callout)
            Button { onDelete() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5))
    }
}
