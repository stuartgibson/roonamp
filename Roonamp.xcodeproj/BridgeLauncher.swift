//
//  BridgeLauncher.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import ServiceManagement

/// Manages the RoonampBridge helper app
@MainActor
class BridgeLauncher: ObservableObject {
    @Published var isRunning = false
    
    func launch() {
        print("🚀 Launching RoonampBridge helper...")
        
        // Get path to the helper app inside our bundle
        guard let helperPath = Bundle.main.path(forResource: "RoonampBridge", ofType: "app", inDirectory: "Contents/Library/LoginItems") ??
                               Bundle.main.bundlePath.appending("/Contents/Library/LoginItems/RoonampBridge.app") as String? else {
            print("❌ Could not find RoonampBridge.app")
            launchFallback()
            return
        }
        
        print("📂 Helper app path: \(helperPath)")
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: helperPath),
                                          configuration: configuration) { app, error in
            if let error = error {
                print("❌ Failed to launch helper: \(error)")
                Task { @MainActor in
                    self.launchFallback()
                }
            } else {
                print("✅ Helper app launched")
                Task { @MainActor in
                    self.isRunning = true
                }
            }
        }
    }
    
    private func launchFallback() {
        // If helper app isn't bundled yet, show instruction
        print("💡 For development: Run the Node.js server manually:")
        print("   cd /Users/stuart/Sites/Roonamp/roon-bridge-server")
        print("   node server.js")
        
        // Check if the manual server is running
        checkIfServerRunning()
    }
    
    private func checkIfServerRunning() {
        Task {
            do {
                let url = URL(string: "http://localhost:3000/status")!
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    print("✅ Server is already running")
                    isRunning = true
                }
            } catch {
                print("⚠️ Server not running. Please start it manually for now.")
            }
        }
    }
}
