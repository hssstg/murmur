import SwiftUI
import MurmurCore

enum TimeFilter: String, CaseIterable {
    case today  = "今天"
    case week   = "7天"
    case month  = "30天"
    case all    = "全部"

    func startDate() -> Date? {
        let cal = Calendar.current
        switch self {
        case .today: return cal.startOfDay(for: Date())
        case .week:  return cal.date(byAdding: .day, value: -7,  to: Date())
        case .month: return cal.date(byAdding: .day, value: -30, to: Date())
        case .all:   return nil
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var filter: TimeFilter = .all
    @State private var showClearConfirm = false
    @State private var editingText = ""

    var filtered: [HistoryEntry] {
        guard let start = filter.startDate() else { return store.entries }
        return store.entries.filter { $0.date >= start }
    }

    var totalChars: Int { filtered.reduce(0) { $0 + $1.effectiveText.count } }

    var mostActiveDay: (String, Int)? {
        guard !filtered.isEmpty else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "MM-dd"
        var counts: [String: Int] = [:]
        for e in filtered { counts[fmt.string(from: e.date), default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Filter + clear
            HStack {
                Picker("", selection: $filter) {
                    ForEach(TimeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .help("清空历史")
                .confirmationDialog("清空所有历史记录？", isPresented: $showClearConfirm) {
                    Button("清空", role: .destructive) { store.clear() }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)

            // Stats
            HStack(spacing: 20) {
                statItem(icon: "text.bubble",            value: "\(filtered.count)", label: "条记录")
                statItem(icon: "character.cursor.ibeam", value: "\(totalChars)",     label: "字")
                if let (day, count) = mostActiveDay {
                    statItem(icon: "flame", value: day, label: "最多 \(count) 条")
                }
                Spacer()
            }
            .padding(.horizontal).padding(.bottom, 8)

            Divider()

            if filtered.isEmpty {
                Spacer()
                HStack { Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("暂无记录").foregroundStyle(.secondary)
                    }
                    Spacer() }
                Spacer()
            } else {
                List(filtered) { entry in
                    HistoryRowView(
                        entry:       entry,
                        editingText: $editingText,
                        onCommit: { store.edit(id: entry.id, newText: editingText) },
                        onCancel: {}
                    )
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }

    @ViewBuilder
    private func statItem(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

// MARK: - Row

private struct HistoryRowView: View {
    let entry: HistoryEntry
    @Binding var editingText: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @State private var showPopover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.effectiveText)
                    .textSelection(.enabled)
                    .lineLimit(4)

                if entry.edited != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("原")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                editingText = entry.effectiveText
                showPopover = true
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("修改")
            .popover(isPresented: $showPopover, arrowEdge: .trailing) {
                EditPopover(
                    text: $editingText,
                    onCommit: { onCommit(); showPopover = false },
                    onCancel: { onCancel(); showPopover = false }
                )
            }
        }
    }
}

// MARK: - EditPopover

private struct EditPopover: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑记录")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(width: 320, height: 120)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }
}
