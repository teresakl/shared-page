import SwiftUI
import UserNotifications

// ============================================================
// CalendarPush.swift — 「我们的日历」自己的推送（不借 我另一个 app）。
//
// 三样东西：
//   · CalendarPushManager  通知授权 + APNs 注册 + token 上报。
//                          写法整段照着 我另一个 app 的 PushNotificationManager 来，
//                          只是登记走日历自己的口（/calendar/push/register，
//                          X-Calendar-Token 鉴权）
//   · PushDayRouter        点通知 → 跳到那一天。payload 里带 calendar_day，
//                          RootView 起来之前点的先攒着，起来就放行
//   · CalendarAppDelegate  系统回调的落点（token 回调、前台展示、点击）
//
// 环境：Debug 直装报 sandbox（服务端没配 sandbox 钥匙，那些 token 躺着不用），
// TestFlight 报 production —— 真正能收到通知的只有 TestFlight 装的版本。
// 模拟器整个跳过，一次注册都不试。
// ============================================================

@MainActor
final class CalendarPushManager {
    static let shared = CalendarPushManager()

    private enum Key {
        static let deviceID = "calendar.push.device_id"
        static let deviceToken = "calendar.push.device_token"
        static let lastFingerprint = "calendar.push.last_fingerprint"
        static let lastUploadAt = "calendar.push.last_upload_at"
        static let lastAttemptAt = "calendar.push.last_attempt_at"
    }

    private let defaults = UserDefaults.standard
    /// 注册成功后每 12 小时最多重报一次，失败 5 分钟内不再试 —— 跟 我另一个 app 同一个节奏
    private let successfulUploadInterval: TimeInterval = 12 * 60 * 60
    private let failedAttemptCooldown: TimeInterval = 5 * 60

    private var registrationStarted = false
    private var uploadTask: Task<Void, Never>?

    private init() {}

    /// app 起来喊一次。第一次会弹系统的通知授权框，之后静默走注册
    func startRegistration() {
        #if targetEnvironment(simulator)
        return
        #else
        guard !registrationStarted else {
            refreshRegistrationIfNeeded()
            return
        }
        registrationStarted = true
        Task { [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(
                    options: [.alert, .sound, .badge])) ?? false
                if granted { UIApplication.shared.registerForRemoteNotifications() }
                else { print("[push] 通知授权没给") }
            case .authorized, .provisional, .ephemeral:
                UIApplication.shared.registerForRemoteNotifications()
            case .denied:
                print("[push] 通知在设置里被关了")
            @unknown default:
                break
            }
        }
        #endif
    }

    /// 回到前台低频重报：restore / 重装 / 系统升级后服务器不该攥着旧 token
    func refreshRegistrationIfNeeded() {
        #if targetEnvironment(simulator)
        return
        #else
        guard registrationStarted else { startRegistration(); return }
        Task { [weak self] in
            guard let self else { return }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            default: return
            }
            UIApplication.shared.registerForRemoteNotifications()
            if let token = defaults.string(forKey: Key.deviceToken) {
                scheduleUpload(token: token, force: fingerprintChanged(for: token))
            }
        }
        #endif
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let previous = defaults.string(forKey: Key.deviceToken)
        defaults.set(token, forKey: Key.deviceToken)
        scheduleUpload(token: token,
                       force: previous != token || fingerprintChanged(for: token))
    }

    func didFailToRegister(error: Error) {
        print("[push] APNs 注册失败: \(error.localizedDescription)")
    }

    // —— 上报 ————————————————————————————————

    private func scheduleUpload(token: String, force: Bool) {
        guard shouldUpload(force: force) else { return }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in await self?.upload(token: token) }
    }

    private func shouldUpload(force: Bool) -> Bool {
        if force { return true }
        let now = Date()
        if let last = defaults.object(forKey: Key.lastUploadAt) as? Date,
           now.timeIntervalSince(last) < successfulUploadInterval { return false }
        if let attempt = defaults.object(forKey: Key.lastAttemptAt) as? Date,
           now.timeIntervalSince(attempt) < failedAttemptCooldown { return false }
        return true
    }

    private func upload(token: String) async {
        defaults.set(Date(), forKey: Key.lastAttemptAt)
        let info = Bundle.main.infoDictionary ?? [:]
        // 键名对着后端 APNsRegistrationRequest 的 snake_case 一个个写死，别走自动转换
        let payload: [String: Any] = [
            "device_id": persistentDeviceID(),
            "transport": "apns",
            "platform": "ios",
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.example.couplecalendar",
            "environment": Self.apnsEnvironment,
            "device_token": token,
            "app_version": info["CFBundleShortVersionString"] as? String ?? "",
            "app_build": info["CFBundleVersion"] as? String ?? "",
            "device_label": "\(UIDevice.current.model) \(UIDevice.current.systemVersion)",
            "enabled": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            let reply = try await CalendarAPI.shared.registerPush(payload: data)
            // 之前踩过的坑：门卫把请求领去登录页返回的也是 200，
            // app 就记了个假成功、服务器上其实 0 台。只认「JSON 且 ok:true
            // 且环境对得上」，别的一律当失败 —— 冷却之后自然会重试
            guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  obj["ok"] as? Bool == true,
                  obj["environment"] as? String == Self.apnsEnvironment else {
                print("[push] 登记响应不是预期的 JSON，不记成功")
                return
            }
            defaults.set(Date(), forKey: Key.lastUploadAt)
            defaults.set(fingerprint(for: token), forKey: Key.lastFingerprint)
            print("[push] token 已登记 (\(Self.apnsEnvironment))")
        } catch {
            print("[push] token 登记失败: \(error)")
        }
    }

    private func persistentDeviceID() -> String {
        if let cur = defaults.string(forKey: Key.deviceID), !cur.isEmpty { return cur }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Key.deviceID)
        return fresh
    }

    /// app 版本 / 系统升级后指纹变了就立刻重报，别等 12 小时
    private func fingerprintChanged(for token: String) -> Bool {
        defaults.string(forKey: Key.lastFingerprint) != fingerprint(for: token)
    }

    private func fingerprint(for token: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return [token,
                Bundle.main.bundleIdentifier ?? "",
                Self.apnsEnvironment,
                info["CFBundleShortVersionString"] as? String ?? "",
                info["CFBundleVersion"] as? String ?? "",
                UIDevice.current.systemVersion].joined(separator: "\u{1f}")
    }

    private nonisolated static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

// —— 点通知 → 跳到那一天 ——————————————————————
@MainActor
final class PushDayRouter {
    static let shared = PushDayRouter()
    private init() {}

    /// RootView 起来时把跳转动作挂进来；挂上那一刻先把攒着的放行
    var onOpenDay: ((CalMonth, Int) -> Void)? {
        didSet {
            if let p = pending, let cb = onOpenDay {
                pending = nil
                cb(p.0, p.1)
            }
        }
    }
    private var pending: (CalMonth, Int)?

    func open(dayKey: String) {
        guard let (m, d) = CalMonth.parseDayKey(dayKey) else { return }
        if let cb = onOpenDay { cb(m, d) } else { pending = (m, d) }
    }
}

// —— 系统回调 ————————————————————————————————
final class CalendarAppDelegate: NSObject, UIApplicationDelegate,
                                 UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            CalendarPushManager.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            CalendarPushManager.shared.didFailToRegister(error: error)
        }
    }

    /// app 开着的时候照样弹横幅 —— 用户可能正翻着别的月
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// 点了通知：带着 calendar_day 就直接翻到那一页
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let day = userInfo["calendar_day"] as? String, !day.isEmpty {
            Task { @MainActor in PushDayRouter.shared.open(dayKey: day) }
        }
        completionHandler()
    }
}
