//
//  RoonMOO.swift
//  Roonamp
//
//  MOO (Message-Oriented Object) WebSocket protocol for Roon Core communication.
//

import Foundation

enum MOOVerb: String {
    case request = "REQUEST"
    case `continue` = "CONTINUE"
    case complete = "COMPLETE"
}

struct MOOMessage {
    let verb: MOOVerb
    let name: String          // service/method for REQUEST; response name for CONTINUE/COMPLETE
    let requestId: Int
    let body: [String: Any]?
    let headers: [String: String]
}

/// Callback for MOO responses. `msg` is the parsed MOOMessage, nil on connection error.
typealias MOORequestCallback = @Sendable (MOOMessage?) -> Void

actor RoonMOO {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var requestId = 0
    private var subKey = 0
    private var pendingRequests: [Int: MOORequestCallback] = [:]
    private var incomingRequestHandler: ((MOOMessage, RoonMOO) -> Void)?
    private var onDisconnect: (() -> Void)?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var isConnected = false

    init() {}

    func connect(ip: String, port: Int,
                 onRequest: @escaping (MOOMessage, RoonMOO) -> Void,
                 onDisconnect: @escaping () -> Void) {
        self.incomingRequestHandler = onRequest
        self.onDisconnect = onDisconnect

        let url = URL(string: "ws://\(ip):\(port)/api")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        let ws = session!.webSocketTask(with: url)
        webSocket = ws
        ws.resume()
        isConnected = true
        startReceiveLoop()
        startPingLoop()
    }

    func disconnect() {
        isConnected = false
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        // Notify all pending requests of disconnection
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cb) in pending {
            cb(nil)
        }
    }

    /// Send a MOO REQUEST and register a callback for the response.
    /// Returns the request ID used.
    @discardableResult
    func sendRequest(_ name: String, body: [String: Any]? = nil,
                     callback: @escaping MOORequestCallback) -> Int {
        let rid = requestId
        requestId += 1
        pendingRequests[rid] = callback
        sendFrame(verb: .request, name: name, requestId: rid, body: body)
        return rid
    }

    /// Send a COMPLETE response to an incoming request from the core.
    func sendComplete(requestId rid: Int, name: String, body: [String: Any]? = nil) {
        sendFrame(verb: .complete, name: name, requestId: rid, body: body)
    }

    /// Send a CONTINUE response to an incoming request from the core.
    func sendContinue(requestId rid: Int, name: String, body: [String: Any]? = nil) {
        sendFrame(verb: .continue, name: name, requestId: rid, body: body)
    }

    /// Get a new subscription key.
    func nextSubKey() -> Int {
        let k = subKey
        subKey += 1
        return k
    }

    // MARK: - Frame Construction

    private func sendFrame(verb: MOOVerb, name: String, requestId: Int, body: [String: Any]?) {
        guard let ws = webSocket, isConnected else { return }

        var header = "MOO/1 \(verb.rawValue) \(name)\nRequest-Id: \(requestId)\n"

        var bodyData: Data?
        if let body = body {
            if let data = try? JSONSerialization.data(withJSONObject: body) {
                bodyData = data
                header += "Content-Length: \(data.count)\n"
                header += "Content-Type: application/json\n"
            }
        }

        header += "\n"

        var frame = Data(header.utf8)
        if let bodyData = bodyData {
            frame.append(bodyData)
        }

        ws.send(.data(frame)) { error in
            if let error = error {
                print("❌ MOO send error: \(error)")
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                guard let ws = await self.webSocket else { break }
                do {
                    let message = try await ws.receive()
                    switch message {
                    case .data(let data):
                        await self.handleFrame(data)
                    case .string(let str):
                        await self.handleFrame(Data(str.utf8))
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        print("❌ MOO receive error: \(error)")
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self = self, !Task.isCancelled else { break }
                await self.webSocket?.sendPing { error in
                    if let error = error {
                        print("❌ MOO ping error: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Frame Parsing

    private func handleFrame(_ data: Data) {
        guard let msg = parseMessage(data) else { return }

        switch msg.verb {
        case .continue, .complete:
            if let cb = pendingRequests[msg.requestId] {
                if msg.verb == .complete {
                    pendingRequests.removeValue(forKey: msg.requestId)
                }
                cb(msg)
            }
        case .request:
            incomingRequestHandler?(msg, self)
        }
    }

    private func parseMessage(_ data: Data) -> MOOMessage? {
        // Find the header/body separator: \n\n
        let bytes = [UInt8](data)
        var headerEnd = -1
        guard bytes.count >= 2 else { return nil }
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == 0x0A && bytes[i + 1] == 0x0A {
                headerEnd = i
                break
            }
        }
        guard headerEnd >= 0 else { return nil }

        let headerData = Data(bytes[0...headerEnd])
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return nil }

        // Parse first line: "MOO/1 VERB name"
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3, parts[0] == "MOO/1" else { return nil }

        guard let verb = MOOVerb(rawValue: String(parts[1])) else { return nil }
        let name = String(parts[2])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        guard let ridStr = headers["Request-Id"], let rid = Int(ridStr) else { return nil }

        // Parse body
        var body: [String: Any]?
        let bodyStart = headerEnd + 2 // skip \n\n
        if bodyStart < bytes.count,
           let contentLength = headers["Content-Length"].flatMap(Int.init),
           contentLength > 0 {
            let bodyEnd = min(bodyStart + contentLength, bytes.count)
            let bodyData = Data(bytes[bodyStart..<bodyEnd])
            if headers["Content-Type"] == "application/json" {
                body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            }
        }

        return MOOMessage(verb: verb, name: name, requestId: rid, body: body, headers: headers)
    }

    private func handleDisconnect() {
        guard isConnected else { return }
        isConnected = false
        pingTask?.cancel()
        receiveTask?.cancel()
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cb) in pending {
            cb(nil)
        }
        onDisconnect?()
    }
}
