//
//  RoonNodeSwift.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Combine
import NodeAPI

/// Uses node-swift to run Roon API in embedded Node.js
@MainActor
class RoonNodeSwift: ObservableObject {
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var zones: [[String: Any]] = []
    
    private var nodeRuntime: NodeRuntime?
    private let appInfo: RoonAppInfo
    
    init(appInfo: RoonAppInfo) {
        self.appInfo = appInfo
    }
    
    func start() async {
        print("🟢 Starting embedded Node.js via node-swift...")
        
        do {
            // Initialize Node.js runtime
            nodeRuntime = try NodeRuntime()
            
            // Run the Roon API setup
            let script = """
            const RoonApi = require('node-roon-api');
            const RoonApiTransport = require('node-roon-api-transport');
            
            let core;
            let transport;
            let zones = {};
            
            const roon = new RoonApi({
                extension_id: '\(appInfo.extensionId)',
                display_name: '\(appInfo.displayName)',
                display_version: '\(appInfo.displayVersion)',
                publisher: '\(appInfo.publisher)',
                email: '\(appInfo.email)',
                core_paired: (pairedCore) => {
                    console.log('PAIRED:', pairedCore.display_name);
                    core = pairedCore;
                    transport = core.services.RoonApiTransport;
                    
                    // Subscribe to zone changes
                    transport.subscribe_zones((cmd, data) => {
                        if (cmd == 'Subscribed') {
                            zones = data.zones;
                        } else if (cmd == 'Changed') {
                            if (data.zones_changed) {
                                data.zones_changed.forEach(zone => {
                                    zones[zone.zone_id] = zone;
                                });
                            }
                        }
                    });
                },
                core_unpaired: () => {
                    console.log('UNPAIRED');
                    core = null;
                    transport = null;
                    zones = {};
                }
            });
            
            roon.init_services({
                required_services: [RoonApiTransport]
            });
            
            roon.start_discovery();
            
            // Export functions for Swift to call
            global.isConnected = () => !!core;
            global.getZones = () => Object.values(zones);
            global.control = (zoneId, command) => {
                if (transport) {
                    transport.control(zoneId, command);
                }
            };
            
            console.log('Roon API initialized');
            """
            
            try nodeRuntime?.run(script)
            
            print("✅ Node.js runtime initialized with Roon API")
            
            // Start polling for connection status
            startStatusPolling()
            
        } catch {
            errorMessage = "Failed to initialize Node.js: \(error.localizedDescription)"
            print("❌ \(errorMessage ?? "")")
        }
    }
    
    func stop() {
        nodeRuntime = nil
        isConnected = false
    }
    
    private func startStatusPolling() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkStatus()
            }
        }
    }
    
    private func checkStatus() async {
        guard let runtime = nodeRuntime else { return }
        
        do {
            let connected = try runtime.call("isConnected")
            if let isConnectedBool = connected as? Bool {
                isConnected = isConnectedBool
                
                if isConnectedBool {
                    // Get zones
                    let zonesResult = try runtime.call("getZones")
                    if let zonesArray = zonesResult as? [[String: Any]] {
                        zones = zonesArray
                    }
                }
            }
        } catch {
            print("⚠️ Status check error: \(error)")
        }
    }
    
    func control(zoneId: String, command: String) async throws {
        guard let runtime = nodeRuntime else {
            throw NSError(domain: "RoonNodeSwift", code: -1, userInfo: [NSLocalizedDescriptionKey: "Node runtime not initialized"])
        }
        
        try runtime.call("control", with: [zoneId, command])
    }
}
