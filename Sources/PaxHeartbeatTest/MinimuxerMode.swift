import Foundation
import Minimuxer

/// minimuxer 模式（按鈕 8）：把 SideStore 0.6.4 本體的 minimuxer 連線層搬進來判別。
/// 啟動序列照本體 AppBootManager.startMinimuxer 與 MinimuxerWrapper（讀碼複製，不改參數）：
///   bindConnectionConfig（LocalDevVPN 模式）→ core.start(pairingFile:mountPath:) → core.fetchUDID()
/// LocalDevVPN 模式不開 EMProxy——本體只在 enableEMPforWireguard 時才開，照原樣不開。
/// 日誌 M 前綴：M > ／M < 是步驟明細（只進詳細頁）；M OPEN／M X 與 ✅/❌ 結論進主頁摘要。
/// minimuxer 內部 log 只去 print()、無 callback 可接，故 M 行由本層在每個步驟邊界發出，
/// 錯誤一律記核心回傳的原文（MinimuxerError 走 core.describeError）。
final class MinimuxerModeTester {
    static let shared = MinimuxerModeTester()
    private init() {}

    /// binding 回報值（minimuxer 掃介面後經 setter 回報，記下來供判讀）
    private var reportedPeerIp: String?
    private var reportedIfaceIp: String?

    func run(log: @escaping (String) -> Void) async {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        // 配對檔：按鈕 3 已存的那份（與常駐心跳同一份）；本體餵的是配對檔內容字串
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pairingURL = docs.appendingPathComponent("PairingFiles/PairingFile_Lockdown.plist")
        guard let pairingString = try? String(contentsOf: pairingURL, encoding: .utf8) else {
            log("M X err=pairing file missing or not utf8 life=\(ms())ms")
            log("❌ minimuxer 模式：讀不到配對檔（先按 3 選擇配對檔）")
            return
        }
        log("M > pairing file loaded (\(pairingString.count) chars)")

        // facade 取得：照本體 MinimuxerWrapper（backend 預設 .idevice，其餘用常數本值）
        let mm = Minimuxer.shared(
            backend: .idevice,
            remotePairingPort: MinimuxerConstants.remotePairingPort,
            deviceProbeTimeout: MinimuxerConstants.defaultTCPProbeTimeoutMs
        )

        // bindConnectionConfig：binding 形狀照本體 MinimuxerWrapper.bindConnectionConfig；
        // 連線模式固定 .localVPN（本體由 ConnectionConfig.useLocalVPN 決定，本 App 只測此模式）；
        // override peer 與 remote server 在本體預設皆為空，照原樣。
        let binding = ConnectionConfigBinding(
            setTunnelIfaceIp: { [weak self] value in
                self?.reportedIfaceIp = value
                if let value { log("M < reported iface=\(value)") }
            },
            setTunnelPeerIp: { [weak self] value in
                self?.reportedPeerIp = value
                if let value { log("M < reported peer=\(value)") }
            },
            setTunnelPeerSubnetMask: { value in
                if let value { log("M < reported peerMask=\(value)") }
            },
            setTunnelPeerReachable: { value in
                log("M < reported peerReachable=\(value)")
            },
            setTunnelIfaceSubnetMask: { _ in },
            getRemoteServerIp: { "" },
            setRemoteReachable: { _ in },
            getOverrideTunnelPeerIp: { "" },
            setOverrideTunnelPeerReachable: { _ in },
            getConnectionMode: { .localVPN }
        )
        log("M OPEN bind config mode=localVPN backend=idevice")
        await mm.core.bindConnectionConfig(binding)
        log("M < bind done @\(ms())ms")

        // minimuxerStart：mountPath 照本體 AppBootManager（documentsDirectory.absoluteString）
        log("M > start")
        do {
            try await mm.core.start(pairingFile: pairingString, mountPath: docs.absoluteString)
        } catch {
            let what = describe(error, core: mm.core)
            log("M X start err=\(what) life=\(ms())ms")
            log("❌ minimuxer 模式：start 失敗（\(what)）")
            return
        }
        log("M < start OK @\(ms())ms")

        // 連通驗證：fetchUDID（本體 AppBootManager 以此驗配對與連通；只做 GetValue，不開 session）
        log("M > fetchUDID")
        do {
            let udid = try await mm.core.fetchUDID()
            if let udid, !udid.isEmpty {
                log("M < fetchUDID OK @\(ms())ms")
                log("✅ minimuxer 模式 GetValue 成功：UDID \(udid)")
            } else {
                log("M X fetchUDID returned nil life=\(ms())ms")
                log("❌ minimuxer 模式：fetchUDID 回 nil（核心未給錯誤原文）")
            }
        } catch {
            let what = describe(error, core: mm.core)
            log("M X fetchUDID err=\(what) life=\(ms())ms")
            log("❌ minimuxer 模式：fetchUDID 失敗（\(what)）")
        }
    }

    /// 錯誤原文：MinimuxerError 用核心自己的 describeError，其餘用 localizedDescription
    private func describe(_ error: Error, core: any MinimuxerAPI) -> String {
        if let mmError = error as? MinimuxerError {
            return core.describeError(mmError)
        }
        return error.localizedDescription
    }
}
