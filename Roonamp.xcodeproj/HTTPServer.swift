//
//  HTTPServer.swift
//  RoonampBridge
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation

/// Simple HTTP server that wraps the Roon Node.js API
class HTTPServer {
    private var nodeProcess: Process?
    
    func start() {
        print("🚀 Starting Roon bridge HTTP server...")
        
        // Get the path to the bundled Node.js resources
        guard let resourcePath = Bundle.main.resourcePath else {
            print("❌ Could not find resource path")
            return
        }
        
        let nodePath = findNodePath()
        let scriptPath = "\(resourcePath)/roon-bridge/server.js"
        let nodeModulesPath = "\(resourcePath)/roon-bridge"
        
        print("📂 Node path: \(nodePath)")
        print("📂 Script path: \(scriptPath)")
        print("📂 Node modules: \(nodeModulesPath)")
        
        // Verify script exists
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            print("❌ server.js not found at \(scriptPath)")
            print("💡 Make sure to add the roon-bridge folder to the helper app's Copy Bundle Resources")
            return
        }
        
        nodeProcess = Process()
        nodeProcess?.executableURL = URL(fileURLWithPath: nodePath)
        nodeProcess?.arguments = [scriptPath]
        nodeProcess?.environment = [
            "NODE_PATH": "\(nodeModulesPath)/node_modules",
            "PATH": "\(nodePath.replacingOccurrences(of: "/node", with: "")):/usr/local/bin:/usr/bin:/bin"
        ]
        
        let pipe = Pipe()
        nodeProcess?.standardOutput = pipe
        nodeProcess?.standardError = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let output = String(data: handle.availableData, encoding: .utf8), !output.isEmpty {
                print("Node.js: \(output)", terminator: "")
            }
        }
        
        do {
            try nodeProcess?.run()
            print("✅ Node.js server started")
        } catch {
            print("❌ Failed to start Node.js: \(error)")
        }
    }
    
    func stop() {
        nodeProcess?.terminate()
    }
    
    private func findNodePath() -> String {
        // Check common Node.js locations
        let paths = [
            NSHomeDirectory() + "/.nvm/versions/node/v24.8.0/bin/node",
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node"
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // Try to find in NVM directory
        let nvmDir = NSHomeDirectory() + "/.nvm/versions/node"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nvmDir).sorted().reversed() {
            for version in contents {
                let nodePath = "\(nvmDir)/\(version)/bin/node"
                if FileManager.default.fileExists(atPath: nodePath) {
                    return nodePath
                }
            }
        }
        
        return "/usr/local/bin/node"
    }
}
