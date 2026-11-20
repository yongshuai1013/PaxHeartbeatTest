import SwiftUI
import UniformTypeIdentifiers

/// IPA 簽名頁面（iOS 原生風格）
struct SigningView: View {
    @State private var selectedIPA: URL?
    @State private var bundleID = ""
    @State private var appName = ""
    @State private var isSigning = false
    @State private var log = ""
    @State private var showIPAPicker = false
    @State private var progress: Double = 0
    
    var body: some View {
        Form {
            // IPA 選擇
            Section(header: Text("IPA 文件")) {
                HStack {
                    Text(selectedIPA?.lastPathComponent ?? "未選擇")
                        .foregroundColor(selectedIPA == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button("選擇") {
                        showIPAPicker = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            // 簽名配置
            Section(header: Text("簽名配置")) {
                HStack {
                    Text("Bundle ID")
                    Spacer()
                    TextField("com.example.app", text: $bundleID)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                HStack {
                    Text("應用名稱")
                    Spacer()
                    TextField("MyApp", text: $appName)
                        .multilineTextAlignment(.trailing)
                }
            }
            
            // 簽名按鈕
            Section {
                Button(action: startSigning) {
                    HStack {
                        Spacer()
                        if isSigning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("開始簽名")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(selectedIPA == nil || isSigning)
            }
            
            // 進度
            if isSigning || progress > 0 {
                Section(header: Text("進度")) {
                    ProgressView(value: progress, total: 100)
                    Text("\(Int(progress))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // 日誌
            Section(header: Text("日誌")) {
                ScrollView {
                    Text(log.isEmpty ? "暫無日誌" : log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 150)
            }
        }
        .navigationTitle("IPA 簽名")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showIPAPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleIPASelection(result)
        }
    }
    
    private func handleIPASelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 複製到沙盒
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dest = docs.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                selectedIPA = dest
                // 自動填 Bundle ID（從文件名猜）
                if bundleID.isEmpty {
                    let name = dest.deletingPathExtension().lastPathComponent
                    bundleID = "com.pax.\(name.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression))"
                }
                if appName.isEmpty {
                    appName = dest.deletingPathExtension().lastPathComponent
                }
                appendLog("已選擇: \(dest.lastPathComponent)")
            } catch {
                appendLog("複製失敗: \(error.localizedDescription)")
            }
        case .failure(let error):
            appendLog("選擇失敗: \(error.localizedDescription)")
        }
    }
    
    private func startSigning() {
        guard let ipa = selectedIPA else { return }
        isSigning = true
        progress = 0
        log = ""
        
        appendLog("開始簽名: \(ipa.lastPathComponent)")
        appendLog("Bundle ID: \(bundleID)")
        
        // TODO: 接入真正的簽名邏輯（Apple ID 登入、證書、重簽）
        // 目前先做 UI 框架
        
        Task {
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    progress = Double(i * 10)
                    appendLog("步驟 \(i)/10...")
                }
            }
            await MainActor.run {
                isSigning = false
                appendLog("✅ 簽名完成（演示模式，後端未接）")
            }
        }
    }
    
    private func appendLog(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: Date())
        log += "[\(time)] \(msg)\n"
    }
}

// 預覽
struct SigningView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SigningView()
        }
    }
}
