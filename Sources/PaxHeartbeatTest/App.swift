import SwiftUI
import UniformTypeIdentifiers
import IDevice

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
/// summary 只收摘要行（主頁用）——按鈕操作、進度、✅/❌ 結論、連線 OPEN／X（死亡）／CLOSE、
/// 探針標題與 OK 結論；逐筆的 >（送出）／<（回覆）明細行只進 full。
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

    /// C 行（鑑識）與 P 行（探針）的逐筆明細不上主頁；其餘皆摘要。
    static func isSummaryLine(_ msg: String) -> Bool {
        if msg.range(of: "^[CP][0-9]+ [><]", options: .regularExpression) != nil {
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
                Text("PROBE MATRIX + LOG UI")
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

                // 日誌輸出（摘要：逐筆 > < 明細只在詳細頁）
                HStack {
                    Text("日誌（摘要）")
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
                appendLog("=== PROBE MATRIX + LOG UI（探針矩陣＋日誌分頁版）===")
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
            }
            .sheet(isPresented: $showIPAPicker) {
                DocumentPicker(contentTypes: [.data]) { url in
                    selectedIPA = url
                    appendLog("已選擇 IPA: \(url.lastPathComponent)")
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
