import Foundation
import Darwin

/// 連線探針矩陣（PROBE MATRIX）：原始 BSD socket 直連 10.7.0.1:62078，繞開 idevice，
/// 一次量清 RST 挑的是連線本身、首送時序、還是內容形狀。
/// P1 空連線（只連不送）／P2 延遲 300ms 首送 GetValue／P3 @0ms 垃圾字節／P4 @0ms GetValue（對照組）。
final class ProbeMatrix {
    static let shared = ProbeMatrix()
    private init() {}

    typealias LogFn = (String) -> Void

    /// idevice v0.1.66 實際送出的 GetValue:ProductVersion 線格式（344B 變體，Label=PaxHeartbeatTest-AFC，
    /// 即按鈕 5 AFC 路徑的首幀）：4B BE 長度頭＋plist XML 本體。
    /// 來源：idevice/src/services/lockdown.rs:103-108（get_value 組 dict：Label／Request=GetValue／Key=ProductVersion）、
    /// idevice/src/lib.rs:347-352（send_plist：to_writer_xml 序列化＋BE 長度頭）。
    /// 已用 idevice Cargo.lock 的 plist 1.8.0 於本機複製驗證：body=340B、含頭總長=344B，
    /// 與鑑識場 C 行出現的 344B 一致（另一變體 Label=PaxHeartbeatTest 為 340B）。
    private static let getValueFrameB64 = "AAABVDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04Ij8+CjwhRE9DVFlQRSBwbGlzdCBQVUJMSUMgIi0vL0FwcGxlLy9EVEQgUExJU1QgMS4wLy9FTiIgImh0dHA6Ly93d3cuYXBwbGUuY29tL0RURHMvUHJvcGVydHlMaXN0LTEuMC5kdGQiPgo8cGxpc3QgdmVyc2lvbj0iMS4wIj4KPGRpY3Q+Cgk8a2V5PkxhYmVsPC9rZXk+Cgk8c3RyaW5nPlBheEhlYXJ0YmVhdFRlc3QtQUZDPC9zdHJpbmc+Cgk8a2V5PlJlcXVlc3Q8L2tleT4KCTxzdHJpbmc+R2V0VmFsdWU8L3N0cmluZz4KCTxrZXk+S2V5PC9rZXk+Cgk8c3RyaW5nPlByb2R1Y3RWZXJzaW9uPC9zdHJpbmc+CjwvZGljdD4KPC9wbGlzdD4="
    private static var getValueFrame: [UInt8] {
        Array(Data(base64Encoded: getValueFrameB64) ?? Data())
    }

    // MARK: - 主流程（背景執行緒上依序跑完四探針）

    func run(host: String, port: UInt16 = 62078, log: @escaping LogFn) {
        log("PROBE MATRIX 開始（目標 \(host):\(port)，四探針依序）")
        probe1Idle(host: host, port: port, log: log)
        nap(1.0)
        probe2Delayed(host: host, port: port, log: log)
        nap(1.0)
        probe3Garbage(host: host, port: port, log: log)
        nap(1.0)
        probe4Control(host: host, port: port, log: log)
        log("PROBE MATRIX 結束")
    }

    // MARK: - 四探針

    /// P1 空連線：connect 後什麼都不送，觀察 3 秒看連線本身活不活。
    private func probe1Idle(host: String, port: UInt16, log: LogFn) {
        log("--- P1 IDLE（空連線，只連不送） ---")
        guard let c = openConn("P1", host: host, port: port, log: log) else { return }
        let r = watch(fd: c.fd, prefix: "P1", t0: c.t0, windowMs: 3000, sent: 0, log: log)
        if r.end == .survived {
            log("P1 OK 存活滿 3 秒（對方未切、無資料） sent=0 recv=\(r.recv) life=\(msSince(c.t0))ms")
        }
        close(c.fd)
    }

    /// P2 延遲首送：connect 後等到 @300ms 才送 GetValue，再觀察至連線滿 4 秒。
    private func probe2Delayed(host: String, port: UInt16, log: LogFn) {
        log("--- P2 DELAY-300ms（延遲首送 GetValue） ---")
        guard let c = openConn("P2", host: host, port: port, log: log) else { return }
        let waitMs = 300 - msSince(c.t0)
        if waitMs > 0 { Thread.sleep(forTimeInterval: Double(waitMs) / 1000.0) }
        let frame = Self.getValueFrame
        if let e = sendAll(fd: c.fd, bytes: frame) {
            log("P2 X >GetValue err=\(e) sent=0 recv=0 life=\(msSince(c.t0))ms")
            close(c.fd)
            return
        }
        log("P2 > GetValue:ProductVersion \(frame.count)B @\(msSince(c.t0))ms")
        let remain = 4000 - msSince(c.t0)
        let r = watch(fd: c.fd, prefix: "P2", t0: c.t0, windowMs: max(remain, 0), sent: frame.count, log: log)
        if r.end == .survived {
            log("P2 OK 觀察窗結束未被切 sent=\(frame.count) recv=\(r.recv) life=\(msSince(c.t0))ms")
        }
        close(c.fd)
    }

    /// P3 垃圾字節：connect 後 @0ms 立刻送 340B 非 plist 垃圾（重複 'A'）。
    private func probe3Garbage(host: String, port: UInt16, log: LogFn) {
        log("--- P3 GARBAGE（@0ms 垃圾字節） ---")
        guard let c = openConn("P3", host: host, port: port, log: log) else { return }
        let garbage = [UInt8](repeating: 0x41, count: 340)
        if let e = sendAll(fd: c.fd, bytes: garbage) {
            log("P3 X >GARBAGE err=\(e) sent=0 recv=0 life=\(msSince(c.t0))ms")
            close(c.fd)
            return
        }
        log("P3 > GARBAGE \(garbage.count)B @\(msSince(c.t0))ms")
        let remain = 4000 - msSince(c.t0)
        let r = watch(fd: c.fd, prefix: "P3", t0: c.t0, windowMs: max(remain, 0), sent: garbage.count, log: log)
        if r.end == .survived {
            log("P3 OK 觀察窗結束未被切 sent=\(garbage.count) recv=\(r.recv) life=\(msSince(c.t0))ms")
        }
        close(c.fd)
    }

    /// P4 對照組：connect 後 @0ms 立刻送與 P2 相同的 GetValue（複現已知死法）。
    private func probe4Control(host: String, port: UInt16, log: LogFn) {
        log("--- P4 CONTROL（@0ms GetValue 對照組） ---")
        guard let c = openConn("P4", host: host, port: port, log: log) else { return }
        let frame = Self.getValueFrame
        if let e = sendAll(fd: c.fd, bytes: frame) {
            log("P4 X >GetValue err=\(e) sent=0 recv=0 life=\(msSince(c.t0))ms")
            close(c.fd)
            return
        }
        log("P4 > GetValue:ProductVersion \(frame.count)B @\(msSince(c.t0))ms")
        let remain = 4000 - msSince(c.t0)
        let r = watch(fd: c.fd, prefix: "P4", t0: c.t0, windowMs: max(remain, 0), sent: frame.count, log: log)
        if r.end == .survived {
            log("P4 OK 觀察窗結束未被切 sent=\(frame.count) recv=\(r.recv) life=\(msSince(c.t0))ms")
        }
        close(c.fd)
    }

    // MARK: - socket 基礎

    private enum WatchEnd { case survived, closed }

    /// 非阻塞 connect（3 秒逾時）；成功回 (fd, t0)，t0 為 connect 前的時刻。
    private func openConn(_ prefix: String, host: String, port: UInt16, log: LogFn) -> (fd: Int32, t0: UInt64)? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            log("\(prefix) X OPEN err=\(errnoText(errno))")
            return nil
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
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
                if soErr != 0 {
                    log("\(prefix) X OPEN err=\(errnoText(soErr)) life=\(msSince(t0))ms")
                    close(fd)
                    return nil
                }
            } else {
                log("\(prefix) X OPEN err=\(errnoText(errno)) life=\(msSince(t0))ms")
                close(fd)
                return nil
            }
        }
        log("\(prefix) OPEN \(host):\(port) @\(msSince(t0))ms")
        return (fd, t0)
    }

    /// 把 bytes 全部送出；失敗回 err 原文，成功回 nil。
    private func sendAll(fd: Int32, bytes: [UInt8]) -> String? {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { bp in
                send(fd, bp.baseAddress! + off, bytes.count - off, 0)
            }
            if n > 0 { off += n; continue }
            let e = errno
            if n < 0 && e == EINTR { continue }
            if n < 0 && (e == EAGAIN || e == EWOULDBLOCK) {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, 1000) <= 0 { return errnoText(ETIMEDOUT) }
                continue
            }
            return errnoText(e)
        }
        return nil
    }

    /// poll 讀取觀察窗：逐筆記回覆字節；EOF／錯誤記 X 行並結束；窗滿未被切回 .survived。
    private func watch(fd: Int32, prefix: String, t0: UInt64, windowMs: Int, sent: Int, log: LogFn) -> (end: WatchEnd, recv: Int) {
        var recvTotal = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(windowMs, 0)) * 1_000_000
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return (.survived, recvTotal) }
            let remainMs = Int((deadline - now) / 1_000_000)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(max(remainMs, 1)))
            if pr == 0 { return (.survived, recvTotal) }
            if pr < 0 {
                if errno == EINTR { continue }
                log("\(prefix) X err=\(errnoText(errno)) sent=\(sent) recv=\(recvTotal) life=\(msSince(t0))ms")
                return (.closed, recvTotal)
            }
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                recvTotal += n
                log("\(prefix) < \(n)B @\(msSince(t0))ms")
                continue
            }
            if n == 0 {
                log("\(prefix) X EOF（對方關閉） sent=\(sent) recv=\(recvTotal) life=\(msSince(t0))ms")
                return (.closed, recvTotal)
            }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                if soErr != 0 {
                    log("\(prefix) X err=\(errnoText(soErr)) sent=\(sent) recv=\(recvTotal) life=\(msSince(t0))ms")
                    return (.closed, recvTotal)
                }
                continue
            }
            log("\(prefix) X err=\(errnoText(e)) sent=\(sent) recv=\(recvTotal) life=\(msSince(t0))ms")
            return (.closed, recvTotal)
        }
    }

    // MARK: - 小工具

    private func msSince(_ t0: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }

    private func nap(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
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
