import Foundation
import Darwin

/// 自研 usbmuxd（SELF-USBMUXD）：純 Swift 手寫，**不呼叫 idevice／minimuxer 的任何連線 API**。
/// 講的是裝置內建 muxer 的 B 層協議（mux 協議）＋其上 C 層 lockdown：
///   TCP → version 交換 → (v2) SETUP → mux-TCP 邏輯流（SYN/SYN-ACK/ACK）→ lockdown QueryType → GetValue。
/// 規格與逐欄位源碼出處：~/workspace/pht-usbmuxer/protocol-spec.md
/// （對照 usbmuxd/src/device.c 的 daemon 裝置側實作；A 層 plist Connect 是客戶端↔主機 muxer 的協議，
///   直連裝置 62078 的對端是裝置 muxer、講 B 層——idevice 直連把 C 層當第一句話送就是死在這裡。）
/// 日誌：U 前綴逐筆行（比照鑑識格式）只進詳細日誌；結論以 ✅/❌ 敘事行另發（主頁可見）。
final class SelfUsbmuxdTester {
    static let shared = SelfUsbmuxdTester()
    private init() {}

    typealias LogFn = (String) -> Void

    private struct UFail: Error {
        let step: String
        let text: String
    }

    // 連線狀態（單一背景執行緒同步跑，無並發）
    private var fd: Int32 = -1
    private var t0: UInt64 = 0
    private var tcpSent = 0
    private var tcpRecv = 0
    private var log: LogFn = { _ in }

    // B 層狀態
    private var headerSize = 8            // version 協商前／v1 為 8；v2 為 16
    private var devTxSeq: UInt16 = 0      // 裝置級送出計數（v2 頭）
    private var devRxSeqEcho: UInt16 = 0  // 上次收到包的 rx_seq（echo，daemon 行為）
    private var streamSport: UInt16 = 1   // find_sport 首號（device.c next_sport=1）
    private var streamTxSeq: UInt32 = 0   // 邏輯流送出序號（SYN 後 =1，之後 += payload）
    private var streamTxAck: UInt32 = 0   // 邏輯流確認序號（SYN 後 =1，之後 += 收到的 payload）
    private var streamRxBuf = Data()      // 已解出的 lockdown 流位元組（待切 C 層框架）

    private let label = "PaxHeartbeatTest"

    // MARK: - 主流程

    func run(host: String, port: UInt16 = 62078, log: @escaping LogFn) {
        self.log = log
        t0 = DispatchTime.now().uptimeNanoseconds
        tcpSent = 0
        tcpRecv = 0
        headerSize = 8
        devTxSeq = 0
        devRxSeqEcho = 0
        streamTxSeq = 0
        streamTxAck = 0
        streamRxBuf = Data()
        do {
            try openTcp(host: host, port: port)
            let major = try versionExchange()
            if major >= 2 {
                headerSize = 16
                try sendSetup()
            }
            try openStream(dport: 62078)
            let type = try lockdownQueryType()
            log("U < Type \(type)")
            let version = try lockdownGetValue(key: "ProductVersion")
            log("U < GetValue ProductVersion=\(version)")
            let udid = try lockdownGetValue(key: "UniqueDeviceID")
            log("U < GetValue UniqueDeviceID=\(udid)")
            log("U CLOSE life=\(ms())ms")
            closeFd()
            log("✅ 自研 usbmuxd GetValue 成功：UDID \(udid)（iOS \(version)）")
        } catch let f as UFail {
            log("U X \(f.step) err=\(f.text) sent=\(tcpSent) recv=\(tcpRecv) life=\(ms())ms")
            closeFd()
            log("❌ 自研 usbmuxd 失敗：\(f.step) \(f.text)")
        } catch {
            log("U X err=\(error.localizedDescription) sent=\(tcpSent) recv=\(tcpRecv) life=\(ms())ms")
            closeFd()
            log("❌ 自研 usbmuxd 失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - TCP 基礎（比照 ProbeMatrix 的非阻塞 connect＋poll 讀寫）

    private func openTcp(host: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { throw UFail(step: "OPEN", text: errnoText(errno)) }
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
                if soErr != 0 { throw UFail(step: "OPEN", text: errnoText(soErr)) }
            } else {
                throw UFail(step: "OPEN", text: errnoText(errno))
            }
        }
        log("U OPEN \(host):\(port) @\(ms())ms")
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
            if now >= deadline { throw UFail(step: step, text: errnoText(ETIMEDOUT)) }
            let remainMs = Int((deadline - now) / 1_000_000)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(remainMs, 1)))
            if pr == 0 { throw UFail(step: step, text: errnoText(ETIMEDOUT)) }
            if pr < 0 {
                if errno == EINTR { continue }
                throw UFail(step: step, text: errnoText(errno))
            }
            let want = min(buf.count, n - out.count)
            let got = recv(fd, &buf, want, 0)
            if got > 0 {
                out.append(contentsOf: buf[0..<got])
                tcpRecv += got
                continue
            }
            if got == 0 { throw UFail(step: step, text: "EOF（對方關閉）") }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                if soErr != 0 { throw UFail(step: step, text: errnoText(soErr)) }
                continue
            }
            throw UFail(step: step, text: errnoText(e))
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
                if poll(&pfd, 1, 5000) <= 0 { throw UFail(step: step, text: errnoText(ETIMEDOUT)) }
                continue
            }
            throw UFail(step: step, text: errnoText(e))
        }
    }

    // MARK: - B 層 mux 封包（device.c send_packet／device_data_input）

    /// 組一包 mux 封包：頭（8 或 16B，整數 BE）＋子頭＋payload。v2 時填 magic 與裝置級 seq 並自增。
    private func buildPacket(proto: UInt32, body: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        let total = headerSize + body.count
        out += be32(proto)
        out += be32(UInt32(total))
        if headerSize == 16 {
            out += be32(0xfeedface)
            out += be16(devTxSeq)
            out += be16(devRxSeqEcho)
            devTxSeq &+= 1
        }
        out += body
        return out
    }

    /// 讀一整包 mux 封包，回 (protocol, 頭後本體)。先讀 8B 公共前綴（protocol+length），再依 length 讀滿；
    /// v2 時本體自第 16B 起，並更新 rx_seq echo。
    private func readPacket(step: String) throws -> (proto: UInt32, body: [UInt8], total: Int) {
        let head = try readExact(8, step: step)
        let proto = be32read(head, 0)
        let length = Int(be32read(head, 4))
        if length < headerSize || length > 1_000_000 {
            throw UFail(step: step, text: "BadMuxLength \(length)")
        }
        var rest = [UInt8]()
        if length > 8 {
            rest = try readExact(length - 8, step: step)
        }
        let full = head + rest
        var bodyStart = 8
        if headerSize == 16 {
            if length < 16 { throw UFail(step: step, text: "BadMuxLength \(length)") }
            devRxSeqEcho = be16read(full, 14)
            bodyStart = 16
        }
        return (proto, Array(full[bodyStart..<length]), length)
    }

    /// version 交換（device.c device_add／device_version_input）：offer 2.0（20B、頭長 8），
    /// 讀回裝置版本；回傳 major。只接受 1 或 2。
    private func versionExchange() throws -> UInt32 {
        var body = [UInt8]()
        body += be32(2)   // major
        body += be32(0)   // minor
        body += be32(0)   // padding
        let pkt = buildPacket(proto: 0, body: body)
        try sendAll(pkt, step: "VERSION")
        log("U > VERSION offer=2.0 \(pkt.count)B @\(ms())ms")
        let r = try readPacket(step: "VERSION")
        if r.proto != 0 || r.body.count < 12 {
            throw UFail(step: "VERSION", text: "UnexpectedPacket proto=\(r.proto) len=\(r.total)")
        }
        let major = be32read(r.body, 0)
        let minor = be32read(r.body, 4)
        log("U < VERSION major=\(major) minor=\(minor) \(r.total)B @\(ms())ms")
        if major != 1 && major != 2 {
            throw UFail(step: "VERSION", text: "BadMuxVersion \(major).\(minor)")
        }
        return major
    }

    /// SETUP 包（僅 v2，device.c:583-585）：protocol=2、payload 單 byte 0x07；
    /// 送出時裝置級 tx_seq=0、rx_seq=0xFFFF（device.c:222-225）。
    private func sendSetup() throws {
        devTxSeq = 0
        devRxSeqEcho = 0xFFFF
        let pkt = buildPacket(proto: 2, body: [0x07])
        try sendAll(pkt, step: "SETUP")
        log("U > SETUP \(pkt.count)B @\(ms())ms")
    }

    // MARK: - B 層邏輯流（mux-TCP，device.c device_start_connect／device_tcp_input）

    private func tcpHeader(sport: UInt16, dport: UInt16, seq: UInt32, ack: UInt32, flags: UInt8) -> [UInt8] {
        var th = [UInt8]()
        th += be16(sport)
        th += be16(dport)
        th += be32(seq)
        th += be32(ack)
        th.append(0x50)          // th_off = 5（20B）
        th.append(flags)
        th += be16(512)          // win = tx_win(131072) >> 8
        th += be16(0)            // sum
        th += be16(0)            // urp
        return th
    }

    /// 開流：送 SYN（sport=1、seq=0），等 flags 恰 SYN|ACK 的回包，送純 ACK，完成三方握手。
    private func openStream(dport: UInt16) throws {
        streamSport = 1
        streamTxSeq = 0
        streamTxAck = 0
        let syn = buildPacket(proto: 6, body: tcpHeader(sport: streamSport, dport: dport, seq: 0, ack: 0, flags: 0x02))
        try sendAll(syn, step: "SYN")
        log("U > SYN sport=\(streamSport) dport=\(dport) \(syn.count)B @\(ms())ms")
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while true {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw UFail(step: "SYNACK", text: errnoText(ETIMEDOUT))
            }
            let r = try readPacket(step: "SYNACK")
            if r.proto != 6 || r.body.count < 20 { continue }
            let th = r.body
            let flags = th[13]
            if flags & 0x04 != 0 {
                let reason = th.count > 20 ? String(bytes: th[20...], encoding: .utf8) ?? "" : ""
                throw UFail(step: "SYNACK", text: "MuxConnRefused RST \(reason)")
            }
            if flags == 0x12 {
                let devSeq = be32read(th, 4)
                log("U < SYNACK seq=\(devSeq) ack=\(be32read(th, 8)) \(r.total)B @\(ms())ms")
                streamTxSeq = 1   // SYN 佔 1（device.c:695）
                streamTxAck = 1   // 裝置 SYN 的 seq 視為 0、佔 1（device.c:696）
                let ack = buildPacket(proto: 6, body: tcpHeader(sport: streamSport, dport: dport, seq: streamTxSeq, ack: streamTxAck, flags: 0x10))
                try sendAll(ack, step: "ACK")
                log("U > ACK \(ack.count)B @\(ms())ms")
                return
            }
            // 其他 flags 組合在 CONNECTING 態一律視為拒絕（device.c:684-694）
            throw UFail(step: "SYNACK", text: "UnexpectedFlags 0x\(String(flags, radix: 16))")
        }
    }

    /// 送一段流 payload（flags=TH_ACK，seq 為送出前值，送後推進；device.c:497-505）。
    private func sendStream(_ payload: [UInt8], step: String) throws {
        let pkt = buildPacket(proto: 6, body: tcpHeader(sport: streamSport, dport: 62078, seq: streamTxSeq, ack: streamTxAck, flags: 0x10) + payload)
        try sendAll(pkt, step: step)
        streamTxSeq &+= UInt32(payload.count)
    }

    /// 讀下一段流 payload：跳過純 ACK 包；收到資料推進 ack 並立即回 ACK（device.c:719-721 的即時 ACK）。
    private func recvStream(step: String) throws -> [UInt8] {
        while true {
            let r = try readPacket(step: step)
            if r.proto != 6 || r.body.count < 20 { continue }
            let th = r.body
            let flags = th[13]
            if flags & 0x04 != 0 {
                let reason = th.count > 20 ? String(bytes: th[20...], encoding: .utf8) ?? "" : ""
                throw UFail(step: step, text: "MuxReset \(reason)")
            }
            if flags != 0x10 {
                throw UFail(step: step, text: "Closed flags=0x\(String(flags, radix: 16))")
            }
            let payload = Array(th[20...])
            if payload.isEmpty { continue }
            streamTxAck &+= UInt32(payload.count)
            let ack = buildPacket(proto: 6, body: tcpHeader(sport: streamSport, dport: 62078, seq: streamTxSeq, ack: streamTxAck, flags: 0x10))
            try sendAll(ack, step: step)
            return payload
        }
    }

    // MARK: - C 層 lockdown（property_list_service.c／lockdown.c）

    /// 送一則 lockdown 訊息：4B BE 長度（僅本體）＋XML plist。
    private func sendLockdown(_ dict: [String: Any], step: String, what: String) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        var frame = be32(UInt32(body.count))
        frame += [UInt8](body)
        try sendStream(frame, step: step)
        log("U > \(what) \(frame.count)B @\(ms())ms")
    }

    /// 讀一則 lockdown 訊息：自流緩衝切 4B BE 長度＋本體，不足則再收一段流 payload。
    private func recvLockdown(step: String, what: String) throws -> [String: Any] {
        while true {
            if streamRxBuf.count >= 4 {
                let len = Int(be32read([UInt8](streamRxBuf), 0))
                if len <= 0 || len > 4_000_000 {
                    throw UFail(step: step, text: "BadLockdownLength \(len)")
                }
                if streamRxBuf.count >= 4 + len {
                    let body = streamRxBuf.subdata(in: 4..<(4 + len))
                    streamRxBuf.removeSubrange(0..<(4 + len))
                    log("U < \(what) \(4 + len)B @\(ms())ms")
                    let obj = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
                    guard let dict = obj as? [String: Any] else {
                        throw UFail(step: step, text: "BadPlistResponse")
                    }
                    return dict
                }
            }
            let seg = try recvStream(step: step)
            streamRxBuf.append(contentsOf: seg)
        }
    }

    private func lockdownQueryType() throws -> String {
        try sendLockdown(["Label": label, "Request": "QueryType"], step: "QueryType", what: "QueryType")
        let resp = try recvLockdown(step: "QueryType", what: "QueryType")
        guard let type = resp["Type"] as? String else {
            throw UFail(step: "QueryType", text: "MissingType \(resp)")
        }
        return type
    }

    private func lockdownGetValue(key: String) throws -> String {
        try sendLockdown(["Label": label, "Key": key, "Request": "GetValue"], step: "GetValue", what: "GetValue:\(key)")
        let resp = try recvLockdown(step: "GetValue", what: "GetValue:\(key)")
        if let err = resp["Error"] as? String {
            throw UFail(step: "GetValue", text: "LockdownError \(err)")
        }
        guard let value = resp["Value"] as? String else {
            throw UFail(step: "GetValue", text: "MissingValue \(resp)")
        }
        return value
    }

    // MARK: - 小工具（位元組序／錯誤原文／計時，比照 ProbeMatrix）

    private func be16(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    private func be16read(_ b: [UInt8], _ off: Int) -> UInt16 {
        (UInt16(b[off]) << 8) | UInt16(b[off + 1])
    }

    private func be32read(_ b: [UInt8], _ off: Int) -> UInt32 {
        (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16) | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3])
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
