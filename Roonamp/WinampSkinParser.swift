//
//  WinampSkinParser.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import AppKit
import SwiftUI

/// Parses Winamp .wsz skin files
@MainActor
class WinampSkinParser {
    
    /// Parse a .wsz file (which is a zip archive)
    static func parse(url: URL) -> WinampSkin? {
        print("🎨 Parsing Winamp skin: \(url.lastPathComponent)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ Skin file not found: \(url.path)")
            return nil
        }
        
        // Create temporary directory for extraction
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Extract the zip file using macOS unzip command
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-oq", url.path, "-d", tempDir.path]
            
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                print("❌ Failed to extract zip file")
                return nil
            }
            
            print("✅ Extracted skin to: \(tempDir.path)")

            // Some skins nest files inside a subdirectory — detect and use it
            let skinDir: URL
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            let hasBmp = contents.contains(where: { $0.lowercased().hasSuffix(".bmp") })
            if !hasBmp, let subdir = contents.first(where: {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: tempDir.appendingPathComponent($0).path, isDirectory: &isDir)
                return isDir.boolValue
            }) {
                skinDir = tempDir.appendingPathComponent(subdir)
            } else {
                skinDir = tempDir
            }

            // Load bitmap images
            let mainBMP = loadBitmap(named: "main.bmp", in: skinDir)
            let titlebarBMP = loadBitmap(named: "titlebar.bmp", in: skinDir)
            let cbuttonsBMP = loadBitmap(named: "cbuttons.bmp", in: skinDir)
            let posbarBMP = loadBitmap(named: "posbar.bmp", in: skinDir)
            let volumeBMP = loadBitmap(named: "volume.bmp", in: skinDir)
            let playpausBMP = loadBitmap(named: "playpaus.bmp", in: skinDir)
            let textBMP = loadBitmap(named: "text.bmp", in: skinDir)
            let numbersBMP = loadBitmap(named: "numbers.bmp", in: skinDir) ?? loadBitmap(named: "nums_ex.bmp", in: skinDir)
            let monosterBMP = loadBitmap(named: "monoster.bmp", in: skinDir)
            let shufrepBMP = loadBitmap(named: "shufrep.bmp", in: skinDir)
            let balanceBMP = loadBitmap(named: "balance.bmp", in: skinDir)
            let visColors = loadVisColors(in: skinDir)
            let regions = loadRegions(in: skinDir)
            let pleditBMP = loadBitmap(named: "pledit.bmp", in: skinDir)
            let pleditColors = loadPlaylistColors(in: skinDir)

            let skinName = url.deletingPathExtension().lastPathComponent

            let skin = WinampSkin(
                name: skinName,
                sourceURL: url,
                mainWindowBitmap: mainBMP,
                titleBarBitmap: titlebarBMP,
                playPauseBitmap: cbuttonsBMP,
                positionBarBitmap: posbarBMP,
                volumeBitmap: volumeBMP,
                playpausBitmap: playpausBMP,
                textBitmap: textBMP,
                numbersBitmap: numbersBMP,
                monosterBitmap: monosterBMP,
                shuffleRepeatBitmap: shufrepBMP,
                balanceBitmap: balanceBMP,
                visColors: visColors,
                normalRegion: regions["Normal"],
                windowShadeRegion: regions["WindowShade"],
                playlistBitmap: pleditBMP,
                playlistColors: pleditColors
            )
            
            print("✅ Successfully loaded Winamp skin: \(skinName)")
            return skin
            
        } catch {
            print("❌ Failed to parse skin: \(error)")
            return nil
        }
    }
    
    private static func loadVisColors(in directory: URL) -> [Color] {
        // Default Winamp viscolors
        let defaults: [(Int, Int, Int)] = [
            (0,0,0), (24,33,41),
            (239,49,16), (206,41,16), (214,90,0), (214,102,0),
            (214,115,0), (198,123,8), (222,165,24), (214,181,33),
            (189,222,41), (148,222,33), (41,206,16), (50,190,16),
            (57,181,16), (49,156,8), (41,148,0), (24,132,8),
            (255,255,255), (214,214,222), (181,189,189), (160,170,175),
            (148,156,165), (150,150,150)
        ]
        var colors = defaults.map { Color(red: Double($0.0)/255, green: Double($0.1)/255, blue: Double($0.2)/255) }

        // Try to load VISCOLOR.TXT (case-insensitive search)
        let allFiles = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let visFileName = allFiles.first(where: { $0.lowercased() == "viscolor.txt" }) else { return colors }
        let fileURL = directory.appendingPathComponent(visFileName)
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where i < 24 {
                // Strip // comments and split by comma, space, or tab
                let stripped = line.components(separatedBy: "//").first ?? line
                let parts = stripped.components(separatedBy: CharacterSet(charactersIn: ", \t"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard parts.count >= 3,
                      let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) else { continue }
                colors[i] = Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
            }
            print("  ✅ Loaded: \(visFileName)")
        }
        return colors
    }

    private static func loadRegions(in directory: URL) -> [String: [[CGPoint]]] {
        let allFiles = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let regionFileName = allFiles.first(where: { $0.lowercased() == "region.txt" }) else { return [:] }
        let fileURL = directory.appendingPathComponent(regionFileName)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }

        var result: [String: [[CGPoint]]] = [:]
        var currentSection: String?
        var currentNumPoints: [Int] = []

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Section header e.g. [Normal]
            if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") {
                currentSection = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
                currentNumPoints = []
                continue
            }
            guard let section = currentSection else { continue }

            if trimmed.lowercased().hasPrefix("numpoints=") {
                let value = String(trimmed.dropFirst("numpoints=".count))
                currentNumPoints = value.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } else if trimmed.lowercased().hasPrefix("pointlist=") {
                let value = String(trimmed.dropFirst("pointlist=".count))
                let coords = value.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

                var polygons: [[CGPoint]] = []
                var idx = 0
                for count in currentNumPoints {
                    var points: [CGPoint] = []
                    for _ in 0..<count {
                        guard idx + 1 < coords.count else { break }
                        points.append(CGPoint(x: coords[idx], y: coords[idx + 1]))
                        idx += 2
                    }
                    if points.count >= 3 {
                        polygons.append(points)
                    }
                }
                result[section] = polygons
            }
        }

        if !result.isEmpty {
            print("  ✅ Loaded: \(regionFileName) (\(result.keys.joined(separator: ", ")))")
        }
        return result
    }

    private static func loadPlaylistColors(in directory: URL) -> PlaylistColors {
        let allFiles = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let pleditFileName = allFiles.first(where: { $0.lowercased() == "pledit.txt" }) else {
            return .default
        }
        let fileURL = directory.appendingPathComponent(pleditFileName)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return .default
        }

        var normal: Color?
        var current: Color?
        var normalBG: Color?
        var selectedBG: Color?
        var font: String?
        var inTextSection = false

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "[text]" {
                inTextSection = true
                continue
            }
            if trimmed.hasPrefix("[") {
                inTextSection = false
                continue
            }
            guard inTextSection else { continue }

            let parts = trimmed.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "normal": normal = parseHexColor(value)
            case "current": current = parseHexColor(value)
            case "normalbg": normalBG = parseHexColor(value)
            case "selectedbg": selectedBG = parseHexColor(value)
            case "font": font = value
            default: break
            }
        }

        let result = PlaylistColors(
            normal: normal ?? PlaylistColors.default.normal,
            current: current ?? PlaylistColors.default.current,
            normalBG: normalBG ?? PlaylistColors.default.normalBG,
            selectedBG: selectedBG ?? PlaylistColors.default.selectedBG,
            font: font ?? PlaylistColors.default.font
        )
        print("  ✅ Loaded: \(pleditFileName)")
        return result
    }

    private static func parseHexColor(_ hex: String) -> Color? {
        var str = hex.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("#") { str = String(str.dropFirst()) }
        guard str.count == 6, let value = UInt64(str, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    private static func loadBitmap(named filename: String, in directory: URL) -> NSImage? {
        let fileURL = directory.appendingPathComponent(filename)
        
        // Try exact filename
        if let image = NSImage(contentsOf: fileURL) {
            print("  ✅ Loaded: \(filename)")
            return image
        }
        
        // Try lowercase
        let lowercaseURL = directory.appendingPathComponent(filename.lowercased())
        if let image = NSImage(contentsOf: lowercaseURL) {
            print("  ✅ Loaded: \(filename.lowercased())")
            return image
        }
        
        // Try uppercase
        let uppercaseURL = directory.appendingPathComponent(filename.uppercased())
        if let image = NSImage(contentsOf: uppercaseURL) {
            print("  ✅ Loaded: \(filename.uppercased())")
            return image
        }
        
        print("  ⚠️ Not found: \(filename)")
        return nil
    }
}
