//
//  WinampSkinManager.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Combine

/// Manages Winamp skins
@MainActor
class WinampSkinManager: ObservableObject {
    @Published var availableSkins: [WinampSkin] = []
    @Published var currentSkin: WinampSkin? {
        didSet { UserDefaults.standard.set(currentSkin?.name, forKey: "selectedSkin") }
    }

    init() {
        loadAvailableSkins()
    }
    
    func loadAvailableSkins() {
        print("🎨 Loading available Winamp skins...")
        
        var skins: [WinampSkin] = []
        
        // Load skins from main bundle
        if let skinURLs = Bundle.main.urls(forResourcesWithExtension: "wsz", subdirectory: nil) {
            for url in skinURLs {
                if let skin = WinampSkinParser.parse(url: url) {
                    skins.append(skin)
                }
            }
        }
        
        // Also check application support directory for user-added skins
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let skinsDir = appSupport.appendingPathComponent("Roonamp/Skins")
            
            if !FileManager.default.fileExists(atPath: skinsDir.path) {
                try? FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)
            }
            
            if let skinURLs = try? FileManager.default.contentsOfDirectory(at: skinsDir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "wsz" }) {
                for url in skinURLs {
                    if let skin = WinampSkinParser.parse(url: url) {
                        skins.append(skin)
                    }
                }
            }
        }
        
        availableSkins = skins
        print("✅ Loaded \(skins.count) Winamp skin(s)")
        
        // Restore saved skin or fall back to first available
        if currentSkin == nil {
            if let saved = UserDefaults.standard.string(forKey: "selectedSkin"),
               let match = skins.first(where: { $0.name == saved }) {
                currentSkin = match
            } else if let first = skins.first {
                currentSkin = first
            }
        }
    }
    
    func importSkin(from url: URL) throws {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "WinampSkinManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find Application Support directory"])
        }
        let skinsDir = appSupport.appendingPathComponent("Roonamp/Skins")
        try FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)

        let destination = skinsDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)

        loadAvailableSkins()

        let importedName = url.deletingPathExtension().lastPathComponent
        selectSkin(named: importedName)
    }

    func isRemovable(_ skin: WinampSkin) -> Bool {
        guard let url = skin.sourceURL else { return false }
        return !url.path.hasPrefix(Bundle.main.bundlePath)
    }

    func removeSkin(_ skin: WinampSkin) throws {
        guard let url = skin.sourceURL, isRemovable(skin) else { return }
        try FileManager.default.removeItem(at: url)

        let wasSelected = currentSkin?.name == skin.name
        loadAvailableSkins()

        if wasSelected {
            currentSkin = availableSkins.first
        }
    }

    func selectSkin(named name: String) {
        if let skin = availableSkins.first(where: { $0.name == name }) {
            currentSkin = skin
            print("🎨 Selected skin: \(name)")
        }
    }
}
