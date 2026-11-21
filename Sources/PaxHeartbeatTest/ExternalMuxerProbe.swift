import Foundation
import Darwin

/// 外部 muxer 探測（按鈕 12）：探本機 127.0.0.1:27015 是否有 usbmuxd 服務在聽。
/// 背景：牛蛙助手的 NBCoreText 含 usbmuxd listener（服務端）符號，懷疑它重裝運行時
/// 會在本機開一個 usbmuxd 服務供其他 App 連——若在，我們的第一交換或許能借它的路活
/// （自己的連線形狀：直連／minimuxer 代理／EMProxy／自研 B 層，全死在第一交換）。
/// 講 A 層 plist 協議（客戶端 ↔ 主機 muxer；規格 ~/workspace/pht-usbmuxer/protocol-spec.md §1）：
///   連線 1：ListDevices（16B LE 頭＋XML plist）→ 解析 DeviceID／SerialNumber
///   連線 2：Connect（DeviceID＋PortNumber=htons(62078)=32498）→ 同流送 lockdown GetValue
///   連線 3（對照）：直連裝置 62078 裸送同一個 GetValue（C 層當第一句話，同 idevice 直連形狀）
/// 判讀基準：27015 ListDevices 有回覆＋Connect 後 GetValue recv>0＝外部 muxer 借路成立；
///           ListDevices 無回覆＝服務不在 27015（落點另尋，或牛蛙根本沒開服務）。
/// 日誌：N 前綴逐筆行只進詳細日誌；主頁只留三行結論（muxer 有無回應／借路成敗／直連對照死活）。
final class ExternalMuxerProbe {
    static let shared = ExternalMuxerProbe()
    private init() {}

    typealias LogFn = (String) -> Void

    private struct NFail: Error {
        let step: String
        let text: String
    }

    private var fd: Int32 = -1
    private var t0: UInt64 = 0
    private var tcpSent = 0   // 本條連線計數（openTcp 時歸零）
    private var tcpRecv = 0
    private var tag: UInt32 = 0
    private var log: LogFn = { _ in }

    private let label = "PaxHeartbeatTest"
    private let muxerHost = "127.0.0.1"
    private let muxerPort: UInt16 = 27015
    private let lockdownPort: UInt16 = 62078

    // MARK: - 主流程（一次按下三段依序做完）

    func run(directHost: String, log: @escaping LogFn) {
        self.log = log
        t0 = DispatchTime.now().uptimeNanoseconds
        tag = 0

        // 第一段：ListDevices（連線 1）
        var deviceID: UInt32? = nil
        let muxerLine: String
        do {
            let found = try listDevices()
            deviceID = found.id
            if let id = found.id {
                muxerLine = "✅ 外部 muxer 有回應：127.0.0.1:27015 ListDevices 拿到裝置（DeviceID \(id)\(found.serial.map { "、序號 \($0)" } ?? "")）"
            } else {
                muxerLine = "⚠️ 外部 muxer 有回應但無裝置：127.0.0.1:27015 ListDevices 未見裝置"
            }
        } catch let f as NFail {
            log("N X ListDevices err=\(f.text) sent=\(tcpSent) recv=\(tcpRecv) life=\(ms())ms")
            muxerLine = "❌ 外部 muxer 無回應：127.0.0.1:27015 ListDevices 失敗（\(f.step) \(f.text)）"
        } catch {
            muxerLine = "❌ 外部 muxer 無回應：127.0.0.1:27015 ListDevices 失敗（\(error.localizedDescription)）"
        }
        closeFd()
        log(muxerLine)

        // 第二段：Connect＋GetValue 借路（連線 2；無裝置可連就跳過）
        let borrowLine: String
        if let id = deviceID {
            do {
                let value = try connectAndGetValue(deviceID: id)
                borrowLine = "✅ 外部 muxer 借路成功：Connect 後 GetValue ProductVersion=\(value)"
            } catch let f as NFail {
                log("N X borrow err=\(f.text) sent=\(tcpSent) recv=\(tcpRecv) life=\(ms())ms")
                borrowLine = "❌ 外部 muxer 借路失敗：\(f.step) \(f.text)"
            } catch {
                borrowLine = "❌ 外部 muxer 借路失敗：\(error.localizedDescription)"
            }
            closeFd()
        } else {
            borrowLine = "⏭ 外部 muxer 借路未試：ListDevices 未拿到裝置，無從 Connect"
        }
        log(borrowLine)

        // 第三段：直連對照（連線 3）
        log(directControl(host: directHost))
    }

    // MARK: - 第一段：ListDevices

    private func listDevices() throws -> (id: UInt32?, serial: String?) {
        try openTcp(host: muxerHost, port: muxerPort, what: "muxer")
        let resp = try roundTripPlist(basePlist("ListDevices"), step: "ListDevices", what: "ListDevices")
        guard let rawList = resp["DeviceList"] as? [Any] else {
            log("N < ListDevices 無 DeviceList，keys=\(resp.keys.sorted()) @\(ms())ms")
            return (nil, nil)
        }
        log("N < ListDevices DeviceList count=\(rawList.count) @\(ms())ms")
        var firstID: UInt32? = nil
        var firstSerial: String? = nil
        for (i, item) in rawList.enumerated() {
            guard let dev = item as? [String: Any] else { continue }
            let props = dev["Properties"] as? [String: Any]
            let did = (dev["DeviceID"] as? NSNumber)?.uint32Value
                ?? (props?["DeviceID"] as? NSNumber)?.uint32Value
            let ser = props?["SerialNumber"] as? String
            let ctype = (props?["ConnectionType"] as? String) ?? "?"
            log("N < Device[\(i)] DeviceID=\(did.map(String.init) ?? "?") SerialNumber=\(ser ?? "?") ConnectionType=\(ctype)")
            if i == 0 { firstID = did; firstSerial = ser }
        }
        return (firstID, firstSerial)
    }

    // MARK: - 第二段：Connect＋同流 GetValue

    private func connectAndGetValue(deviceID: UInt32) throws -> String {
        try openTcp(host: muxerHost, port: muxerPort, what: "muxer")
        var req = basePlist("Connect")
        req["DeviceID"] = NSNumber(value: deviceID)
        // PortNumber 存 htons(port)：62078 → 32498（規格 §1.4，daemon 端 ntohs 換回）
        req["PortNumber"] = NSNumber(value: lockdownPort.byteSwapped)
        let resp = try roundTripPlist(req, step: "Connect", what: "Connect DeviceID=\(deviceID) PortNumber=\(lockdownPort.byteSwapped)")
        let number = (resp["Number"] as? NSNumber)?.intValue
        log("N < Connect Result Number=\(number.map(String.init) ?? "?") keys=\(resp.keys.sorted()) @\(ms())ms")
        guard number == 0 else {
            throw NFail(step: "Connect", text: "MuxResult \(number.map(String.init) ?? "未知")（0=OK 2=BADDEV 3=CONNREFUSED 6=BADVERSION）")
        }
        // Connect 成功後同一條流已橋接到 lockdown：直接送 C 層 GetValue（4B BE＋XML）
        let (dict, _) = try lockdownGetValue(key: "ProductVersion", step: "GetValue")
        if let v = dict?["Value"] as? String { return v }
        throw NFail(step: "GetValue", text: "回覆無 Value（keys=\(dict?.keys.sorted() ?? [])）")
    }

    // MARK: - 第三段：直連對照

    /// 對裝置 62078 裸送同一個 GetValue（C 層當第一句話，同 idevice 直連／鑑識 C 行的形狀）。
    /// 回主頁結論行；逐筆在 N 行，失敗另記 N X（sent／recv／life）。
    private func directControl(host: String) -> String {
        let d0 = ms()
        do {
            try openTcp(host: host, port: lockdownPort, what: "direct")
            let (dict, _) = try lockdownGetValue(key: "ProductVersion", step: "direct GetValue")
            closeFd()
            if let v = dict?["Value"] as? String {
                return "✅ 直連對照有回覆：\(host):62078 GetValue ProductVersion=\(v)"
            }
            return "⚠️ 直連對照有 bytes 回覆但無 Value：\(host):62078"
        } catch let f as NFail {
            log("N X direct err=\(f.text) sent=\(tcpSent) recv=\(tcpRecv) life=\(ms() - d0)ms")
            closeFd()
            return "❌ 直連對照無回覆：\(host):62078 \(f.step) \(f.text)"
        } catch {
            closeFd()
            return "❌ 直連對照無回覆：\(host):62078 \(error.localizedDescription)"
        }
    }

    // MARK: - A 層 plist 封包（16B LE 頭＋XML；usbmuxd-proto.h／libusbmuxd.c）

    /// create_plist_message（libusbmuxd.c:796-811）的欄位組：選填欄位 muxer 端僅存檔、不用於放行。
    private func basePlist(_ messageType: String) -> [String: Any] {
        return [
            "MessageType": messageType,
            "ClientVersionString": "libusbmuxd 2.0.2",
            "ProgName": "PaxHeartbeatTest",
            "kLibUSBMuxVersion": NSNumber(value: 3),
            "BundleID": "com.pax.heartbeattest",
        ]
    }

    private func roundTripPlist(_ dict: [String: Any], step: String, what: String) throws -> [String: Any] {
        try sendPlistPacket(dict, step: step, what: what)
        return try recvPlistPacket(step: step, what: what)
    }

    private func sendPlistPacket(_ dict: [String: Any], step: String, what: String) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        tag &+= 1
        var pkt = le32(UInt32(16 + body.count))
        pkt += le32(1)   // version＝proto v1
        pkt += le32(8)   // message＝MESSAGE_PLIST（命令在 plist 的 MessageType 裡）
        pkt += le32(tag)
        pkt += [UInt8](body)
        try sendAll(pkt, step: step)
        log("N > \(what) \(pkt.count)B tag=\(tag) @\(ms())ms")
    }

    private func recvPlistPacket(step: String, what: String) throws -> [String: Any] {
        let head = try readExact(16, step: step)
        let length = Int(le32read(head, 0))
        let version = le32read(head, 4)
        let message = le32read(head, 8)
        let rtag = le32read(head, 12)
        if length < 16 || length > 4_000_000 {
            throw NFail(step: step, text: "BadPacketLength \(length)")
        }
        let body = try readExact(length - 16, step: step)
        log("N < \(what) \(length)B version=\(version) message=\(message) tag=\(rtag) @\(ms())ms")
        let obj = try PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil)
        guard let dict = obj as? [String: Any] else {
            throw NFail(step: step, text: "BadPlistResponse 先頭=\(hexPrefix(body, 32))")
        }
        return dict
    }

    // MARK: - C 層 lockdown 框架（4B BE 長度＋XML；property_list_service.c）

    /// 在目前 fd 上送一則 GetValue 並讀一則回覆。任何 bytes 到達都先記 N < 行；
    /// 回覆不是 plist dict 時回 (nil, 框架位元組數)，由呼叫端決定怎麼記。
    private func lockdownGetValue(key: String, step: String) throws -> (dict: [String: Any]?, frameBytes: Int) {
        let req: [String: Any] = ["Label": label, "Key": key, "Request": "GetValue"]
        let body = try PropertyListSerialization.data(fromPropertyList: req, format: .xml, options: 0)
        var frame = be32(UInt32(body.count))
        frame += [UInt8](body)
        try sendAll(frame, step: step)
        log("N > GetValue:\(key) \(frame.count)B @\(ms())ms")
        let head = try readExact(4, step: step)
        let len = Int(be32read(head, 0))
        if len <= 0 || len > 4_000_000 {
            log("N < GetValue head=\(hexPrefix(head, 4)) 長度不合 len=\(len) recv=\(tcpRecv) @\(ms())ms")
            throw NFail(step: step, text: "BadLockdownLength \(len)")
        }
        let payload = try readExact(len, step: step)
        log("N < GetValue recv=\(4 + len)B @\(ms())ms")
        let obj = try? PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil)
        guard let dict = obj as? [String: Any] else {
            log("N < GetValue 回覆非 plist dict，先頭位元組=\(hexPrefix(payload, 32))")
            return (nil, 4 + len)
        }
        if let err = dict["Error"] as? String {
            log("N < GetValue Error=\(err)")
        }
        return (dict, 4 + len)
    }

    // MARK: - TCP 基礎（比照 SelfUsbmuxd／ProbeMatrix 的非阻塞 connect＋poll 讀寫）

    private func openTcp(host: String, port: UInt16, what: String) throws {
        tcpSent = 0
        tcpRecv = 0
        fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { throw NFail(step: "OPEN", text: errnoText(errno)) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 {
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, 3000)
                var soErr: Int32 = ETIMEDOUT
                if pr > 0 {
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                }
                if soErr != 0 { throw NFail(step: "OPEN", text: errnoText(soErr)) }
            } else {
                throw NFail(step: "OPEN", text: errnoText(errno))
            }
        }
        log("N OPEN \(what) \(host):\(port) @\(ms())ms")
    }

    private func closeFd() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// 讀滿 n bytes（poll 守 5 秒）；EOF 記對方關閉、逾時記 TimedOut。
    private func readExact(_ n: Int, step: String) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(n)
        var buf = [UInt8](repeating: 0, count: 16384)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while out.count < n {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { throw NFail(step: step, text: errnoText(ETIMEDOUT)) }
            let remainMs = Int((deadline - now) / 1_000_000)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(remainMs, 1)))
            if pr == 0 { throw NFail(step: step, text: errnoText(ETIMEDOUT)) }
            if pr < 0 {
                if errno == EINTR { continue }
                throw NFail(step: step, text: errnoText(errno))
            }
            let want = min(buf.count, n - out.count)
            let got = recv(fd, &buf, want, 0)
            if got > 0 {
                out.append(contentsOf: buf[0..<got])
                tcpRecv += got
                continue
            }
            if got == 0 { throw NFail(step: step, text: "EOF（對方關閉）") }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                if soErr != 0 { throw NFail(step: step, text: errnoText(soErr)) }
                continue
            }
            throw NFail(step: step, text: errnoText(e))
        }
        return out
    }

    private func sendAll(_ bytes: [UInt8], step: String) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { bp in
                send(fd, bp.baseAddress! + off, bytes.count - off, 0)
            }
            if n > 0 { off += n; tcpSent += n; continue }
            let e = errno
            if n < 0 && e == EINTR { continue }
            if n < 0 && (e == EAGAIN || e == EWOULDBLOCK) {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, 5000) <= 0 { throw NFail(step: step, text: errnoText(ETIMEDOUT)) }
                continue
            }
            throw NFail(step: step, text: errnoText(e))
        }
    }

    // MARK: - 小工具（位元組序／錯誤原文／計時，比照 SelfUsbmuxd）

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private func le32read(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private func be32read(_ b: [UInt8], _ off: Int) -> UInt32 {
        (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16) | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3])
    }

    private func hexPrefix(_ b: [UInt8], _ n: Int) -> String {
        b.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func ms() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }

    private func errnoText(_ e: Int32) -> String {
        let name: String
        switch e {
        case ECONNRESET: name = "ConnectionReset"
        case EPIPE: name = "BrokenPipe"
        case ECONNREFUSED: name = "ConnectionRefused"
        case ECONNABORTED: name = "ConnectionAborted"
        case ETIMEDOUT: name = "TimedOut"
        case ENOTCONN: name = "NotConnected"
        default: name = "Socket"
        }
        return "\(name) os\(e) \"\(String(cString: strerror(e)))\""
    }
}
