import Foundation

// ============================================================
// CalendarAPI.swift — 跟网关日历接口说话的唯一一层。
// 上面是 CalendarStore，下面是 URLSession，别的地方一律不许自己发请求。
//
// 规矩：
//   · 每个请求都带 X-Calendar-Token（CalendarSecrets.token）
//   · 不重试。后端 POST 完全不去重，同一个 body 发两遍就是两条事件，
//     网络一抖用户就得自己肉眼找出来手删。写操作宁可报错也不偷偷重发
//   · 超时 12 秒，waitsForConnectivity 关掉 —— 没网就立刻报 offline，不吊在那儿转
//   · from/to 用 Z 结尾的 UTC 串。URLComponents 不转义 + 号（实测），
//     用 +08:00 会被后端当成空格，直接 400。另外还补了一道 percentEncodedQuery 兜底
// ============================================================

enum CalendarAPIError: Error {
    case offline            // 网络不通
    case unauthorized       // 401，token 不对
    case badRequest(String) // 400，后端 detail
    case notFound
    case server(Int)
    case decoding(Error)
}

final class CalendarAPI: Sendable {
    static let shared = CalendarAPI()

    private let base: URL
    private let token: String
    private let session: URLSession

    init(base: String = CalendarSecrets.baseURL, token: String = CalendarSecrets.token) {
        self.base = URL(string: base) ?? URL(string: "https://invalid.invalid")!
        self.token = token
        let c = URLSessionConfiguration.ephemeral      // 本地一份缓存都不留
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        self.session = URLSession(configuration: c)
    }

    // MARK: - 对外的四件事

    /// 拉一个区间的事件。半开区间 [from, to)：ends_at 正好等于 from 的不算，
    /// starts_at 正好等于 to 的也不算 —— 月视图用「本月1号 → 次月1号」不会重复画边界那条
    func list(from: Date, to: Date) async throws -> [EventDTO] {
        let data = try await send(path: "/events", method: "GET", query: [
            URLQueryItem(name: "from", value: CalTime.isoUTC(from)),
            URLQueryItem(name: "to", value: CalTime.isoUTC(to)),
        ])
        do {
            return try Self.decoder.decode(EventListDTO.self, from: data).events
        } catch {
            throw CalendarAPIError.decoding(error)
        }
    }

    @discardableResult
    func create(_ body: EventWriteDTO) async throws -> EventDTO {
        try await write(path: "/events", method: "POST", body: body)
    }

    @discardableResult
    func update(id: String, _ body: EventWriteDTO) async throws -> EventDTO {
        try await write(path: "/events/\(id)", method: "PATCH", body: body)
    }

    /// 软删。返回的是删掉之后那条完整记录（status 变成 deleted），不是 {ok:true}。
    /// 注意它不幂等：同一条删第二次是 404
    @discardableResult
    func delete(id: String) async throws -> EventDTO {
        let data = try await send(path: "/events/\(id)", method: "DELETE")
        do {
            return try Self.decoder.decode(EventDTO.self, from: data)
        } catch {
            throw CalendarAPIError.decoding(error)
        }
    }

    // MARK: - 便签

    /// 拉一个区间的便签。跟事件一样是半开区间 [from, to)，
    /// 但后端这边比的是 anchor_date 这个纯日期串，所以传的也是 "2026-08-01" 这种形状 ——
    /// to 必须给下个月 1 号，给本月最后一天会整天漏掉那天
    func listNotes(fromDay: String, toDay: String) async throws -> [NoteDTO] {
        let data = try await send(path: "/notes", method: "GET", query: [
            URLQueryItem(name: "from", value: fromDay),
            URLQueryItem(name: "to", value: toDay),
        ])
        do {
            return try Self.decoder.decode(NoteListDTO.self, from: data).notes
        } catch {
            throw CalendarAPIError.decoding(error)
        }
    }

    @discardableResult
    func createNote(_ body: NoteWriteDTO) async throws -> NoteDTO {
        try await writeNote(path: "/notes", method: "POST", body: body)
    }

    @discardableResult
    func updateNote(id: String, _ body: NoteWriteDTO) async throws -> NoteDTO {
        try await writeNote(path: "/notes/\(id)", method: "PATCH", body: body)
    }

    /// 软删。跟事件那边一样不幂等，删第二次是 404
    @discardableResult
    func deleteNote(id: String) async throws -> NoteDTO {
        let data = try await send(path: "/notes/\(id)", method: "DELETE")
        do {
            return try Self.decoder.decode(NoteDTO.self, from: data)
        } catch {
            throw CalendarAPIError.decoding(error)
        }
    }

    private func writeNote(path: String, method: String, body: NoteWriteDTO) async throws -> NoteDTO {
        let payload: Data
        do {
            payload = try Self.encoder.encode(body)
        } catch {
            throw CalendarAPIError.decoding(error)
        }
        let data = try await send(path: path, method: method, body: payload)
        do {
            return try Self.decoder.decode(NoteDTO.self, from: data)
        } catch {
            throw CalendarAPIError.decoding(error)
        }
    }

    // MARK: - 感叹号（未读）

    /// 拉全部未读的日子，不带区间 —— store 那份 unseenDays 是一个扁平集合、整份替换，
    /// 按月拉会在翻月的时候把别的月的感叹号抹掉。现实里就几条，一次全给最省事
    func listUnseen() async throws -> [String] {
        let data = try await send(path: "/unseen", method: "GET")
        do {
            return try Self.decoder.decode(UnseenDaysDTO.self, from: data).days
        } catch {
            throw CalendarAPIError.decoding(error)
        }
    }

    /// 某一天看过了。服务端天然幂等（同一天打两遍第二遍 cleared=0），
    /// 但这一层的规矩还是不重试 —— 打不动就算了，下一次拉取会把这天再带回来
    func markSeen(day: String) async throws {
        let payload: Data
        do {
            payload = try Self.encoder.encode(["date": day])
        } catch {
            throw CalendarAPIError.decoding(error)
        }
        _ = try await send(path: "/unseen/seen", method: "POST", body: payload)
    }

    /// 探活，不查 token。调试用，正常流程走不到
    func ping() async -> Bool {
        (try? await send(path: "/ping", method: "GET")) != nil
    }

    // MARK: - 推送 token 登记

    /// 「我们的日历」自己的 APNs token 报给网关（POST /push/register，同一把日历钥匙）。
    /// payload 由 CalendarPushManager 拼好 —— 键名要跟后端逐字对上，这层不碰内容。
    /// 响应原样交回去：成不成功由调用方验 JSON 说了算，不是看状态码
    func registerPush(payload: Data) async throws -> Data {
        try await send(path: "/push/register", method: "POST", body: payload)
    }

    // MARK: - 整页图（阶段五）

    /// 把渲染好的那一页传上去。multipart，字段名 file，一天一张服务端覆盖写。
    /// 覆盖写天然幂等，但这一层的规矩不变：不重试，失败交给 PageSync 的记号等下一次
    func uploadPage(day: String, png: Data) async throws {
        let url = base.appendingPathComponent("pages/\(day)/render")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-Calendar-Token")
        let boundary = "cc-page-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func put(_ s: String) { body.append(Data(s.utf8)) }
        put("--\(boundary)\r\n")
        put("Content-Disposition: form-data; name=\"file\"; filename=\"\(day).png\"\r\n")
        put("Content-Type: image/png\r\n\r\n")
        body.append(png)
        put("\r\n--\(boundary)--\r\n")
        req.httpBody = body
        _ = try await run(req)
    }

    // MARK: - 底下

    private func write(path: String, method: String, body: EventWriteDTO) async throws -> EventDTO {
        let payload: Data
        do {
            payload = try Self.encoder.encode(body)
        } catch {
            throw CalendarAPIError.decoding(error)
        }
        let data = try await send(path: path, method: method, body: payload)
        do {
            return try Self.decoder.decode(EventDTO.self, from: data)
        } catch {
            throw CalendarAPIError.decoding(error)
        }
    }

    private func send(path: String, method: String,
                      query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard var comps = URLComponents(url: base.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else {
            throw CalendarAPIError.server(-1)
        }
        if !query.isEmpty {
            comps.queryItems = query
            // URLComponents 认为 + 在查询串里是合法字符，不会转义它，
            // 而后端把它解成空格。现在的时间串是 Z 结尾本来就没有 +，这里再补一道保险
            comps.percentEncodedQuery = comps.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { throw CalendarAPIError.server(-1) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Calendar-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await run(req)
    }

    /// 真正跑一发请求 + 状态码归类。send（JSON 那路）和 uploadPage（multipart）共用，
    /// 错误的分法必须一直是同一套
    private func run(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // URLError 一律算不通：没网、超时、DNS 挂了、证书不对，对用户来说都是「连不上」
            throw CalendarAPIError.offline
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200...299:
            return data
        case 401, 403:
            throw CalendarAPIError.unauthorized
        case 404:
            throw CalendarAPIError.notFound
        case 400, 422:
            throw CalendarAPIError.badRequest(Self.detail(from: data))
        default:
            throw CalendarAPIError.server(code)
        }
    }

    /// 后端的 detail 是多态的：应用级错误（400/401/404）是一个字符串，
    /// FastAPI 自己的请求校验（422，比如 JSON 坏掉）是一个对象数组。
    /// 写成 struct { let detail: String } 会在 422 上直接抛，真实原因全丢，所以用 JSONSerialization 分两路认
    static func detail(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let s = obj["detail"] as? String { return s }
        if let arr = obj["detail"] as? [[String: Any]] {
            let msgs = arr.compactMap { $0["msg"] as? String }
            if !msgs.isEmpty { return msgs.joined(separator: "; ") }
        }
        return ""
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // 后端回的是 2026-08-05T06:30:00+00:00，带冒号的 offset、无小数秒，这个策略直接吃得下（实测）。
        // keyDecodingStrategy 一个都不设：convertFromSnakeCase 会把 metadata 里的键一起改名
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        JSONEncoder()
    }()
}

/// GET /calendar/unseen 的回包。键就是纯小写的 days，没有 snake_case，
/// 所以不用写 CodingKeys（本文件那个 decoder 是不设 keyDecodingStrategy 的）
private struct UnseenDaysDTO: Decodable {
    let days: [String]
}
