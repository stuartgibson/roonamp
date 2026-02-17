//
//  SettingsView.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var roonAPI: RoonAPI
    
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(roonAPI.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(roonAPI.isConnected ? "Connected" : "Disconnected")
                            .foregroundStyle(.secondary)
                    }
                }
                
                if roonAPI.isConnected {
                    Button("Disconnect", role: .destructive) {
                        roonAPI.disconnect()
                    }
                } else {
                    Button("Reconnect") {
                        roonAPI.connect()
                    }
                }
            }
            
            Section("Zone Selection") {
                if !roonAPI.zones.isEmpty {
                    Picker("Active Zone", selection: Binding(
                        get: { 
                            roonAPI.currentZone?.id ?? ""
                        },
                        set: { newZoneId in
                            if let selectedZone = roonAPI.zones.first(where: { $0.id == newZoneId }) {
                                roonAPI.currentZone = selectedZone
                            }
                        }
                    )) {
                        ForEach(roonAPI.zones) { zone in
                            Text(zone.displayName)
                                .tag(zone.id)
                        }
                    }
                    
                    if let currentZone = roonAPI.currentZone {
                        LabeledContent("State") {
                            Text(currentZone.state.rawValue.capitalized)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if roonAPI.isConnected {
                    Text("No zones available")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect to see available zones")
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Extension ID", value: "com.yourcompany.roonamp")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
    }
}

#Preview {
    SettingsView()
        .environmentObject(RoonAPI(
            appInfo: RoonAppInfo(
                extensionId: "com.yourcompany.roonamp",
                displayName: "Roonamp",
                displayVersion: "1.0.0",
                publisher: "Your Name",
                email: "your.email@example.com"
            )
        ))
}
