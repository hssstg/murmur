import SwiftUI
import MurmurCore

struct HotwordsView: View {
    @ObservedObject var store: HotwordStore
    let config: AppConfig

    @State private var newWord    = ""
    @State private var syncStatus = ""
    @State private var syncing    = false

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

            // Word list
            if store.words.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "textformat.abc")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("暂无热词")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                List {
                    ForEach(store.words, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                store.remove(word)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { store.remove(at: $0) }
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer: word count + sync
            HStack {
                Text("\(store.words.count) 个热词")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !syncStatus.isEmpty {
                    Text(syncStatus)
                        .font(.caption)
                        .foregroundStyle(syncStatus.hasPrefix("失败") ? .red : .green)
                }

                Button {
                    Task { await syncToVolcengine() }
                } label: {
                    if syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("同步到火山引擎", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(syncing || store.words.isEmpty || config.hotwords_ak.isEmpty || config.hotwords_sk.isEmpty)
                .help(config.hotwords_ak.isEmpty ? "请先在设置中填写热词 AK/SK" : "上传词表到火山引擎自学习平台")
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 360)
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        store.add(w)
        newWord = ""
    }

    private func syncToVolcengine() async {
        syncing    = true
        syncStatus = ""
        defer { syncing = false }

        do {
            let msg = try await VolcHotwordsClient.sync(
                ak:        config.hotwords_ak,
                sk:        config.hotwords_sk,
                appId:     config.api_app_id,
                tableName: config.asr_vocabulary,
                words:     store.words
            )
            syncStatus = msg
        } catch {
            syncStatus = "失败：\(error.localizedDescription)"
        }
    }
}
