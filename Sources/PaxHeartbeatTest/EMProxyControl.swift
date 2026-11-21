import Foundation
import Minimuxer

/// EMProxy 宿主（按鈕 11）：讓 EMProxy 由測試 App 本人宿主——WireGuard App 的隧道對端
/// 連進本 App 的 EMProxy（UDP 127.0.0.1:51820），裝置連線改經 EMProxy 轉發，
/// 判別第一交換在這條路上是否仍被拆（對照 LocalDevVPN 回環的全滅）。
/// 啟動序列照 0.6.4 本體 AppBootManager＋EMProxyWrapper.startEMProxy：
///   bindConnectionConfig（與按鈕 8/9 同一套 binding，mode=.localVPN、backend=.idevice）
///   → 取 binding 回報的 tunnelPeerIp
///   → emproxy.setHandshakeClient(host: peerIp, port: 62078, enabled: !peerIp.isEmpty)
///   → emproxy.start(host: "127.0.0.1", port: 51820)
/// 按鈕 11 為 toggle：未運行按下啟動並保持運行（不自動停），運行中再按改為 stop。
/// 期望狀態旗標：start 成功後存進 UserDefaults、stop 成功後清掉；App 啟動時
/// 若旗標為開，自動照同一序列復活（照 0.6.4 本體 AppBootManager 的啟動自動
/// 拉起設計——EMProxy 宿主跟著 App 行程生死，真機兩場證實 App 一離開主頁面
/// 行程就重啟、EMProxy 跟著死，靠此旗標在重啟後復活）。
/// 日誌 E 前綴：所有 E 行只進詳細頁（full）；主頁只留 ✅/❌ 敘事結論行。
final class EMProxyController {
    static let shared = EMProxyController()
    private init() {}

    /// EMProxy 是否運行中（toggle 方向與敘事行用；只在 start/stop 成功後翻面）
    private(set) var isRunning = false

    /// 「期望開啟」旗標的 UserDefaults key（只記期望狀態，不記其他東西）
    static let desiredOnKey = "emproxy.desiredOn"

    /// 上次是否把 EMProxy 開著（App 啟動自動復活的判準）
    static var desiredOn: Bool { UserDefaults.standard.bool(forKey: desiredOnKey) }

    /// binding 回報值（minimuxer 掃介面後經 setter 回報，記下來供判讀）
    private var reportedPeerIp: String?
    private var reportedIfaceIp: String?

    func toggle(log: @escaping (String) -> Void) async {
        if isRunning {
            await stop(log: log)
        } else {
            await start(log: log)
        }
    }

    /// App 啟動自動復活：旗標為開且未運行時，跑與按鈕 11 逐字相同的 start 序列
    /// （同一套 binding→setHandshakeClient 含 fallback 兜底→start，E 行模板不變）。
    /// 開場敘事行「EMProxy 自動啟動（恢復上次開啟狀態）」由呼叫端（App 啟動序列）印。
    func autoStartIfDesired(log: @escaping (String) -> Void) async {
        guard EMProxyController.desiredOn, !isRunning else { return }
        await start(log: log)
    }

    private func start(log: @escaping (String) -> Void) async {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        // facade 取得：照本體 MinimuxerWrapper（backend 預設 .idevice，其餘用常數本值）
        let mm = Minimuxer.shared(
            backend: .idevice,
            remotePairingPort: MinimuxerConstants.remotePairingPort,
            deviceProbeTimeout: MinimuxerConstants.defaultTCPProbeTimeoutMs
        )

        // bindConnectionConfig：binding 形狀與按鈕 8/9 逐字相同（mode=.localVPN）
        let binding = ConnectionConfigBinding(
            setTunnelIfaceIp: { [weak self] value in
                self?.reportedIfaceIp = value
                if let value { log("E < reported iface=\(value)") }
            },
            setTunnelPeerIp: { [weak self] value in
                self?.reportedPeerIp = value
                if let value { log("E < reported peer=\(value)") }
            },
            setTunnelPeerSubnetMask: { value in
                if let value { log("E < reported peerMask=\(value)") }
            },
            setTunnelPeerReachable: { value in
                log("E < reported peerReachable=\(value)")
            },
            setTunnelIfaceSubnetMask: { _ in },
            getRemoteServerIp: { "" },
            setRemoteReachable: { _ in },
            getOverrideTunnelPeerIp: { "" },
            setOverrideTunnelPeerReachable: { _ in },
            getConnectionMode: { .localVPN }
        )
        log("E OPEN bind config mode=localVPN backend=idevice")
        await mm.core.bindConnectionConfig(binding)
        log("E < bind done @\(ms())ms")

        // handshake client：peer 為隧道對端（裝置），埠 62078（muxer）。
        // binding 的 peer 來自介面掃描：WireGuard 介面沒有 LocalDevVPN 那種 peer 位址、
        // 掃描會落空（真機兩場實證）——掃不到就照本體預設 10.7.0.1 兜底
        // （0.6.4 本體 AppConstants.Connection.defaultOverrideIP），enabled 一律 true。
        let scannedPeer = reportedPeerIp ?? ""
        let peerIp = scannedPeer.isEmpty ? "10.7.0.1" : scannedPeer
        let peerSrc = scannedPeer.isEmpty ? "fallback" : "scan"
        log("E > setHandshakeClient host=\(peerIp) port=62078 enabled=true src=\(peerSrc)")
        mm.emproxy.setHandshakeClient(host: peerIp, port: 62078, enabled: true)

        // EMProxy 本體啟動：綁 127.0.0.1:51820（本體 AppConstants.Proxy.serverURL）
        log("E > start host=127.0.0.1 port=51820")
        do {
            try await mm.emproxy.start(host: "127.0.0.1", port: 51820)
        } catch {
            let what = error.localizedDescription
            log("E X start err=\(what) life=\(ms())ms")
            log("❌ EMProxy 啟動失敗（\(what)）")
            return
        }
        isRunning = true
        UserDefaults.standard.set(true, forKey: EMProxyController.desiredOnKey)
        log("E < start OK @\(ms())ms")
        log("✅ EMProxy 已啟動（127.0.0.1:51820）")
    }

    private func stop(log: @escaping (String) -> Void) async {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        let mm = Minimuxer.shared(
            backend: .idevice,
            remotePairingPort: MinimuxerConstants.remotePairingPort,
            deviceProbeTimeout: MinimuxerConstants.defaultTCPProbeTimeoutMs
        )
        log("E > stop")
        do {
            try await mm.emproxy.stop()
        } catch {
            let what = error.localizedDescription
            log("E X stop err=\(what) life=\(ms())ms")
            log("❌ EMProxy 停止失敗（\(what)）")
            return
        }
        isRunning = false
        UserDefaults.standard.removeObject(forKey: EMProxyController.desiredOnKey)
        log("E < stop OK @\(ms())ms")
        log("EMProxy 已停止")
    }
}
