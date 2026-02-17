//
//  RoonSOOD.swift
//  Roonamp
//
//  SOOD (Simple Object-Oriented Discovery) protocol for finding Roon Core on the network.
//  Uses two POSIX sockets (like node-roon-api): multicast on port 9003 + unicast on ephemeral port.
//

import Foundation

/// Simple file logger for debugging
func rlog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let path = "/tmp/roonamp_debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

struct RoonCoreInfo {
    let ip: String
    let port: Int
    let uniqueId: String
}

/// Discovers Roon Cores on the local network using SOOD UDP protocol.
class RoonSOOD {
    private let serviceId = "00720724-5143-4a9b-abac-0e50cba674bb"
    private let soodPort: UInt16 = 9003
    private let multicastGroup = "239.255.90.90"

    // Two sockets like node-roon-api's sood.js:
    // - multicastFD: bound to port 9003, joined multicast group (receives multicast responses)
    // - unicastFD: bound to ephemeral port, used for sending queries and receiving unicast responses
    private var multicastFD: Int32 = -1
    private var unicastFD: Int32 = -1
    private var queryTimer: Timer?
    private var multicastSource: DispatchSourceRead?
    private var unicastSource: DispatchSourceRead?
    private var onCoreFound: ((RoonCoreInfo) -> Void)?
    private var isStopped = false

    func startDiscovery(onCoreFound: @escaping (RoonCoreInfo) -> Void) {
        self.onCoreFound = onCoreFound
        self.isStopped = false
        rlog("SOOD: Starting discovery for Roon Core...")

        guard setupSockets() else {
            rlog("SOOD: Failed to set up sockets")
            return
        }

        startReceiving()
        sendQuery()
        queryTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.sendQuery()
        }
    }

    func stopDiscovery() {
        isStopped = true
        queryTimer?.invalidate()
        queryTimer = nil
        multicastSource?.cancel()
        multicastSource = nil
        unicastSource?.cancel()
        unicastSource = nil
        if multicastFD >= 0 { close(multicastFD); multicastFD = -1 }
        if unicastFD >= 0 { close(unicastFD); unicastFD = -1 }
        rlog("SOOD: Discovery stopped")
    }

    // MARK: - Socket Setup

    private func setupSockets() -> Bool {
        // 1. Unicast socket - ephemeral port, for sending queries and receiving unicast replies
        unicastFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard unicastFD >= 0 else {
            rlog("SOOD: unicast socket() failed: \(String(cString: strerror(errno)))")
            return false
        }

        var reuse: Int32 = 1
        setsockopt(unicastFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(unicastFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var broadcast: Int32 = 1
        setsockopt(unicastFD, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        // Bind to ephemeral port (port 0)
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0  // ephemeral
        bindAddr.sin_addr.s_addr = INADDR_ANY.bigEndian

        var bindResult = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(unicastFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            rlog("SOOD: unicast bind() failed: \(String(cString: strerror(errno)))")
            close(unicastFD); unicastFD = -1
            return false
        }

        // Set multicast TTL on the unicast socket too (for sending)
        var ttl: UInt8 = 1
        setsockopt(unicastFD, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        setNonBlocking(unicastFD)
        rlog("SOOD: Unicast socket ready (fd: \(unicastFD))")

        // 2. Multicast socket - bound to port 9003, joined multicast group
        multicastFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard multicastFD >= 0 else {
            rlog("SOOD: multicast socket() failed: \(String(cString: strerror(errno)))")
            close(unicastFD); unicastFD = -1
            return false
        }

        var reuse2: Int32 = 1
        setsockopt(multicastFD, SOL_SOCKET, SO_REUSEADDR, &reuse2, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(multicastFD, SOL_SOCKET, SO_REUSEPORT, &reuse2, socklen_t(MemoryLayout<Int32>.size))

        var mcastBindAddr = sockaddr_in()
        mcastBindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        mcastBindAddr.sin_family = sa_family_t(AF_INET)
        mcastBindAddr.sin_port = soodPort.bigEndian
        mcastBindAddr.sin_addr.s_addr = INADDR_ANY.bigEndian

        bindResult = withUnsafePointer(to: &mcastBindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(multicastFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            rlog("SOOD: multicast bind() to port 9003 failed: \(String(cString: strerror(errno)))")
            close(multicastFD); multicastFD = -1
            close(unicastFD); unicastFD = -1
            return false
        }

        // Join multicast group
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr(multicastGroup)
        mreq.imr_interface.s_addr = INADDR_ANY.bigEndian
        let joinResult = setsockopt(multicastFD, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        if joinResult < 0 {
            rlog("SOOD: Failed to join multicast group: \(String(cString: strerror(errno)))")
        } else {
            rlog("SOOD: Joined multicast group \(multicastGroup)")
        }

        setNonBlocking(multicastFD)
        rlog("SOOD: Multicast socket ready (fd: \(multicastFD))")
        return true
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    // MARK: - Receiving

    private func startReceiving() {
        // Listen on both sockets
        if multicastFD >= 0 {
            let source = DispatchSource.makeReadSource(fileDescriptor: multicastFD, queue: .main)
            source.setEventHandler { [weak self] in
                self?.readPendingData(from: self?.multicastFD ?? -1, label: "multicast")
            }
            source.resume()
            multicastSource = source
        }

        if unicastFD >= 0 {
            let source = DispatchSource.makeReadSource(fileDescriptor: unicastFD, queue: .main)
            source.setEventHandler { [weak self] in
                self?.readPendingData(from: self?.unicastFD ?? -1, label: "unicast")
            }
            source.resume()
            unicastSource = source
        }
    }

    private func readPendingData(from fd: Int32, label: String) {
        guard fd >= 0, !isStopped else { return }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var senderAddr = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                recvfrom(fd, &buffer, buffer.count, 0, sockPtr, &senderLen)
            }
        }

        guard bytesRead > 0 else { return }

        let data = Data(buffer[0..<bytesRead])
        let senderIP = String(cString: inet_ntoa(senderAddr.sin_addr))



        parseResponse(data, senderIP: senderIP)
    }

    // MARK: - Sending Queries

    private func sendQuery() {
        guard unicastFD >= 0, !isStopped else { return }
        let packet = buildQueryPacket()

        // Send from the unicast socket so replies come back to our ephemeral port
        sendTo(packet, ip: multicastGroup, port: soodPort)
        sendTo(packet, ip: "255.255.255.255", port: soodPort)
        rlog("SOOD: Sent query to multicast + broadcast")
    }

    private func sendTo(_ data: Data, ip: String, port: UInt16) {
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian
        destAddr.sin_addr.s_addr = inet_addr(ip)

        let sent = data.withUnsafeBytes { bufPtr in
            withUnsafePointer(to: &destAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(unicastFD, bufPtr.baseAddress, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if sent < 0 {
            rlog("SOOD: sendto \(ip):\(port) failed: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Packet Construction

    private func buildQueryPacket() -> Data {
        var data = Data()
        data.append(contentsOf: [0x53, 0x4F, 0x4F, 0x44]) // "SOOD"
        data.append(2)    // Version
        data.append(0x51) // Type: "Q" (query)

        let tid = UUID().uuidString.lowercased()
        appendKV(&data, name: "_tid", value: tid)
        appendKV(&data, name: "query_service_id", value: serviceId)

        return data
    }

    private func appendKV(_ data: inout Data, name: String, value: String) {
        let nameBytes = Array(name.utf8)
        data.append(UInt8(nameBytes.count))
        data.append(contentsOf: nameBytes)

        let valueBytes = Array(value.utf8)
        let length = UInt16(valueBytes.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(contentsOf: valueBytes)
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data, senderIP: String) {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return }

        guard bytes[0] == 0x53, bytes[1] == 0x4F, bytes[2] == 0x4F, bytes[3] == 0x44 else { return }
        guard bytes[4] == 2 else { return }
        // Only process responses (type "R"), skip our own queries (type "Q")
        guard bytes[5] == 0x52 else { return }

        var props: [String: String] = [:]
        var offset = 6
        while offset < bytes.count {
            let nameLen = Int(bytes[offset])
            offset += 1
            guard nameLen > 0, offset + nameLen <= bytes.count else { break }

            let name = String(bytes: bytes[offset..<(offset + nameLen)], encoding: .utf8) ?? ""
            offset += nameLen

            guard offset + 2 <= bytes.count else { break }
            let valueLen = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2

            if valueLen == 0xFFFF { continue }

            guard offset + valueLen <= bytes.count else { break }
            let value = String(bytes: bytes[offset..<(offset + valueLen)], encoding: .utf8) ?? ""
            offset += valueLen
            props[name] = value
        }




        guard let httpPortStr = props["http_port"], let httpPort = Int(httpPortStr) else {
            return
        }

        let coreIP = props["_replyaddr"] ?? senderIP
        let uniqueId = props["unique_id"] ?? "unknown"

        let info = RoonCoreInfo(ip: coreIP, port: httpPort, uniqueId: uniqueId)
        rlog("SOOD: Found Roon Core at \(coreIP):\(httpPort) (id: \(uniqueId))")
        onCoreFound?(info)
    }
}
