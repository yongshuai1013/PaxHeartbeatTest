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
/// 日誌 E 前綴：所有 E 行只進詳細頁（full）；主頁只留 ✅/❌ 敘事結論行。
final class EMProxyController {
    static let shared = EMProxyController()
    private init() {}

    /// EMProxy 是否運行中（toggle 方向與敘事行用；只在 start/stop 成功後翻面）
    private(set) var isRunning = false

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
        log("E < stop OK @\(ms())ms")
        log("EMProxy 已停止")
    }
}
