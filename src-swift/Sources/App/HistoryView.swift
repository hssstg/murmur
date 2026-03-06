import SwiftUI
import MurmurCore

enum TimeFilter: String, CaseIterable {
    case today  = "today"
    case week   = "week"
    case month  = "month"
    case all    = "all"

    var displayName: String {
        switch self {
        case .today: L("history.filter.today")
        case .week:  L("history.filter.week")
        case .month: L("history.filter.month")
        case .all:   L("history.filter.all")
        }
    }

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
                    ForEach(TimeFilter.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .help(Text(L("history.clear.help")))
                .confirmationDialog(Text(L("history.clear.confirm")), isPresented: $showClearConfirm) {
                    Button(L("history.clear.action"), role: .destructive) { store.clear() }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)

            // Stats
            HStack(spacing: 20) {
                statItem(icon: "text.bubble",            value: "\(filtered.count)", label: L("history.stat.entries"))
                statItem(icon: "character.cursor.ibeam", value: "\(totalChars)",     label: L("history.stat.chars"))
                if let (day, count) = mostActiveDay {
                    statItem(icon: "flame", value: day,
                             label: String(format: L("history.stat.most_active"), count))
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
                        Text(L("history.empty")).foregroundStyle(.secondary)
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
                        Text(L("history.entry.original_label"))
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
            .help(Text(L("history.entry.edit.help")))
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
            Text(L("history.editpopover.title"))
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(width: 320, height: 120)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .focused($focused)

            HStack {
                Spacer()
                Button(L("common.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save"), action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }
}
