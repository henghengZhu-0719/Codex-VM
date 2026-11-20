import Foundation
import Darwin

struct BalloonStatus: Equatable {
    let targetMB: Double
    let maxMB: Double
    let minMB: Double
}

enum HostMemoryPressureLevel: String {
    case normal = "normal"
    case warning = "warning"
    case critical = "critical"

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏紧"
        case .critical: return "紧张"
        }
    }
}

final class HostMemoryPressureMonitor {
    private var source: DispatchSourceMemoryPressure?
    private(set) var level: HostMemoryPressureLevel = .normal
    var onChange: ((HostMemoryPressureLevel) -> Void)?

    func start() {
        stop()
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            let next: HostMemoryPressureLevel
            if event.contains(.critical) {
                next = .critical
            } else if event.contains(.warning) {
                next = .warning
            } else {
                next = .normal
            }
            if next != self.level {
                self.level = next
                self.onChange?(next)
            }
        }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

enum HostMemoryFootprint {
    /// Measures the real macOS physical memory footprint (ri_phys_footprint, matching Activity Monitor)
    /// for a VM's hostagent process and its child processes (including com.apple.Virtualization.VirtualMachine).
    static func measureMB(vmName: String, limaDir: String) -> Double {
        let pidPath = URL(fileURLWithPath: limaDir)
            .appendingPathComponent(vmName)
            .appendingPathComponent("ha.pid").path
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let haPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              haPID > 1 else {
            return 0
        }

        var pids: [pid_t] = [haPID]
        let childBufCount = 32
        var childPids = [pid_t](repeating: 0, count: childBufCount)
        let bytesReturned = proc_listchildpids(haPID, &childPids, Int32(childBufCount * MemoryLayout<pid_t>.stride))
        if bytesReturned > 0 {
            let count = Int(bytesReturned) / MemoryLayout<pid_t>.stride
            for i in 0..<min(count, childBufCount) where childPids[i] > 1 {
                pids.append(childPids[i])
            }
        }

        var totalBytes: UInt64 = 0
        for pid in pids {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            if rc == 0 {
                totalBytes &+= info.ri_phys_footprint
            }
        }
        return Double(totalBytes) / (1024.0 * 1024.0)
    }
}

enum HostAgentBalloonClient {
    static func socketPath(vmName: String, limaDir: String) -> String {
        URL(fileURLWithPath: limaDir)
            .appendingPathComponent(vmName)
            .appendingPathComponent("ha.sock").path
    }

    static func get(vmName: String, limaDir: String) -> BalloonStatus? {
        let sock = socketPath(vmName: vmName, limaDir: limaDir)
        guard let body = sendHTTP(socketPath: sock, method: "GET", path: "/v1/memory/balloon", body: nil) else {
            return nil
        }
        return parse(body)
    }

    static func set(vmName: String, limaDir: String, targetMB: Int) -> BalloonStatus? {
        let sock = socketPath(vmName: vmName, limaDir: limaDir)
        let payload = "{\"targetMB\":\(max(0, targetMB))}"
        guard let body = sendHTTP(socketPath: sock, method: "POST", path: "/v1/memory/balloon", body: payload) else {
            return nil
        }
        return parse(body)
    }

    private static func parse(_ data: Data) -> BalloonStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = (obj["targetBytes"] as? NSNumber)?.doubleValue,
              let maxB = (obj["maxBytes"] as? NSNumber)?.doubleValue,
              let minB = (obj["minBytes"] as? NSNumber)?.doubleValue,
              maxB > 0 else {
            return nil
        }
        let mib = 1024.0 * 1024.0
        return BalloonStatus(targetMB: target / mib, maxMB: maxB / mib, minMB: minB / mib)
    }

    private static func sendHTTP(socketPath: String, method: String, path: String, body: String?) -> Data? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxPathLen else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (idx, byte) in pathBytes.enumerated() {
                buf[idx] = byte
            }
            buf[pathBytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }
        guard connectRes == 0 else { return nil }

        let bodyData = body?.data(using: .utf8) ?? Data()
        var req = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if !bodyData.isEmpty {
            req += "Content-Type: application/json\r\nContent-Length: \(bodyData.count)\r\n"
        }
        req += "\r\n"
        var raw = Data(req.utf8)
        raw.append(bodyData)

        let written = raw.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            var total = 0
            while total < raw.count {
                let n = Darwin.write(fd, base.advanced(by: total), raw.count - total)
                if n <= 0 { return -1 }
                total += n
            }
            return total
        }
        guard written == raw.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                response.append(buffer, count: n)
                if response.count > 65536 { break }
            } else {
                break
            }
        }
        guard let sepRange = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = response.subdata(in: response.startIndex..<sepRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8),
              let firstLine = headerText.components(separatedBy: "\r\n").first,
              firstLine.contains(" 200 ") else {
            return nil
        }
        return response.subdata(in: sepRange.upperBound..<response.endIndex)
    }
}

struct SmartBalloonDecision {
    let shouldAdjust: Bool
    let targetMB: Int
}

enum SmartMemoryPolicy {
    static func decideBalloonTarget(
        usedMB: Double,
        totalMB: Double,
        current: BalloonStatus,
        isBurstActive: Bool,
        pressure: HostMemoryPressureLevel,
        lastAdjustAt: Date?,
        now: Date = Date()
    ) -> SmartBalloonDecision {
        let maxMB = current.maxMB
        let minMB = max(current.minMB, 768)
        guard maxMB > minMB else { return SmartBalloonDecision(shouldAdjust: false, targetMB: Int(maxMB)) }

        let availMB = max(0, totalMB - usedMB)
        let memPct = totalMB > 0 ? (usedMB / totalMB) * 100.0 : 0

        // Immediate full expansion if VM is actively bursting or low on guest headroom.
        if isBurstActive || memPct >= 75.0 || availMB < 600.0 {
            if maxMB - current.targetMB >= 128.0 {
                return SmartBalloonDecision(shouldAdjust: true, targetMB: Int(ceil(maxMB)))
            }
            return SmartBalloonDecision(shouldAdjust: false, targetMB: Int(ceil(current.targetMB)))
        }

        // Compute desired target with pressure-aware headroom.
        let headroomMB: Double
        switch pressure {
        case .normal: headroomMB = 768.0
        case .warning: headroomMB = 448.0
        case .critical: headroomMB = 256.0
        }

        let rawDesired = min(maxMB, max(minMB, usedMB + headroomMB))
        // Round up to 64 MiB increments for clean page alignment.
        let desiredMB = min(maxMB, ceil(rawDesired / 64.0) * 64.0)
        let delta = desiredMB - current.targetMB

        // Expanding (moderate): allow quickly if >= 128 MiB needed.
        if delta >= 128.0 {
            return SmartBalloonDecision(shouldAdjust: true, targetMB: Int(desiredMB))
        }

        // Shrinking: apply hysteresis (>= 192 MiB) and cooldown to avoid thrashing.
        let shrinkCooldown: TimeInterval = pressure == .normal ? 20.0 : 5.0
        if -delta >= 192.0 {
            if let last = lastAdjustAt, now.timeIntervalSince(last) < shrinkCooldown {
                return SmartBalloonDecision(shouldAdjust: false, targetMB: Int(ceil(current.targetMB)))
            }
            return SmartBalloonDecision(shouldAdjust: true, targetMB: Int(desiredMB))
        }

        return SmartBalloonDecision(shouldAdjust: false, targetMB: Int(ceil(current.targetMB)))
    }
}
