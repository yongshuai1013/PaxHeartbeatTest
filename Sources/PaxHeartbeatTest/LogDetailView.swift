import SwiftUI

/// 詳細日誌頁：完整逐筆紀錄（C 行、P 行全量，一字不漏），可滾動；
/// 「下載日誌」把完整內容寫成 .txt 並叫出系統分享面板（存檔案 App／直接傳出）。
struct LogDetailView: View {
    @ObservedObject var store: LogStore
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            Text(store.full.isEmpty ? "（尚無紀錄）" : store.full)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("詳細日誌")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("下載日誌") {
                    let url = exportURL()
                    if FileManager.default.fileExists(atPath: url.path) {
                        shareItems = [url]
                    } else {
                        shareItems = [store.full]
                    }
                    showShare = true
                }
                .disabled(store.full.isEmpty)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
    }

    /// 匯出內容與詳細頁顯示的完整日誌一致（同一份 store.full）。
    private func exportURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaxHeartbeatTest-full-log.txt")
        try? store.full.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// 系統分享面板（存進檔案 App 或直接傳出）。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
