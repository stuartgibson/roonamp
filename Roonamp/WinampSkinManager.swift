//
//  WinampSkinManager.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Combine

/// Lightweight metadata for a skin (no parsed bitmaps)
struct SkinEntry: Identifiable {
    let name: String
    let sourceURL: URL
    var id: String { name }
}

/// Manages Winamp skins
@MainActor
class WinampSkinManager: ObservableObject {
    @Published var availableSkins: [SkinEntry] = []
    @Published var currentSkin: WinampSkin? {
        didSet { UserDefaults.standard.set(currentSkin?.name, forKey: "selectedSkin") }
    }
    /// Cached sprite cache for the current skin — survives view recreation (e.g. windowshade toggle)
    var currentSpriteCache: SpriteCache?

    init() {
        loadAvailableSkins()
    }

    func loadAvailableSkins() {
        print("🎨 Loading available Winamp skins...")

        var entries: [SkinEntry] = []

        // Collect skins from main bundle (metadata only)
        if let skinURLs = Bundle.main.urls(forResourcesWithExtension: "wsz", subdirectory: nil) {
            for url in skinURLs {
                let name = url.deletingPathExtension().lastPathComponent
                entries.append(SkinEntry(name: name, sourceURL: url))
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
                    let name = url.deletingPathExtension().lastPathComponent
                    entries.append(SkinEntry(name: name, sourceURL: url))
                }
            }
        }

        availableSkins = entries
        print("✅ Found \(entries.count) Winamp skin(s)")

        // Restore saved skin or fall back to first available — parse on demand
        if currentSkin == nil {
            let saved = UserDefaults.standard.string(forKey: "selectedSkin")
            let target = entries.first(where: { $0.name == saved }) ?? entries.first
            if let entry = target {
                selectSkin(named: entry.name)
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

    func isRemovable(_ entry: SkinEntry) -> Bool {
        return !entry.sourceURL.path.hasPrefix(Bundle.main.bundlePath)
    }

    func removeSkin(_ entry: SkinEntry) throws {
        guard isRemovable(entry) else { return }
        try FileManager.default.removeItem(at: entry.sourceURL)

        let wasSelected = currentSkin?.name == entry.name
        loadAvailableSkins()

        if wasSelected {
            if let first = availableSkins.first {
                selectSkin(named: first.name)
            } else {
                currentSkin = nil
            }
        }
    }

    func selectSkin(named name: String) {
        guard let entry = availableSkins.first(where: { $0.name == name }) else { return }
        if currentSkin?.name == name { return }
        if let skin = WinampSkinParser.parse(url: entry.sourceURL) {
            currentSpriteCache = nil
            currentSkin = skin
            print("🎨 Selected skin: \(name)")
        }
    }

    /// Nil out source bitmaps that are no longer needed after sprite cache is built.
    /// Keeps playlistBitmap, textBitmap, and titleBarBitmap (needed at runtime).
    func clearSourceBitmaps() {
        currentSkin?.mainWindowBitmap = nil
        currentSkin?.playPauseBitmap = nil
        currentSkin?.positionBarBitmap = nil
        currentSkin?.volumeBitmap = nil
        currentSkin?.balanceBitmap = nil
        currentSkin?.playpausBitmap = nil
        currentSkin?.numbersBitmap = nil
        currentSkin?.monosterBitmap = nil
        currentSkin?.shuffleRepeatBitmap = nil
    }
}
