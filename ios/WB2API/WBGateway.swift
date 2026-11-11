import Foundation
import Combine

// MARK: - 数据模型（与 Go 侧 StatusJSON 对齐）

struct WBAccount: Identifiable, Decodable {
    var id: String { uid }
    let uid: String
    let nickname: String
    let realm: String
    let domain: String
    let expiresAt: Int64
    let file: String
    /// 剩余可用积分（最近一次查询值）
    let credits: Int64
    /// 其中「快过期」的部分
    let creditsExpiring: Int64
    /// 积分采样时间（Unix 秒；0 = 从未查询）
    let creditsAt: Int64
    /// 上次查询失败原因（空 = 正常）
    let creditsErr: String?
    /// 冷却中 / 已禁用（界面标色用）
    let cooling: Bool
    let disabled: Bool

    enum CodingKeys: String, CodingKey {
        case uid, nickname, realm, domain, file, credits, cooling, disabled
        case expiresAt = "expires_at"
        case creditsExpiring = "credits_expiring"
        case creditsAt = "credits_at"
        case creditsErr = "credits_err"
    }

    /// 容错解码：Go 侧新增字段缺席时（旧内核）按 0/false 处理，不整条解析失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        nickname = (try? c.decodeIfPresent(String.self, forKey: .nickname)) ?? ""
        realm = (try? c.decodeIfPresent(String.self, forKey: .realm)) ?? "cn"
        domain = (try? c.decodeIfPresent(String.self, forKey: .domain)) ?? ""
        expiresAt = (try? c.decodeIfPresent(Int64.self, forKey: .expiresAt)) ?? 0
        file = (try? c.decodeIfPresent(String.self, forKey: .file)) ?? ""
        credits = (try? c.decodeIfPresent(Int64.self, forKey: .credits)) ?? 0
        creditsExpiring = (try? c.decodeIfPresent(Int64.self, forKey: .creditsExpiring)) ?? 0
        creditsAt = (try? c.decodeIfPresent(Int64.self, forKey: .creditsAt)) ?? 0
        creditsErr = try? c.decodeIfPresent(String.self, forKey: .creditsErr)
        cooling = (try? c.decodeIfPresent(Bool.self, forKey: .cooling)) ?? false
        disabled = (try? c.decodeIfPresent(Bool.self, forKey: .disabled)) ?? false
    }

    /// 凭证剩余有效期文案
    var expiryText: String {
        guard expiresAt > 0 else { return "—" }
        let left = expiresAt - Int64(Date().timeIntervalSince1970)
        if left <= 0 { return "已过期" }
        let d = left / 86400
        if d > 0 { return "剩 \(d) 天" }
        return "剩 \(left / 3600) 小时"
    }

    var realmText: String { realm == "global" ? "国际" : "国内" }

    /// 积分文案：整数不带小数点，超千位加千分位
    var creditsText: String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.groupingSeparator = ","
        return n.string(from: NSNumber(value: credits)) ?? "\(credits)"
    }

    /// 积分采样时间文案（相对时间）
    var creditsTimeText: String {
        guard creditsAt > 0 else { return "未查询" }
        let now = Int64(Date().timeIntervalSince1970)
        let ago = max(0, now - creditsAt)
        if ago < 60 { return "刚刚刷新" }
        if ago < 3600 { return "\(ago / 60) 分钟前刷新" }
        if ago < 86400 { return "\(ago / 3600) 小时前刷新" }
        return "\(ago / 86400) 天前刷新"
    }

    /// 状态文案（优先展示错误，其次冷却/禁用）
    var stateText: String? {
        if let e = creditsErr, !e.isEmpty { return e }
        if disabled { return "已禁用" }
        if cooling { return "冷却中" }
        return nil
    }
}

struct WBStatus: Decodable {
    let running: Bool
    let addr: String
    let uptime: Int
    let dataDir: String
    let apiKey: String
    let redisMode: String
    let accounts: [WBAccount]
    let available: Int
    let version: String
    /// 所有账号剩余积分之和
    let totalCredits: Int64

    enum CodingKeys: String, CodingKey {
        case running, addr, uptime, accounts, available, version
        case dataDir = "data_dir"
        case apiKey = "api_key"
        case redisMode = "redis_mode"
        case totalCredits = "total_credits"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = (try? c.decodeIfPresent(Bool.self, forKey: .running)) ?? false
        addr = (try? c.decodeIfPresent(String.self, forKey: .addr)) ?? ""
        uptime = (try? c.decodeIfPresent(Int.self, forKey: .uptime)) ?? 0
        dataDir = (try? c.decodeIfPresent(String.self, forKey: .dataDir)) ?? ""
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
        redisMode = (try? c.decodeIfPresent(String.self, forKey: .redisMode)) ?? ""
        accounts = (try? c.decodeIfPresent([WBAccount].self, forKey: .accounts)) ?? []
        available = (try? c.decodeIfPresent(Int.self, forKey: .available)) ?? 0
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? ""
        totalCredits = (try? c.decodeIfPresent(Int64.self, forKey: .totalCredits)) ?? 0
    }

    var baseURL: String { "http://\(addr)" }
    var uptimeText: String {
        if uptime < 60 { return "\(uptime) 秒" }
        if uptime < 3600 { return "\(uptime / 60) 分钟" }
        return "\(uptime / 3600) 小时 \((uptime % 3600) / 60) 分"
    }

    /// 总积分文案（千分位）
    var totalCreditsText: String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.groupingSeparator = ","
        return n.string(from: NSNumber(value: totalCredits)) ?? "\(totalCredits)"
    }
}

/// 登录接口的统一信封（Go 侧返回 {"ok":…,"data":…,"error":…}）
struct WBEnvelope: Decodable {
    let ok: Bool
    let error: String?
}

/// 带 data 载荷的信封（导入接口用；登录仍走 WBEnvelope，不改既有路径）
struct WBDataEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let data: T?
}

/// 导入结果条目（对应 Go 侧 wbios.ImportItem）
struct WBImportItem: Decodable, Identifiable {
    var id: String { uid + "|" + status + "|" + (reason ?? "") }
    let uid: String
    let nickname: String
    let status: String   // added / updated / skipped
    let reason: String?
    let file: String?

    var statusText: String {
        switch status {
        case "added": return "新增"
        case "updated": return "更新"
        default: return "跳过"
        }
    }
}

/// 导入汇总（对应 Go 侧 wbios.ImportResult）
struct WBImportResult: Decodable {
    let total: Int
    let added: Int
    let updated: Int
    let skipped: Int
    let items: [WBImportItem]
}

// MARK: - 网关控制器

final class WBGateway: ObservableObject {
    static let shared = WBGateway()

    @Published private(set) var status: WBStatus?
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var keepAliveOn = false
    @Published private(set) var refreshingCredits = false
    @Published var alert: String?
    @Published var toast: String?

    /// 数据目录：Documents/WB2API（文件 App 可见）
    let dataDir: URL

    private var timer: Timer?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dataDir = docs.appendingPathComponent("WB2API", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        refresh()
        // 每 3 秒刷新一次状态（运行中时）
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.refresh()
        }
    }

    // MARK: Go 调用辅助

    private func wbString(_ f: () -> UnsafeMutablePointer<CChar>?) -> String {
        guard let p = f() else { return "" }
        defer { WbFree(p) }
        return String(cString: p)
    }

    private func wbCall(_ dataDir: String, _ f: (UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?) -> String {
        dataDir.withCString { c in
            wbString { f(UnsafeMutablePointer(mutating: c)) }
        }
    }

    private func wbCall2(_ dataDir: String, _ arg: String,
                         _ f: (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?) -> String {
        dataDir.withCString { c in
            arg.withCString { a in
                wbString { f(UnsafeMutablePointer(mutating: c), UnsafeMutablePointer(mutating: a)) }
            }
        }
    }

    // MARK: 状态

    func refresh() {
        let json = wbString { WbStatus() }
        if let d = json.data(using: .utf8), let st = try? JSONDecoder().decode(WBStatus.self, from: d) {
            status = st
            running = st.running
        } else {
            running = WbRunning() == 1
        }
    }

    /// 立即查询所有账号积分（走上游 billing/meter）。
    /// 内核并发限制在 2，个位数账号通常 1~3 秒返回；不阻塞 UI。
    /// 完成后自动 refresh() 让界面拿到新值。
    func refreshCredits() {
        guard !refreshingCredits else { return }
        refreshingCredits = true
        DispatchQueue.global(qos: .utility).async {
            let n = WbRefreshCredits()
            DispatchQueue.main.async {
                self.refreshingCredits = false
                if n < 0 {
                    self.toast = "反代未运行，先启动"
                } else if n == 0 {
                    self.toast = "积分刷新失败，稍后重试"
                } else {
                    self.toast = "已刷新 \(n) 个账号的积分"
                }
                self.refresh()
            }
        }
    }

    // MARK: 启停

    func start() {
        guard !busy, !running else { return }
        busy = true
        let dir = dataDir.path
        let listen = ""
        let key = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let ret = dir.withCString { cDir in
                listen.withCString { cListen in
                    key.withCString { cKey in
                        WbStart(UnsafeMutablePointer(mutating: cDir),
                                UnsafeMutablePointer(mutating: cListen),
                                UnsafeMutablePointer(mutating: cKey))
                    }
                }
            }
            var err: String?
            if let p = ret { err = String(cString: p); WbFree(p) }
            DispatchQueue.main.async {
                self.busy = false
                if let e = err, !e.isEmpty { self.alert = e }
                self.refresh()
                if self.running {
                    self.applyKeepAlive(UserDefaults.standard.object(forKey: "keepAlive") as? Bool ?? true)
                    // 启动成功后立刻拉一次积分（后台每 5.5 分钟自动续）
                    self.refreshCredits()
                }
            }
        }
    }

    func stop() {
        guard !busy, running else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ret = WbStop()
            var err: String?
            if let p = ret { err = String(cString: p); WbFree(p) }
            DispatchQueue.main.async {
                self.busy = false
                if let e = err, !e.isEmpty { self.alert = e }
                KeepAlive.shared.stop()
                self.keepAliveOn = false
                self.refresh()
            }
        }
    }

    // MARK: 保活

    func applyKeepAlive(_ wanted: Bool) {
        if wanted && running {
            let strong = (UserDefaults.standard.object(forKey: "keepAliveStrong") as? Bool) ?? false
            keepAliveOn = KeepAlive.shared.start(strong: strong)
        } else {
            KeepAlive.shared.stop()
            keepAliveOn = false
        }
    }

    // MARK: 账号

    func deleteAccount(_ uid: String) {
        let ret = wbCall2(dataDir.path, uid) { cDir, cUid in WbDeleteAccount(cDir, cUid) }
        if let d = ret.data(using: .utf8), let env = try? JSONDecoder().decode(WBEnvelope.self, from: d), env.ok {
            toast = "已删除账号"
        } else if let d = ret.data(using: .utf8), let env = try? JSONDecoder().decode(WBEnvelope.self, from: d) {
            alert = env.error
        }
        refresh()
    }

    /// 发起登录，返回授权 URL（失败返回 nil 并设置 alert）
    func loginStart(realm: String) -> String? {
        let ret = wbCall2(dataDir.path, realm) { cDir, cRealm in WbLoginStart(cDir, cRealm) }
        return decodeEnvelopeString(ret)
    }

    /// 轮询一次；成功返回账号描述（并刷新列表）
    func loginPoll(realm: String) -> (String?, String?) {
        let ret = wbCall2(dataDir.path, realm) { cDir, cRealm in WbLoginPoll(cDir, cRealm) }
        guard let d = ret.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return (nil, "返回数据异常")
        }
        if let ok = obj["ok"] as? Bool, ok {
            if let dataStr = obj["data"] as? String,
               let dd = dataStr.data(using: .utf8),
               let m = try? JSONSerialization.jsonObject(with: dd) as? [String: Any] {
                let nick = (m["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (m["uid"] as? String ?? "")
                refresh()
                return ("已添加账号：\(nick)", nil)
            }
            refresh()
            return ("已添加账号", nil)
        }
        return (nil, obj["error"] as? String ?? "登录未完成")
    }

    func loginCancel() {
        _ = wbCall(dataDir.path) { cDir in
            WbLoginCancel(cDir)
            return nil
        }
    }

    /// 导入账号 JSON（粘贴 / 文件）。失败返回 nil，原因写进 alert。
    /// 同步调用 Go 内核：纯本地解析 + 落盘，无网络，几十条也是毫秒级；
    /// 调用方仍应在后台线程调用，避免大文本卡主线程。
    @discardableResult
    func importJSON(_ raw: String, allowRefresh: Bool = true) -> WBImportResult? {
        let ret = wbCall2(dataDir.path, raw) { cDir, cJSON in
            WbImportJSON(cDir, cJSON, allowRefresh ? 1 : 0)
        }
        guard let d = ret.data(using: .utf8) else {
            DispatchQueue.main.async { self.alert = "返回数据异常" }
            return nil
        }
        let dec = JSONDecoder()
        if let env = try? dec.decode(WBDataEnvelope<WBImportResult>.self, from: d) {
            if env.ok, let r = env.data {
                DispatchQueue.main.async { self.refresh() }
                return r
            }
            DispatchQueue.main.async { self.alert = env.error ?? "导入失败" }
            return nil
        }
        // 兜底：只拿到 {"ok":false,"error":…}
        if let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let e = obj["error"] as? String {
            DispatchQueue.main.async { self.alert = e }
        } else {
            DispatchQueue.main.async { self.alert = "返回数据异常" }
        }
        return nil
    }

    private func decodeEnvelopeString(_ ret: String) -> String? {
        guard let d = ret.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let ok = obj["ok"] as? Bool, ok, let s = obj["data"] as? String { return s }
        if let e = obj["error"] as? String {
            DispatchQueue.main.async { self.alert = e }
        }
        return nil
    }
}
