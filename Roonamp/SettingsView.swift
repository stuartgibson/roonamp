//
//  SettingsView.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var roonAPI: RoonAPI
    @EnvironmentObject var skinManager: WinampSkinManager
    @AppStorage("windowScale") private var windowScale: Double = 2.0
    @AppStorage("displayKbps") private var displayKbps: String = ""
    @AppStorage("displayKHz") private var displayKHz: String = ""
    @State private var showingSkinImporter = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var showingRemoveConfirmation = false

    private var currentSkinEntry: SkinEntry? {
        guard let name = skinManager.currentSkin?.name else { return nil }
        return skinManager.availableSkins.first(where: { $0.name == name })
    }

    var body: some View {
        Form {
            Section("Appearance") {
                if !skinManager.availableSkins.isEmpty {
                    Picker("Winamp Skin", selection: Binding(
                        get: { skinManager.currentSkin?.name ?? "" },
                        set: { skinManager.selectSkin(named: $0) }
                    )) {
                        ForEach(skinManager.availableSkins) { entry in
                            Text(entry.name).tag(entry.name)
                        }
                    }
                } else {
                    Text("No skins available")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Import Skin...") {
                        showingSkinImporter = true
                    }

                    if let entry = currentSkinEntry, skinManager.isRemovable(entry) {
                        Button("Remove Skin", role: .destructive) {
                            showingRemoveConfirmation = true
                        }
                    }
                }

                Toggle("Always on Top", isOn: $roonAPI.alwaysOnTop)

                Picker("Window Size", selection: $windowScale) {
                    Text("1x").tag(1.0)
                    Text("1.5x").tag(1.5)
                    Text("2x").tag(2.0)
                }
            }
            
            Section {
                TextField("Bitrate (kbps)", text: $displayKbps)
                    .textFieldStyle(.roundedBorder)
                TextField("Sample rate (kHz)", text: $displayKHz)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Info Display")
            } footer: {
                Text("The Roon API does not provide bitrate or sample rate information. These values are shown as static text in the main window display.")
                    .foregroundStyle(.secondary)
            }

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
                if roonAPI.isZoneUnavailable, let name = roonAPI.preferredZoneName {
                    LabeledContent("Selected Zone") {
                        HStack {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            Text("\(name) — No Connection")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !roonAPI.zones.isEmpty {
                    Picker("Active Zone", selection: Binding(
                        get: {
                            roonAPI.currentZone?.id ?? ""
                        },
                        set: { newZoneId in
                            if let selectedZone = roonAPI.zones.first(where: { $0.id == newZoneId }) {
                                roonAPI.selectZone(selectedZone)
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
        .frame(width: 450, height: 500)
        .fileImporter(
            isPresented: $showingSkinImporter,
            allowedContentTypes: [UTType(filenameExtension: "wsz") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    try skinManager.importSkin(from: url)
                } catch {
                    importError = error.localizedDescription
                    showingImportError = true
                }
            case .failure(let error):
                importError = error.localizedDescription
                showingImportError = true
            }
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK") {}
        } message: {
            Text(importError ?? "Unknown error")
        }
        .alert("Remove Skin", isPresented: $showingRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                if let entry = currentSkinEntry {
                    do {
                        try skinManager.removeSkin(entry)
                    } catch {
                        importError = error.localizedDescription
                        showingImportError = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \"\(skinManager.currentSkin?.name ?? "")\"? The skin file will be deleted.")
        }
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
