//
//  RoonampBridgeApp.swift
//  RoonampBridge
//
//  Created by Stuart Gibson on 12/02/2026.
//

import SwiftUI

@main
struct RoonampBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) var appDelegate
    
    var body: some Scene {
        // No window - this runs in background
        Settings {
            EmptyView()
        }
    }
}

class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    var nodeProcess: Process?
    var httpServer: HTTPServer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)
        
        print("🟢 RoonampBridge starting...")
        
        // Start the HTTP server that wraps the Roon API
        httpServer = HTTPServer()
        httpServer?.start()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("🔴 RoonampBridge stopping...")
        httpServer?.stop()
    }
}
