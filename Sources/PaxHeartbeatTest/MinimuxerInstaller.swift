import Foundation
import Minimuxer

/// minimuxer 安裝（按鈕 9）：安裝鏈改走 minimuxer 連線層（0.6.4 本體／minimuxer 套件的正規用法）。
/// 背景：idevice 直連（按鈕 5）的 lockdown 第一筆交換被裝置端 RST（同場實證判負）；
/// minimuxer 路（按鈕 8）同分鐘回真 UDID 成功，故安裝也改走這層。
/// 序列照本體：bindConnectionConfig（LocalDevVPN）→ core.start → IPA 直傳
/// → core.sendIpaAfc(bundleId:ipaBytes:) → core.installIpa(bundleId:)。
/// 直傳照 Eili 的 .ipa 模式：整顆 IPA 上傳、裝置端安裝，本機不解壓
/// （解壓路真機兩度死於 Archive 打不開檔案，整段繞過）。
/// sendIpaAfc 的 bundleId 在此只作 staging key，用 IPA 檔名去副檔名。
/// 日誌 M 前綴（比照按鈕 8）：開頭 M OPEN 標明 minimuxer install，每步 M > ／M < ＋毫秒計時，
/// 失敗記 M X ＋核心回傳的錯誤原文（MinimuxerError 走 core.describeError）。
/// 所有 M 行只進詳細頁（full）；主頁只留 ✅/❌ 敘事結論行。
final class MinimuxerInstaller {
    static let shared = MinimuxerInstaller()
    private init() {}

    /// binding 回報值（minimuxer 掃介面後經 setter 回報，記下來供判讀）
    private var reportedPeerIp: String?
    private var reportedIfaceIp: String?

    func install(ipaURL: URL, log: @escaping (String) -> Void) async {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        log("M OPEN minimuxer install ipa=\(ipaURL.lastPathComponent)")

        // 配對檔：按鈕 3 已存的那份（與按鈕 8 同一份）；本體餵的是配對檔內容字串
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pairingURL = docs.appendingPathComponent("PairingFiles/PairingFile_Lockdown.plist")
        guard let pairingString = try? String(contentsOf: pairingURL, encoding: .utf8) else {
            log("M X err=pairing file missing or not utf8 life=\(ms())ms")
            log("❌ minimuxer 安裝：讀不到配對檔（先按 3 選擇配對檔）")
            return
        }
        log("M > pairing file loaded (\(pairingString.count) chars)")

        // facade 取得：照本體 MinimuxerWrapper（backend 預設 .idevice，其餘用常數本值）
        let mm = Minimuxer.shared(
            backend: .idevice,
            remotePairingPort: MinimuxerConstants.remotePairingPort,
            deviceProbeTimeout: MinimuxerConstants.defaultTCPProbeTimeoutMs
        )

        // bindConnectionConfig：形狀照按鈕 8／本體 MinimuxerWrapper.bindConnectionConfig；
        // 連線模式固定 .localVPN，override peer 與 remote server 在本體預設皆為空，照原樣。
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
            log("❌ minimuxer 安裝：start 失敗（\(what)）")
            return
        }
        log("M < start OK @\(ms())ms")

        // IPA 直傳（照 Eili 的 .ipa 模式）：整顆 IPA 讀成 Data，經套件 sendIpaAfc 上傳、
        // installIpa 交裝置端安裝——本機不解壓（解壓路真機兩度死於 Archive 打不開檔案，整段繞過）。
        // sendIpaAfc 的 bundleId 參數在此只作 staging key：用 IPA 檔名去掉副檔名（如 LocalDevVPN-fakesigned）。
        let ipaData: Data
        do {
            ipaData = try Data(contentsOf: ipaURL)
        } catch {
            log("M X ipabytes err=\(error.localizedDescription) path=\(ipaURL.path) life=\(ms())ms")
            log("❌ minimuxer 安裝：讀不到 IPA（\(error.localizedDescription)）")
            return
        }
        log("M > ipabytes size=\(ipaData.count) path=\(ipaURL.path)")
        let stagingKey = ipaURL.deletingPathExtension().lastPathComponent

        // AFC 上傳整顆 IPA（套件現成 API：gateway 經 usbmuxd proxy 連 AFC）
        log("M > sendIpaAfc key=\(stagingKey) size=\(ipaData.count)")
        do {
            try await mm.core.sendIpaAfc(bundleId: stagingKey, ipaBytes: ipaData)
        } catch {
            let what = describe(error, core: mm.core)
            log("M X sendIpaAfc err=\(what) life=\(ms())ms")
            log("❌ minimuxer 安裝：AFC 上傳 IPA 失敗（\(what)）")
            return
        }
        log("M < sendIpaAfc OK @\(ms())ms")

        // installation_proxy 安裝 IPA（套件現成 API：裝置端自己解 IPA 安裝）
        log("M > installIpa key=\(stagingKey)")
        do {
            try await mm.core.installIpa(bundleId: stagingKey)
        } catch {
            let what = describe(error, core: mm.core)
            log("M X installIpa err=\(what) life=\(ms())ms")
            log("❌ minimuxer 安裝：installIpa 失敗（\(what)）")
            return
        }
        log("M < installIpa OK @\(ms())ms")
        log("✅ minimuxer 安裝完成（IPA 直傳）：\(ipaURL.lastPathComponent)")
    }

    /// 錯誤原文：MinimuxerError 用核心自己的 describeError，其餘用 localizedDescription
    private func describe(_ error: Error, core: any MinimuxerAPI) -> String {
        if let mmError = error as? MinimuxerError {
            return core.describeError(mmError)
        }
        return error.localizedDescription
    }
}
