import SwiftUI
import UniformTypeIdentifiers
import IDeviceFFI

/// FORENSICS 橋接：idevice 核心的每筆交換紀錄經 FFI callback 進到這裡，
/// 再轉交 FxLogRelay 送進 App 的日誌畫面（appendLog）。
private func ideviceForensicsLine(_ line: UnsafePointer<CChar>?) {
    guard let line else { return }
    let text = String(cString: line)
    DispatchQueue.main.async {
        FxLogRelay.shared.deliver(text)
    }
}

/// FORENSICS 橋接中繼：ContentView 在 onAppear 把 handler 接上 appendLog。
final class FxLogRelay {
    static let shared = FxLogRelay()
    var handler: ((String) -> Void)?
    func deliver(_ text: String) { handler?(text) }
}

/// 日誌雙層儲存：full 收全量逐筆（一字不漏，詳細頁與匯出用）；
/// summary 只收 App 自己的敘事行（主頁用）——按鈕操作、[％] 進度、✅/❌ 結論、
/// 一句話結果（如「✅ minimuxer 模式 GetValue 成功：UDID …」）。
/// 所有機器行（C／P／M／U／E 開頭的連線紀錄，不分 OPEN／X／>／<）一律只進 full：
/// idevice 重試永不停，機器行上主頁必淹版（用戶 2026-11-20 最終規格）。
final class LogStore: ObservableObject {
    @Published private(set) var summary = ""
    @Published private(set) var full = ""

    func append(_ msg: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(msg)\n"
        full += line
        if Self.isSummaryLine(msg) {
            summary += line
        }
    }

    /// 機器行一律不上主頁：C<n>（鑑識）／P<n>（探針）／M（minimuxer）／U（自研 usbmuxd）／E（EMProxy）／N（外部 muxer 探測）的連線紀錄
    /// 不分 OPEN／X／>／<／OK 全擋；探針的段標題（--- Pn …）與 PROBE MATRIX 起訖行
    /// 同屬機器輸出塊，一併擋下。其餘敘事行（操作／進度／✅❌／一句話結果）才進 summary。
    /// 註：minimuxer 的結論是以 ✅ 敘事行形式另發的，不以 M 開頭，照留主頁。
    static func isSummaryLine(_ msg: String) -> Bool {
        if msg.range(of: "^[CP][0-9]+ ", options: .regularExpression) != nil {
            return false
        }
        if msg.hasPrefix("M ") {
            return false
        }
        if msg.hasPrefix("E ") {
            return false
        }
        if msg.hasPrefix("U ") {
            return false
        }
        if msg.hasPrefix("N ") {
            return false
        }
        if msg.range(of: "^--- P[0-9]+ ", options: .regularExpression) != nil {
            return false
        }
        if msg.hasPrefix("PROBE MATRIX ") {
            return false
        }
        return true
    }
}

@main
struct PaxHeartbeatTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var deviceIP = "10.7.0.1"
    @StateObject private var logStore = LogStore()
    @State private var autoScrollLog = true
    @State private var isTesting = false
    @State private var showIPAPicker = false
    @State private var showPairingPicker = false
    @State private var selectedIPA: URL?
    @State private var pairingFile: URL?
    
    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
            ScrollView {
            VStack(spacing: 12) {
                Text("PaxHeartbeatTest")
                    .font(.title)
                    .padding(.top)
                Text("PROBE MATRIX + LOG UI + MINIMUXER + MINIMUXER INSTALL + SELF-USBMUXD + EMPROXY + EXTMUXER")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.red)
                
                // 設備 IP 輸入
                HStack {
                    Text("設備 IP:")
                    TextField("10.7.0.1", text: $deviceIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numbersAndPunctuation)
                }
                .padding(.horizontal)
                
                // 1. VPN 檢測
                Button(action: testVPN) {
                    Text("1. 測試 VPN 連接")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)
                
                // 2. 心跳服務
                Button(action: testHeartbeat) {
                    Text("2. 測試心跳服務")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)
                
                // 3. 選擇配對檔
                Button(action: { showPairingPicker = true }) {
                    HStack {
                        Text("3. 選擇配對檔")
                        Spacer()
                        Text(pairingFile?.lastPathComponent ?? "未選擇")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)
                
                // 4. 選擇 IPA
                Button(action: { showIPAPicker = true }) {
                    HStack {
                        Text("4. 選擇已簽名 IPA")
                        Spacer()
                        Text(selectedIPA?.lastPathComponent ?? "未選擇")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)
                
                // 5. 安裝
                Button(action: installIPA) {
                    Text("5. 開始 AFC 安裝")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting || selectedIPA == nil)
                
                // 5b. 本機安裝（MobileInstallation）
                Button(action: installOnDevice) {
                    Text("5b. 本機安裝（測試）")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting || selectedIPA == nil)
                
                // 5c. 列出 MI 符號（調試）
                Button(action: dumpMISymbols) {
                    Text("5c. 列出 MI 符號")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)
                
                // 6. IPA 簽名（新頁面）
                NavigationLink(destination: SigningView()) {
                    Text("6. IPA 簽名")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)

                // 7. 連線探針矩陣（原始 socket，繞開 idevice）
                Button(action: runProbeMatrix) {
                    Text("7. 連線探針矩陣")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.teal)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)

                // 8. minimuxer 模式 GetValue（0.6.4 本體的 minimuxer 連線層）
                Button(action: runMinimuxerMode) {
                    Text("8. minimuxer 模式 GetValue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.indigo)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)

                // 9. AFC 安裝（minimuxer 連線層・IPA 直傳；按鈕 5 的 idevice 直連版保留作對照）
                Button(action: installViaMinimuxer) {
                    Text("9. AFC 安裝（minimuxer・IPA 直傳）")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.indigo)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting || selectedIPA == nil)

                // 10. 自研 usbmuxd GetValue（純 Swift 手寫 mux 協議，不經 idevice／minimuxer）
                Button(action: runSelfUsbmuxd) {
                    Text("10. 自研 usbmuxd GetValue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.teal)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)

                // 11. EMProxy 宿主（toggle：啟動後保持運行，再按一次停止；EMProxy 由本 App 宿主）
                Button(action: toggleEMProxy) {
                    Text("11. 啟動 EMProxy")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.indigo)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)

                // 12. 外部 muxer 探測（探 127.0.0.1:27015 的 usbmuxd 服務——牛蛙 NBCoreText 含 usbmuxd listener 符號，疑在本機開服務）
                Button(action: probeExternalMuxer) {
                    Text("12. 探測外部 muxer")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.teal)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
                .disabled(isTesting)

                // 詳細日誌入口（完整逐筆）
                NavigationLink(destination: LogDetailView(store: logStore)) {
                    Text("詳細日誌（完整逐筆）")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)

                // 日誌輸出（主頁只顯示敘事行；機器行全量在詳細頁＋下載）
                HStack {
                    Text("日誌")
                        .font(.headline)
                    Spacer()
                    Toggle("自動滾動", isOn: $autoScrollLog)
                        .font(.caption)
                }
                .padding(.horizontal)
                // 日誌全文展開、整頁可滾動（不再用固定高度的框截斷下方日誌）
                Text(logStore.summary)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                    .padding()
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(8)
                    .padding(.horizontal)
                Color.clear
                    .frame(height: 1)
                    .id("logBottom")
            }
            .onChange(of: logStore.summary) { _ in
                if autoScrollLog {
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
            }
            }
            .navigationTitle("AFC 測試")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // FORENSICS：註冊 idevice 鑑識紀錄橋（每筆交換即時進日誌畫面）
                FxLogRelay.shared.handler = { msg in appendLog(msg) }
                idevice_forensics_set_callback(ideviceForensicsLine)
                appendLog("=== MINIMUXER + SELF-USBMUXD + EMPROXY + EXTMUXER（外部 muxer 探測版）===")
                // App 打開時，如果已有配對檔，自動啟動常駐心跳
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let pairingURL = docs.appendingPathComponent("PairingFiles/PairingFile_Lockdown.plist")
                if FileManager.default.fileExists(atPath: pairingURL.path) {
                    appendLog("檢測到已保存的配對檔，自動啟動常駐心跳...")
                    Task {
                        do {
                            try await HeartbeatManager.shared.start(pairingFileURL: pairingURL, host: deviceIP)
                            await MainActor.run {
                                appendLog("✅ 常駐心跳已自動啟動")
                            }
                        } catch {
                            await MainActor.run {
                                appendLog("⚠️ 自動啟動失敗: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                // EMProxy 自動復活：上次開啟狀態還在（UserDefaults 旗標）且未運行時，
                // 照按鈕 11 同一序列自動拉起（照 0.6.4 本體 AppBootManager——EMProxy
                // 宿主跟著 App 行程生死，行程重啟後靠旗標復活，不必再手按按鈕 11）
                if EMProxyController.desiredOn && !EMProxyController.shared.isRunning {
                    appendLog("EMProxy 自動啟動（恢復上次開啟狀態）")
                    Task {
                        await EMProxyController.shared.autoStartIfDesired { msg in
                            DispatchQueue.main.async { appendLog(msg) }
                        }
                    }
                }
            }
            .sheet(isPresented: $showIPAPicker) {
                DocumentPicker(contentTypes: [.data]) { url in
                    // 先複製進 App 容器再存容器 URL（照配對檔的形狀）：
                    // 挑選器給的 URL 是外部位置的參照，事後 Archive 直接開會打不開
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let dir = docs.appendingPathComponent("IPAInput")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        selectedIPA = dest
                        appendLog("已選擇 IPA: \(url.lastPathComponent)")
                        appendLog("✅ 已複製到 IPAInput/")
                    } catch {
                        appendLog("❌ 複製 IPA 失敗: \(error)")
                    }
                }
            }
            .sheet(isPresented: $showPairingPicker) {
                DocumentPicker(contentTypes: [.data]) { url in
                    // 複製到 AppInstaller 期望的位置
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let dir = docs.appendingPathComponent("PairingFiles")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent("PairingFile_Lockdown.plist")
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        pairingFile = dest
                        appendLog("已選擇配對檔: \(url.lastPathComponent)")
                        appendLog("✅ 已複製到 PairingFiles/")
                    } catch {
                        appendLog("❌ 複製配對檔失敗: \(error)")
                    }
                }
            }
        }
    }
    
    private func appendLog(_ msg: String) {
        logStore.append(msg)
    }
    
    private func testVPN() {
        isTesting = true
        appendLog("正在檢測 VPN: \(deviceIP):62078...")
        
        Task {
            let reachable = await VPNConnectionChecker.shared.checkConnection()
            await MainActor.run {
                if reachable {
                    appendLog("✅ VPN 隧道暢通")
                } else {
                    appendLog("❌ VPN 不通，請檢查外置 VPN 是否開啟")
                }
                isTesting = false
            }
        }
    }
    
    private func testHeartbeat() {
        isTesting = true
        appendLog("正在啟動常駐心跳服務...")
        
        Task {
            // 找配對檔
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let pairingURL = docs.appendingPathComponent("PairingFiles/PairingFile_Lockdown.plist")
            
            guard FileManager.default.fileExists(atPath: pairingURL.path) else {
                await MainActor.run {
                    appendLog("❌ 請先選擇配對檔（按鈕 3）")
                    isTesting = false
                }
                return
            }
            
            do {
                try await HeartbeatManager.shared.start(pairingFileURL: pairingURL, host: deviceIP)
                await MainActor.run {
                    appendLog("✅ 常駐心跳已啟動（App 生命週期內一直跑）")
                    appendLog("   仿 khanh8249/minimuxer 常駐模式")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    appendLog("❌ 心跳啟動失敗: \(error.localizedDescription)")
                    isTesting = false
                }
            }
        }
    }
    
    private func installIPA() {
        guard let ipaURL = selectedIPA else {
            appendLog("❌ 請先選擇 IPA 文件")
            return
        }
        guard !isTesting else {
            appendLog("⚠️ 安裝進行中，請勿重複點擊")
            return
        }
        isTesting = true
        appendLog("開始安裝: \(ipaURL.lastPathComponent)")
        
        Task {
            do {
                try await AppInstaller.shared.install(ipaURL: ipaURL) { msg, percent in
                    Task { @MainActor in
                        appendLog("[\(percent)%] \(msg)")
                    }
                }
                await MainActor.run {
                    appendLog("✅ 安裝完成！")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    appendLog("❌ 安裝失敗: \(error.localizedDescription)")
                    isTesting = false
                }
            }
        }
    }
    
    private func installOnDevice() {
        guard let ipaURL = selectedIPA else {
            appendLog("❌ 請先選擇 IPA 文件")
            return
        }
        guard !isTesting else {
            appendLog("⚠️ 安裝進行中，請勿重複點擊")
            return
        }
        isTesting = true
        appendLog("開始本機安裝: \(ipaURL.lastPathComponent)")
        
        Task {
            do {
                try await OnDeviceInstaller.shared.install(ipaURL: ipaURL) { msg, percent in
                    Task { @MainActor in
                        appendLog("[\(percent)%] \(msg)")
                    }
                }
                await MainActor.run {
                    appendLog("✅ 本機安裝完成！")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    appendLog("❌ 本機安裝失敗: \(error.localizedDescription)")
                    isTesting = false
                }
            }
        }
    }
    
    private func runProbeMatrix() {
        guard !isTesting else { return }
        isTesting = true
        let host = deviceIP
        appendLog("連線探針矩陣啟動（目標 \(host):62078）")
        Task.detached {
            ProbeMatrix.shared.run(host: host) { msg in
                DispatchQueue.main.async { appendLog(msg) }
            }
            DispatchQueue.main.async { isTesting = false }
        }
    }

    private func installViaMinimuxer() {
        guard let ipaURL = selectedIPA else {
            appendLog("❌ 請先選擇 IPA 文件")
            return
        }
        guard !isTesting else { return }
        isTesting = true
        appendLog("minimuxer 安裝啟動（安裝鏈改走 minimuxer 連線層）")
        Task {
            await MinimuxerInstaller.shared.install(ipaURL: ipaURL) { msg in
                DispatchQueue.main.async { appendLog(msg) }
            }
            await MainActor.run { isTesting = false }
        }
    }

    private func runSelfUsbmuxd() {
        guard !isTesting else { return }
        isTesting = true
        let host = deviceIP
        appendLog("自研 usbmuxd 啟動（手寫 mux 協議，直連 \(host):62078）")
        Task.detached {
            SelfUsbmuxdTester.shared.run(host: host) { msg in
                DispatchQueue.main.async { appendLog(msg) }
            }
            DispatchQueue.main.async { isTesting = false }
        }
    }

    private func runMinimuxerMode() {
        guard !isTesting else { return }
        isTesting = true
        appendLog("minimuxer 模式啟動（0.6.4 本體連線層）")
        Task {
            await MinimuxerModeTester.shared.run { msg in
                DispatchQueue.main.async { appendLog(msg) }
            }
            await MainActor.run { isTesting = false }
        }
    }

    private func toggleEMProxy() {
        guard !isTesting else { return }
        isTesting = true
        appendLog(EMProxyController.shared.isRunning ? "EMProxy 停止（測試 App 宿主）" : "EMProxy 啟動（測試 App 宿主，綁 127.0.0.1:51820）")
        Task {
            await EMProxyController.shared.toggle { msg in
                DispatchQueue.main.async { appendLog(msg) }
            }
            await MainActor.run { isTesting = false }
        }
    }

    private func probeExternalMuxer() {
        guard !isTesting else { return }
        isTesting = true
        let host = deviceIP
        appendLog("外部 muxer 探測啟動（127.0.0.1:27015 的 usbmuxd 服務；對照直連 \(host):62078）")
        Task.detached {
            ExternalMuxerProbe.shared.run(directHost: host) { msg in
                DispatchQueue.main.async { appendLog(msg) }
            }
            DispatchQueue.main.async { isTesting = false }
        }
    }

    private func dumpMISymbols() {
        guard !isTesting else { return }
        isTesting = true
        appendLog("開始探測 MobileInstallation 符號...")
        
        Task {
            await OnDeviceInstaller.shared.dumpSymbols { msg, percent in
                Task { @MainActor in
                    appendLog("[\(percent)%] \(msg)")
                }
            }
            await MainActor.run {
                isTesting = false
            }
        }
    }
}

// 文件選擇器（照抄 PaxStore 的實現）
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                DispatchQueue.main.async {
                    self.onPick(url)
                }
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 用戶取消，不做任何事
        }
    }
}
