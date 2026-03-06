import SwiftUI
import Charts
import MurmurCore

struct StatsView: View {
    @ObservedObject var store: HistoryStore

    // MARK: - Computed data

    private var allEntries: [HistoryEntry] { store.entries }

    private var totalSessions: Int { allEntries.count }
    private var totalChars: Int    { allEntries.reduce(0) { $0 + $1.effectiveText.count } }
    private var editedCount: Int   { allEntries.filter { $0.edited != nil }.count }
    private var editRate: Double   { totalSessions == 0 ? 0 : Double(editedCount) / Double(totalSessions) }
    private var avgChars: Double   { totalSessions == 0 ? 0 : Double(totalChars) / Double(totalSessions) }

    private var daysUsed: Int {
        let cal = Calendar.current
        let days = Set(allEntries.map { cal.startOfDay(for: $0.date) })
        return days.count
    }

    /// Last 30 days, count per day
    private var dailyData: [(date: Date, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(grouping: allEntries) { cal.startOfDay(for: $0.date) }
        return (0..<30).reversed().map { offset -> (Date, Int) in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            return (day, byDay[day]?.count ?? 0)
        }
    }

    /// 24 hours, count per hour
    private var hourlyData: [(hour: Int, count: Int)] {
        let cal = Calendar.current
        var counts = Array(repeating: 0, count: 24)
        for e in allEntries { counts[cal.component(.hour, from: e.date)] += 1 }
        return counts.enumerated().map { ($0.offset, $0.element) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Overview cards ──────────────────────────────────────────
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 12) {
                    StatCard(icon: "mic.fill",               value: "\(totalSessions)", label: L("stats.total_sessions"))
                    StatCard(icon: "character.cursor.ibeam", value: "\(totalChars)",    label: L("stats.total_chars"))
                    StatCard(icon: "calendar",               value: "\(daysUsed)",      label: L("stats.days_used"))
                    StatCard(icon: "pencil.and.scribble",
                             value: String(format: "%.0f%%", editRate * 100),           label: L("stats.edit_rate"))
                }

                Divider()

                // ── Daily usage (last 30 days) ──────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(L("stats.daily.title"))
                    if totalSessions == 0 {
                        emptyHint()
                    } else {
                        Chart(dailyData, id: \.date) { item in
                            AreaMark(
                                x: .value(L("stats.chart.date_axis"), item.date, unit: .day),
                                y: .value(L("stats.chart.count_axis"), item.count)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.35),
                                             Color.accentColor.opacity(0.0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.catmullRom)

                            LineMark(
                                x: .value(L("stats.chart.date_axis"), item.date, unit: .day),
                                y: .value(L("stats.chart.count_axis"), item.count)
                            )
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.catmullRom)
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                                AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                                    .font(.caption2)
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.3))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { _ in
                                AxisValueLabel().font(.caption2)
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                            }
                        }
                        .chartYScale(domain: 0...max(1, dailyData.map(\.count).max() ?? 1))
                        .frame(height: 110)
                    }
                }

                Divider()

                // ── Hourly distribution ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(L("stats.hourly.title"))
                    if totalSessions == 0 {
                        emptyHint()
                    } else {
                        Chart(hourlyData, id: \.hour) { item in
                            AreaMark(
                                x: .value(L("stats.chart.hour_axis"), item.hour),
                                y: .value(L("stats.chart.count_axis"), item.count)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.35),
                                             Color.accentColor.opacity(0.0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .interpolationMethod(.catmullRom)

                            LineMark(
                                x: .value(L("stats.chart.hour_axis"), item.hour),
                                y: .value(L("stats.chart.count_axis"), item.count)
                            )
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.catmullRom)
                        }
                        .chartXAxis {
                            AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                                AxisValueLabel {
                                    if let h = v.as(Int.self) {
                                        Text(String(format: L("stats.chart.hour_label"), h))
                                            .font(.caption2)
                                    }
                                }
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { _ in
                                AxisValueLabel().font(.caption2)
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                            }
                        }
                        .chartYScale(domain: 0...max(1, hourlyData.map(\.count).max() ?? 1))
                        .frame(height: 90)
                    }
                }

                Divider()

                // ── Recognition quality ─────────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(L("stats.quality.title"))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                        GridItem(.flexible())], spacing: 12) {
                        StatCard(icon: "checkmark.circle",
                                 value: "\(totalSessions - editedCount)", label: L("stats.quality.direct"))
                        StatCard(icon: "pencil.circle",
                                 value: "\(editedCount)",                 label: L("stats.quality.edited"))
                        StatCard(icon: "textformat.size",
                                 value: String(format: "%.1f", avgChars), label: L("stats.quality.avg_chars"))
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 540, minHeight: 520)
    }

    @ViewBuilder
    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func emptyHint() -> some View {
        Text(L("common.no_data"))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 60)
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
