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

    var filtered: [HistoryEntry] {
        guard let start = filter.startDate() else { return store.entries }
        return store.entries.filter { $0.date >= start }
    }

    var totalChars: Int { filtered.reduce(0) { $0 + $1.text.count } }

    // Per-day counts for the most active day
    var mostActiveDay: (String, Int)? {
        guard !filtered.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        var counts: [String: Int] = [:]
        for e in filtered {
            let key = fmt.string(from: e.date)
            counts[key, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Filter bar
            HStack {
                Picker("", selection: $filter) {
                    ForEach(TimeFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer()

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("清空历史")
                .confirmationDialog("清空所有历史记录？", isPresented: $showClearConfirm) {
                    Button("清空", role: .destructive) { store.clear() }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            // Stats bar
            HStack(spacing: 20) {
                statItem(icon: "text.bubble", value: "\(filtered.count)", label: "条记录")
                statItem(icon: "character.cursor.ibeam", value: "\(totalChars)", label: "字")
                if let (day, count) = mostActiveDay {
                    statItem(icon: "flame", value: day, label: "最多 \(count) 条")
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            if filtered.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("暂无记录")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Text(entry.date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
