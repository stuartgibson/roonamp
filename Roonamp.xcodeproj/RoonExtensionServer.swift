//
//  RoonExtensionServer.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Network
import Combine

/// Runs a WebSocket server that Roon Core can connect to
@MainActor
class RoonExtensionServer: ObservableObject {
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private let appInfo: RoonAppInfo
    private let port: UInt16 = 9876 // Random port for our extension server
    
    init(appInfo: RoonAppInfo) {
        self.appInfo = appInfo
    }
    
    func start() {
        print("🚀 Starting Roon extension server on port \(port)")
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    print("📡 Roon Core is connecting!")
                    self?.handleIncomingConnection(connection)
                }
            }
            
            listener?.start(queue: .main)
            
        } catch {
            print("❌ Failed to start server: \(error)")
            errorMessage = "Failed to start server: \(error.localizedDescription)"
        }
    }
    
    func stop() {
        listener?.cancel()
        connection?.cancel()
        isRunning = false
        isConnected = false
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        print("🎧 Server state: \(state)")
        
        switch state {
        case .ready:
            print("✅ Extension server is ready on port \(port)")
            isRunning = true
            // Now broadcast our presence via SOOD
            broadcastPresence()
            
        case .failed(let error):
            print("❌ Server failed: \(error)")
            errorMessage = "Server failed: \(error.localizedDescription)"
            isRunning = false
            
        default:
            break
        }
    }
    
    private func handleIncomingConnection(_ newConnection: NWConnection) {
        print("📡 Accepting connection from Roon Core")
        self.connection = newConnection
        
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        
        newConnection.start(queue: .main)
        startReceiving()
    }
    
    private func handleConnectionState(_ state: NWConnection.State) {
        print("🔗 Connection state: \(state)")
        
        switch state {
        case .ready:
            print("✅ Connected to Roon Core!")
            isConnected = true
            
        case .failed(let error):
            print("❌ Connection failed: \(error)")
            errorMessage = "Connection failed: \(error.localizedDescription)"
            isConnected = false
            
        default:
            break
        }
    }
    
    private func startReceiving() {
        // Receive messages from Roon Core
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    await self.handleReceivedData(data)
                }
            }
            
            if !isComplete {
                self.startReceiving()
            }
        }
    }
    
    private func handleReceivedData(_ data: Data) async {
        if let message = String(data: data, encoding: .utf8) {
            print("📨 Received from Roon: \(message)")
        }
    }
    
    private func broadcastPresence() {
        print("📢 Broadcasting extension presence via SOOD")
        
        // Send SOOD broadcast announcing our extension
        let message = "SOOD ROON \(getLocalIPAddress() ?? "localhost"):\(port) \(appInfo.extensionId)\n"
        guard let data = message.data(using: .utf8) else { return }
        
        let connection = NWConnection(host: .ipv4(.broadcast), port: 9003, using: .udp)
        connection.start(queue: .main)
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Broadcast failed: \(error)")
            } else {
                print("✅ Broadcast sent: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            connection.cancel()
        })
    }
    
    private func getLocalIPAddress() -> String? {
        // Simple way to get local IP - this is not perfect but works for basic cases
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: (interface?.ifa_name)!)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        
        return address
    }
}
