//
//  RoonNodeBridge.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Combine

/// Bridges to a Node.js process running the node-roon-api
@MainActor
class RoonNodeBridge: ObservableObject {
    @Published var isConnected = false
    @Published var errorMessage: String?
    
    private var nodeProcess: Process?
    private var serverPort: Int = 3000
    
    func start() {
        print("🟢 Starting Node.js bridge server...")
        
        // Create the bridge server script
        createBridgeScript()
        
        // Start Node.js process
        startNodeProcess()
    }
    
    func stop() {
        nodeProcess?.terminate()
        nodeProcess = nil
        isConnected = false
    }
    
    private func createBridgeScript() {
        let scriptPath = getScriptPath()
        
        let script = """
        const RoonApi = require('node-roon-api');
        const RoonApiTransport = require('node-roon-api-transport');
        const http = require('http');
        
        let core;
        let transport;
        
        const roon = new RoonApi({
            extension_id: 'com.yourcompany.roonamp',
            display_name: 'Roonamp',
            display_version: '1.0.0',
            publisher: 'Your Name',
            email: 'your.email@example.com',
            core_paired: (pairedCore) => {
                console.log('PAIRED:', pairedCore.display_name);
                core = pairedCore;
                transport = core.services.RoonApiTransport;
            },
            core_unpaired: () => {
                console.log('UNPAIRED');
                core = null;
                transport = null;
            }
        });
        
        roon.init_services({
            required_services: [RoonApiTransport]
        });
        
        // Start discovery
        roon.start_discovery();
        
        // HTTP server for Swift to communicate with
        const server = http.createServer((req, res) => {
            res.setHeader('Access-Control-Allow-Origin', '*');
            res.setHeader('Content-Type', 'application/json');
            
            const url = new URL(req.url, `http://localhost:\(serverPort)`);
            
            if (url.pathname === '/status') {
                res.end(JSON.stringify({ 
                    connected: !!core,
                    core_name: core?.display_name 
                }));
            } else if (url.pathname === '/zones') {
                if (!transport) {
                    res.statusCode = 503;
                    res.end(JSON.stringify({ error: 'Not connected' }));
                    return;
                }
                transport.get_zones((err, zones) => {
                    if (err) {
                        res.statusCode = 500;
                        res.end(JSON.stringify({ error: err.message }));
                    } else {
                        res.end(JSON.stringify(zones));
                    }
                });
            } else if (url.pathname === '/control') {
                if (!transport) {
                    res.statusCode = 503;
                    res.end(JSON.stringify({ error: 'Not connected' }));
                    return;
                }
                
                let body = '';
                req.on('data', chunk => { body += chunk; });
                req.on('end', () => {
                    try {
                        const { zone_id, control } = JSON.parse(body);
                        transport.control(zone_id, control, (err) => {
                            if (err) {
                                res.statusCode = 500;
                                res.end(JSON.stringify({ error: err.message }));
                            } else {
                                res.end(JSON.stringify({ success: true }));
                            }
                        });
                    } catch (e) {
                        res.statusCode = 400;
                        res.end(JSON.stringify({ error: 'Invalid JSON' }));
                    }
                });
            } else {
                res.statusCode = 404;
                res.end(JSON.stringify({ error: 'Not found' }));
            }
        });
        
        server.listen(\(serverPort), () => {
            console.log('Bridge server listening on port \(serverPort)');
        });
        """
        
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        print("📝 Created bridge script at: \(scriptPath)")
    }
    
    private func startNodeProcess() {
        nodeProcess = Process()
        nodeProcess?.executableURL = URL(fileURLWithPath: getNodePath())
        nodeProcess?.arguments = [getScriptPath()]
        nodeProcess?.currentDirectoryURL = URL(fileURLWithPath: "/Users/stuart/Sites/Roonamp/node_modules_bridge")
        
        let pipe = Pipe()
        nodeProcess?.standardOutput = pipe
        nodeProcess?.standardError = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let output = String(data: handle.availableData, encoding: .utf8) {
                print("🟢 Node.js: \(output)", terminator: "")
                
                Task { @MainActor in
                    if output.contains("PAIRED:") {
                        self.isConnected = true
                    } else if output.contains("UNPAIRED") {
                        self.isConnected = false
                    }
                }
            }
        }
        
        do {
            try nodeProcess?.run()
            print("✅ Node.js process started")
        } catch {
            print("❌ Failed to start Node.js: \(error)")
            errorMessage = "Failed to start Node.js: \(error.localizedDescription)"
        }
    }
    
    private func getScriptPath() -> String {
        // Use a path relative to the project
        let projectPath = "/Users/stuart/Sites/Roonamp/node_modules_bridge"
        return projectPath + "/roon-bridge.js"
    }
    
    private func getNodePath() -> String {
        // Try common Node.js locations
        let paths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node"
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return "/usr/local/bin/node" // Default
    }
    
    // MARK: - API Methods (call the Node.js HTTP server)
    
    func getStatus() async throws -> [String: Any] {
        let url = URL(string: "http://localhost:\(serverPort)/status")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    
    func getZones() async throws -> [[String: Any]] {
        let url = URL(string: "http://localhost:\(serverPort)/zones")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }
    
    func control(zoneId: String, command: String) async throws {
        let url = URL(string: "http://localhost:\(serverPort)/control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["zone_id": zoneId, "control": command]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, _) = try await URLSession.shared.data(for: request)
    }
}
