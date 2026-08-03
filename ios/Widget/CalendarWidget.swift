import SwiftUI
import WidgetKit

// ============================================================
// CalendarWidget.swift — 小组件本体(只编进 widget target)。
//
// 中号一种规格:今天的日程 + 便签(视图在 WidgetShared.swift)。
// 刷新交给系统:每次醒来重新拉一次网关,约二十分钟一班;
// 数据纯在线不落盘。点卡片 → ourcalendar://day/<今天> → app 直接翻到那页。
// ============================================================

struct CalDayEntry: TimelineEntry {
    let date: Date
    let snap: WDaySnapshot
}

struct CalDayProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalDayEntry {
        CalDayEntry(date: Date(), snap: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (CalDayEntry) -> Void) {
        // 小组件相册里的预览:不打网络,给样板
        if context.isPreview {
            completion(CalDayEntry(date: Date(), snap: Self.sample))
            return
        }
        Task { completion(CalDayEntry(date: Date(), snap: await WidgetFetch.today())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalDayEntry>) -> Void) {
        Task {
            let snap = await WidgetFetch.today()
            let next = Calendar.current.date(byAdding: .minute, value: 20, to: Date())
                ?? Date().addingTimeInterval(1200)
            completion(Timeline(entries: [CalDayEntry(date: Date(), snap: snap)],
                                policy: .after(next)))
        }
    }

    /// 小组件挑选页里的演示数据(不发网络)
    static var sample: WDaySnapshot {
        var s = WDaySnapshot()
        s.items = [
            WItem(id: "1", isMaster: false, isSystem: false,
                  timeLabel: "14:00", text: "拿快递"),
            WItem(id: "2", isMaster: true, isSystem: false,
                  timeLabel: "20:00", text: "一起看电影"),
        ]
        s.latestNote = WLatestNote(isMaster: true, body: "记得带伞。", stamp: "08-02 09:12")
        return s
    }
}

struct CalendarMediumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CalendarDayWidget", provider: CalDayProvider()) { entry in
            WidgetMediumView(snap: entry.snap)
                .widgetURL(deepLink(for: entry))
                .containerBackground(Color.white, for: .widget)
        }
        .configurationDisplayName("今天")
        .description("这一天的安排和便签。")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }

    private func deepLink(for entry: CalDayEntry) -> URL? {
        let f = DateFormatter()
        f.timeZone = WDaySnapshot.zone
        f.dateFormat = "yyyy-MM-dd"
        return URL(string: "ourcalendar://day/\(f.string(from: entry.date))")
    }
}

@main
struct CalendarWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalendarMediumWidget()
    }
}
