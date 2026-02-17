//
//  RoonDiscovery.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Network
import Combine

/// Discovers Roon Cores on the local network using SOOD (Simple Object Oriented Discovery)
@MainActor
class RoonDiscovery: ObservableObject {
    @Published var discoveredCores: [RoonCore] = []
    
    private var listener: NWListener?
    private let serviceName = "_roon._tcp"
    
    func startDiscovery() {
        print("🔍 Starting Roon Core discovery...")
        
        // Roon uses SOOD protocol on UDP port 9003
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: 9003)
            
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    print("🔍 New connection received")
                    self?.handleConnection(connection)
                }
            }
            
            listener?.start(queue: .main)
            print("🔍 Listener started on port 9003")
            
            // Also send discovery broadcast
            sendDiscoveryBroadcast()
        } catch {
            print("❌ Failed to start discovery: \(error)")
        }
    }
    
    func stopDiscovery() {
        listener?.cancel()
        listener = nil
    }
    
    private func sendDiscoveryBroadcast() {
        print("🔍 Sending discovery broadcast...")
        
        // Roon SOOD discovery message
        let message = "SOOD ROON com.roonlabs.services.transport\n"
        
        guard let data = message.data(using: .utf8) else { return }
        
        let connection = NWConnection(
            host: .ipv4(.broadcast),
            port: 9003,
            using: .udp
        )
        
        connection.start(queue: .main)
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Discovery broadcast error: \(error)")
            } else {
                print("✅ Discovery broadcast sent successfully")
            }
            connection.cancel()
        })
    }
    
    private func handleConnection(_ connection: NWConnection) {
        print("🔍 Handling connection...")
        connection.start(queue: .main)
        
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            if let error = error {
                print("❌ Receive error: \(error)")
                return
            }
            
            guard let self = self,
                  let data = data,
                  let message = String(data: data, encoding: .utf8) else {
                print("❌ Failed to decode message")
                return
            }
            
            print("📨 Received message: \(message)")
            self.parseDiscoveryResponse(message)
            connection.cancel()
        }
    }
    
    private func parseDiscoveryResponse(_ message: String) {
        print("🔍 Parsing discovery response: \(message)")
        
        // Parse SOOD response format
        // Example: "SOOD ROON/1.0 hostname:port service_id core_name"
        let components = message.components(separatedBy: " ")
        
        guard components.count >= 4,
              components[0] == "SOOD",
              components[1].hasPrefix("ROON") else {
            print("❌ Invalid SOOD response format")
            return
        }
        
        // Extract host and port
        let hostPort = components[2].components(separatedBy: ":")
        guard hostPort.count == 2,
              let port = Int(hostPort[1]) else {
            print("❌ Invalid host:port format")
            return
        }
        
        let core = RoonCore(
            id: components[3],
            name: components.count > 4 ? components[4...].joined(separator: " ") : "Roon Core",
            host: hostPort[0],
            port: port
        )
        
        print("✅ Discovered Roon Core: \(core.name) at \(core.host):\(core.port)")
        
        // Add if not already discovered
        if !discoveredCores.contains(where: { $0.id == core.id }) {
            discoveredCores.append(core)
        }
    }
}

struct RoonCore: Identifiable {
    let id: String
    let name: String
    let host: String
    let port: Int
}
