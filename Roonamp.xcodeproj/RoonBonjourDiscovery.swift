//
//  RoonBonjourDiscovery.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Network
import Combine

/// Discovers Roon Cores using Bonjour/mDNS
@MainActor
class RoonBonjourDiscovery: ObservableObject {
    @Published var discoveredCores: [RoonCore] = []
    
    private var browser: NWBrowser?
    
    func startDiscovery() {
        print("🔍 Starting Bonjour discovery for Roon...")
        
        // Try to find Roon services via Bonjour
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        // Roon might advertise as _roon._tcp or similar
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_roon._tcp", domain: nil), using: parameters)
        
        browser?.stateUpdateHandler = { newState in
            print("🔍 Browser state: \(newState)")
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                print("🔍 Found \(results.count) services")
                for result in results {
                    print("  📡 Service: \(result.endpoint)")
                    self?.handleDiscoveredService(result)
                }
            }
        }
        
        browser?.start(queue: .main)
    }
    
    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }
    
    private func handleDiscoveredService(_ result: NWBrowser.Result) {
        print("🔍 Processing service: \(result.endpoint)")
        
        switch result.endpoint {
        case .service(let name, let type, let domain, let interface):
            print("  📋 Name: \(name)")
            print("  📋 Type: \(type)")
            print("  📋 Domain: \(domain ?? "nil")")
            
            // We need to resolve this to get the actual IP and port
            // For now, we'll create a placeholder
            let core = RoonCore(
                id: name,
                name: name,
                host: "unknown", // Need to resolve
                port: 9100
            )
            
            if !discoveredCores.contains(where: { $0.id == core.id }) {
                discoveredCores.append(core)
            }
            
        default:
            break
        }
    }
}
