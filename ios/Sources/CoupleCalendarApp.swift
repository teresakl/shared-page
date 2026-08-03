import SwiftUI

// ============================================================
// CoupleCalendarApp.swift — 入口。月视图 ⇄ 日视图切换。
// 视图与所有定稿数值来自设计包，未作改动。
// 启动月份/日号现在从真实日期来，-month 2026-08 和 -day 15 两个启动参数可以指定。
// ============================================================

@main
struct CoupleCalendarApp: App {
    /// APNs 的系统回调（token、前台展示、点通知）都落在这个 delegate 上
    @UIApplicationDelegateAdaptor(CalendarAppDelegate.self) private var pushDelegate
    init() {
        FontCheck.run()
        BakeProbe.runIfAsked()
    }
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CalendarStore = {
        let s = CalendarStore()
        s.month = RootView.launchMonth
        return s
    }()
    @State private var selectedDay: Int = RootView.launchDay
    @State private var showingDay = ProcessInfo.processInfo.arguments.contains("-openDay")

    /// 翻页：日视图从右边推进来，月视图往后退半步淡掉；回来时反着走
    private static let flip = Animation.spring(response: 0.36, dampingFraction: 0.9)

    /// 启动参数注入：-month 2026-08 直接落在那个月，不给就是此时此刻这个月
    static var launchMonth: CalMonth {
        UserDefaults.standard.string(forKey: "month").flatMap(CalMonth.init(key:)) ?? .current
    }
    /// -day 17 指定当月第几天；不给或越界就落到今天，今天不在这个月里就落 1 号
    static var launchDay: Int {
        let m = launchMonth
        let d = UserDefaults.standard.integer(forKey: "day")
        return (1...m.daysInMonth).contains(d) ? d : (m.todayInMonth ?? 1)
    }

    var body: some View {
        ZStack {
            if showingDay {
                DayView(day: $selectedDay) {
                    withAnimation(Self.flip) { showingDay = false }
                    // 退回月视图 = 这一轮看完了，动过的那几页渲染上传给 AI 侧（阶段五）
                    PageSync.shared.flush(store: store)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            } else {
                MonthView(selectedDay: $selectedDay) { _ in
                    withAnimation(Self.flip) { showingDay = true }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(0)
            }
        }
        .environment(store)
        // 拉这个月的事件。出现的时候跑一次（app 起来），月份换了再跑一次（翻月），
        // 旧的那次自己会被取消。挂在 RootView 而不是 MonthView 上是因为
        // MonthView 切去日视图时会被销毁，挂那儿的话每次退回来都要重拉一遍、副标题跟着闪
        .task(id: store.month) { store.load(store.month) }
        // 贴纸/照片/emoji 的增删挪都从 PlacedStore 走，它改哪天就把哪天记成动过。
        // 这个口子是 PlacedItem.swift 留给网关同步用的，阶段五先由页面渲染占着
        // 点桌面小组件进来:ourcalendar://day/2026-08-03 → 直接翻到那一页
        .onOpenURL { url in
            guard url.scheme == "ourcalendar", url.host == "day",
                  let key = url.pathComponents.dropFirst().first else { return }
            PushDayRouter.shared.open(dayKey: key)
        }
        .onAppear {
            PlacedStore.shared.didMutate = { PageSync.shared.markDirty($0) }
            PageProbe.runIfAsked(store: store)
            WidgetProbe.runIfAsked()
            // 通知授权 + token 登记（模拟器里整个跳过）
            CalendarPushManager.shared.startRegistration()
            // 点了那条通知→ 直接翻到那一天。
            // @State 不能塞进逃逸闭包，抓 binding 进去
            let sd = $selectedDay, sh = $showingDay
            PushDayRouter.shared.onOpenDay = { m, d in
                store.month = m
                sd.wrappedValue = min(d, m.daysInMonth)
                withAnimation(Self.flip) { sh.wrappedValue = true }
            }
        }
        // 拖动位置是攒 0.35s 再写盘的，退到后台前补一次，免得刚挪完就被杀掉；
        // 顺手把动过的那几页渲染上传（阶段五：切后台也是一个上传时机）
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushPlaced()
                PageSync.shared.flush(store: store)
            } else {
                store.load(store.month)             // 回到前台跟服务端对一遍
                CalendarPushManager.shared.refreshRegistrationIfNeeded()
            }
        }
        // 翻月之后日号可能落空（7/31 翻到只有 30 天的 9 月），夹一次
        .onChange(of: store.month) { _, m in
            if selectedDay > m.daysInMonth { selectedDay = m.daysInMonth }
        }
    }
}

// 字体没装齐时手写感会整个消失，启动时在控制台点名一次
enum FontCheck {
    static func run() {
        #if DEBUG
        let want = ["LXGWWenKai-Regular",
                    "InstrumentSerif-Regular", "SpaceMono-Regular", "SpaceMono-Bold", "Caveat-Medium"]
        let have = Set(UIFont.familyNames.flatMap { UIFont.fontNames(forFamilyName: $0) })
        for n in want {
            print(have.contains(n) ? "[font] ok   \(n)" : "[font] MISSING \(n)")
        }
        #endif
    }
}

#Preview("月视图") {
    MonthView(selectedDay: .constant(17)) { _ in }
        .environment(CalendarStore())
}

#Preview("日视图") {
    DayView(day: .constant(17)) {}
        .environment(CalendarStore())
}


// 调试探针：-bakeTest 时拿 bundle 里的样张跑一遍完整烤制，结果丢进 Documents，
// 用 `xcrun simctl get_app_container booted com.example.couplecalendar data` 取出来看。
enum BakeProbe {
    static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-bakeTest") else { return }
        Task {
            guard let url = Bundle.main.url(forResource: "baketest", withExtension: "jpg"),
                  let data = try? Data(contentsOf: url),
                  let img = UIImage(data: data) else {
                print("[bake] 样张没找到"); return
            }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            do {
                if let l = try await StickerBaker.liftSubject(img) {
                    try? l.pngData()?.write(to: docs.appendingPathComponent("probe-1-subject.png"))
                    print("[bake] 抠图 ok \(Int(l.size.width))x\(Int(l.size.height))")
                } else {
                    print("[bake] 抠图返回 nil —— 没识别出实例")
                }
            } catch {
                print("[bake] 抠图抛错: \(error)")
            }
            if let baked = try? await StickerBaker.bake(img) {
                try? baked.pngData()?.write(to: docs.appendingPathComponent("probe-2-baked.png"))
                print("[bake] 成品 ok \(Int(baked.size.width))x\(Int(baked.size.height))")
            } else {
                print("[bake] 烤制失败")
            }
        }
    }
}
