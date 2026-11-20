import Foundation
import Minimuxer
import ZIPFoundation

/// minimuxer 安裝（按鈕 9）：安裝鏈改走 minimuxer 連線層（0.6.4 本體／minimuxer 套件的正規用法）。
/// 背景：idevice 直連（按鈕 5）的 lockdown 第一筆交換被裝置端 RST（同場實證判負）；
/// minimuxer 路（按鈕 8）同分鐘回真 UDID 成功，故安裝也改走這層。
/// 序列照本體：bindConnectionConfig（LocalDevVPN）→ core.start → 解壓 IPA（同按鈕 5 的流程）
/// → core.sendAppBundleAfc(bundleId:appURL:) → core.installAppBundle(bundleId:appName:)。
/// 後兩支是套件 MinimuxerAPI 的現成函數：gateway 經自家 usbmuxd proxy 取得服務連線
/// （afc_client_connect／installation_proxy_connect），staging 路徑
/// PublicStaging/<bundleId>/<App>.app、安裝選項 PackageType=Developer——全用套件現成 API，不自創協議。
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

        // 解壓 IPA（同按鈕 5／AppInstaller 的流程：ZIPFoundation 逐 entry 展開，取 Payload/*.app）
        log("M > extract ipa")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appLocalURL: URL
        let appName: String
        let bundleId: String
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            guard let archive = Archive(url: ipaURL, accessMode: .read) else {
                throw InstallerError.afcFailed("無法打開 IPA")
            }
            for entry in archive {
                let dest = tempDir.appendingPathComponent(entry.path)
                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try archive.extract(entry, to: dest)
                }
            }
            let payloadDir = tempDir.appendingPathComponent("Payload")
            let contents = try FileManager.default.contentsOfDirectory(atPath: payloadDir.path)
            guard let found = contents.first(where: { $0.hasSuffix(".app") }) else {
                throw InstallerError.afcFailed("找不到 .app")
            }
            appName = found
            appLocalURL = payloadDir.appendingPathComponent(found)
            // bundleId 以 .app 的 Info.plist CFBundleIdentifier 為準（本體 staging 資料夾名用的就是它）
            let info = NSDictionary(contentsOf: appLocalURL.appendingPathComponent("Info.plist"))
            guard let bid = info?["CFBundleIdentifier"] as? String, !bid.isEmpty else {
                throw InstallerError.afcFailed("讀不到 CFBundleIdentifier")
            }
            bundleId = bid
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            let what = error.localizedDescription
            log("M X extract err=\(what) life=\(ms())ms")
            log("❌ minimuxer 安裝：解壓失敗（\(what)）")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }
        log("M < extract OK app=\(appName) bundleId=\(bundleId) @\(ms())ms")

        // AFC 上傳 .app（套件現成 API：gateway 經 usbmuxd proxy 連 AFC，
        // 上傳到 PublicStaging/<bundleId>/<App>.app）
        log("M > sendAppBundleAfc bundleId=\(bundleId) app=\(appName)")
        do {
            try await mm.core.sendAppBundleAfc(bundleId: bundleId, appURL: appLocalURL)
        } catch {
            let what = describe(error, core: mm.core)
            log("M X sendAppBundleAfc err=\(what) life=\(ms())ms")
            log("❌ minimuxer 安裝：AFC 上傳失敗（\(what)）")
            return
        }
        log("M < sendAppBundleAfc OK @\(ms())ms")

        // installation_proxy 安裝（套件現成 API：PackageType=Developer）
        log("M > installAppBundle bundleId=\(bundleId) app=\(appName)")
        do {
            try await mm.core.installAppBundle(bundleId: bundleId, appName: appName)
        } catch {
            let what = describe(error, core: mm.core)
            log("M X installAppBundle err=\(what) life=\(ms())ms")
            log("❌ minimuxer 安裝：installation_proxy 安裝失敗（\(what)）")
            return
        }
        log("M < installAppBundle OK @\(ms())ms")
        log("✅ minimuxer 安裝完成：\(appName)（\(bundleId)）")
    }

    /// 錯誤原文：MinimuxerError 用核心自己的 describeError，其餘用 localizedDescription
    private func describe(_ error: Error, core: any MinimuxerAPI) -> String {
        if let mmError = error as? MinimuxerError {
            return core.describeError(mmError)
        }
        return error.localizedDescription
    }
}
