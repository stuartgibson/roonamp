//
//  RoonTCPConnection.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Network
import Combine

/// TCP-based connection to Roon Core (Roon uses TCP sockets, not WebSockets)
@MainActor
class RoonTCPConnection: ObservableObject {
    @Published var isConnected = false
    @Published var errorMessage: String?
    
    private var connection: NWConnection?
    private let host: String
    private let port: Int
    private let appInfo: RoonAppInfo
    private var requestId = 0
    
    init(host: String, port: Int = 9100, appInfo: RoonAppInfo) {
        self.host = host
        self.port = port
        self.appInfo = appInfo
    }
    
    func connect() {
        print("🔌 Connecting to Roon Core at \(host):\(port) via TCP")
        
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        
        connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }
        
        connection?.start(queue: .main)
        startReceiving()
    }
    
    func disconnect() {
        print("🔌 Disconnecting from Roon Core")
        connection?.cancel()
        isConnected = false
    }
    
    private func handleStateChange(_ state: NWConnection.State) {
        print("📡 Connection state: \(state)")
        
        switch state {
        case .ready:
            print("✅ TCP connection established")
            isConnected = true
            errorMessage = nil
            // Send registration after connection is established
            Task {
                await sendRegistration()
            }
            
        case .waiting(let error):
            print("⚠️ Connection waiting: \(error)")
            errorMessage = "Waiting to connect: \(error.localizedDescription)"
            
        case .failed(let error):
            print("❌ Connection failed: \(error)")
            errorMessage = "Connection failed: \(error.localizedDescription)"
            isConnected = false
            
        case .cancelled:
            print("🔌 Connection cancelled")
            isConnected = false
            
        default:
            break
        }
    }
    
    private func startReceiving() {
        // Roon protocol uses length-prefixed JSON messages
        // Each message is: 4-byte length (big-endian) + JSON payload
        
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Receive error: \(error)")
                return
            }
            
            guard let lengthData = data, lengthData.count == 4 else {
                print("❌ Invalid length header")
                Task { @MainActor in
                    self.startReceiving() // Continue receiving
                }
                return
            }
            
            // Read the length (big-endian 32-bit integer)
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            print("📏 Message length: \(length)")
            
            // Now read the actual message
            self.connection?.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { messageData, _, _, error in
                if let error = error {
                    print("❌ Message receive error: \(error)")
                    return
                }
                
                guard let messageData = messageData,
                      let jsonString = String(data: messageData, encoding: .utf8) else {
                    print("❌ Failed to decode message")
                    Task { @MainActor in
                        self.startReceiving()
                    }
                    return
                }
                
                print("📨 Received: \(jsonString)")
                
                Task { @MainActor in
                    await self.processMessage(jsonString)
                    self.startReceiving() // Continue receiving
                }
            }
        }
    }
    
    private func processMessage(_ jsonString: String) async {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to parse JSON")
            return
        }
        
        print("✅ Parsed message: \(json)")
        
        // Handle different message types
        if let verb = json["verb"] as? String {
            print("📋 Message verb: \(verb)")
            
            switch verb {
            case "REGISTERED":
                print("✅ Successfully registered with Roon Core!")
                isConnected = true
                
            case "COMPLETE":
                print("✅ Request completed")
                
            default:
                print("📋 Received verb: \(verb)")
            }
        }
    }
    
    private func sendRegistration() async {
        print("📤 Sending registration to Roon Core")
        
        let registration: [String: Any] = [
            "com.roonlabs.registry": [
                "extension_id": appInfo.extensionId,
                "display_name": appInfo.displayName,
                "display_version": appInfo.displayVersion,
                "publisher": appInfo.publisher,
                "email": appInfo.email,
                "required_services": [
                    "com.roonlabs.transport:2"
                ]
            ]
        ]
        
        await sendMessage(registration)
    }
    
    private func sendMessage(_ message: [String: Any]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ Failed to serialize message")
            return
        }
        
        print("📤 Sending: \(jsonString)")
        
        // Convert to data with length prefix
        guard let messageData = jsonString.data(using: .utf8) else { return }
        let length = UInt32(messageData.count).bigEndian
        
        var lengthData = Data()
        withUnsafeBytes(of: length) { lengthData.append(contentsOf: $0) }
        
        // Send length prefix
        connection?.send(content: lengthData, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Failed to send length: \(error)")
                return
            }
            
            // Send message body
            self.connection?.send(content: messageData, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send message: \(error)")
                } else {
                    print("✅ Message sent successfully")
                }
            })
        })
    }
}

