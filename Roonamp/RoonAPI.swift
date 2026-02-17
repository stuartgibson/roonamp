//
//  RoonAPI.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Combine

/// Main class for communicating with Roon Core via HTTP bridge
@MainActor
class RoonAPI: ObservableObject {
    @Published var isConnected = false
    @Published var zones: [RoonZone] = []
    @Published var currentZone: RoonZone? {
        didSet {
            // Save the selected zone ID whenever it changes
            if let zoneId = currentZone?.id {
                UserDefaults.standard.set(zoneId, forKey: "lastSelectedZoneId")
                print("💾 Saved last zone: \(currentZone?.displayName ?? "") (ID: \(zoneId))")
            }
            // Clear history when switching to a different zone
            if oldValue?.id != currentZone?.id {
                queueHistory = []
                queueItems = []
                // Restore saved queue if this is the initial zone load (oldValue was nil)
                if oldValue == nil {
                    restoreQueueState()
                }
            }
        }
    }
    @Published var errorMessage: String?
    @Published var queueItems: [QueueItem] = []
    @Published var queueHistory: [QueueItem] = []
    @Published var isPlaylistVisible: Bool {
        didSet {
            UserDefaults.standard.set(isPlaylistVisible, forKey: "isPlaylistVisible")
        }
    }
    @Published var isAlbumArtVisible: Bool {
        didSet {
            UserDefaults.standard.set(isAlbumArtVisible, forKey: "isAlbumArtVisible")
        }
    }
    @Published var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
            NotificationCenter.default.post(name: .alwaysOnTopChanged, object: alwaysOnTop)
        }
    }
    
    private let appInfo: RoonAppInfo
    private let bridgeURL = "http://localhost:3000"
    private var statusTimer: Timer?
    
    init(appInfo: RoonAppInfo) {
        self.appInfo = appInfo
        // Restore preferences
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        self.isPlaylistVisible = UserDefaults.standard.bool(forKey: "isPlaylistVisible")
        self.isAlbumArtVisible = UserDefaults.standard.bool(forKey: "isAlbumArtVisible")
    }
    
    // MARK: - Connection Management
    
    func connect() {
        print("🔌 Connecting to Roon bridge at \(bridgeURL)")
        print("💡 Make sure the Node.js server is running:")
        print("   cd /Users/stuart/Sites/Roonamp/roon-bridge-server && node server.js")
        
        startPolling()
    }
    
    func disconnect() {
        print("🔌 Disconnecting")
        stopPolling()
        isConnected = false
    }
    
    private func startPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateStatus()
            }
        }
    }
    
    private func stopPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
    
    private func updateStatus() async {
        // Check connection status
        do {
            let url = URL(string: "\(bridgeURL)/status")!
            let (data, response) = try await URLSession.shared.data(from: url)
            
            // Server is running if we get a response
            errorMessage = nil
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let connected = json["connected"] as? Bool {
                isConnected = connected
                
                if !connected {
                    // Server is running but not paired with Roon Core
                    print("⏳ Bridge server running, waiting for Roon Core to pair...")
                    errorMessage = "Waiting for Roon Core connection. Please enable the extension in Roon Settings > Extensions."
                }
                
                if connected {
                    await updateZones()
                    if isPlaylistVisible {
                        await fetchQueue()
                    }
                }
            }
        } catch {
            isConnected = false
            print("❌ Bridge server not reachable: \(error.localizedDescription)")
            if errorMessage == nil {
                errorMessage = "Bridge not running. Start it with: cd /Users/stuart/Sites/Roonamp/roon-bridge-server && node server.js"
            }
        }
    }
    
    private func updateZones() async {
        do {
            let url = URL(string: "\(bridgeURL)/zones")!
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Debug: Print raw response
            if let rawString = String(data: data, encoding: .utf8) {
                print("🔍 Raw zones response: \(rawString.prefix(500))...")
            }
            
            // Try to parse as generic JSON first to see the structure
            if let json = try? JSONSerialization.jsonObject(with: data) {
                print("🔍 JSON type: \(type(of: json))")
                
                // Check if it's a dictionary with a "zones" key containing the actual zones
                if let wrapper = json as? [String: Any] {
                    print("🔍 Top-level keys: \(wrapper.keys)")
                    
                    // First: Check if zones are an ARRAY under "zones" key
                    if let zonesArray = wrapper["zones"] as? [[String: Any]] {
                        print("🔍 Found zones array with \(zonesArray.count) zones")
                        var newZones: [RoonZone] = []
                        for zoneData in zonesArray {
                            if let zone = parseZone(from: zoneData) {
                                newZones.append(zone)
                            }
                        }
                        updateZonesList(with: newZones)
                        return
                    }
                    
                    // Second: Check if zones are a DICTIONARY under "zones" key
                    if let zonesDict = wrapper["zones"] as? [String: [String: Any]] {
                        print("🔍 Found nested zones dictionary with \(zonesDict.count) zones")
                        parseAndUpdateZones(from: zonesDict)
                        return
                    }
                    
                    // Third: Maybe the wrapper itself is the zones dict (no "zones" key)
                    let firstKey = wrapper.keys.first ?? ""
                    if firstKey != "zones" && firstKey != "error" {
                        if let zonesDict = json as? [String: [String: Any]] {
                            print("🔍 Parsed top-level as zones dictionary with \(zonesDict.count) zones")
                            parseAndUpdateZones(from: zonesDict)
                            return
                        }
                    }
                }
                
                // Maybe it's an array at the top level?
                if let zonesArray = json as? [[String: Any]] {
                    print("🔍 Parsed as top-level zones array with \(zonesArray.count) zones")
                    var newZones: [RoonZone] = []
                    for zoneData in zonesArray {
                        if let zone = parseZone(from: zoneData) {
                            newZones.append(zone)
                        }
                    }
                    updateZonesList(with: newZones)
                    return
                }
                
                print("⚠️ Unknown JSON structure")
            } else {
                print("⚠️ Failed to parse as JSON at all")
            }
        } catch {
            print("⚠️ Failed to get zones: \(error)")
        }
    }
    
    private func parseAndUpdateZones(from zonesDict: [String: [String: Any]]) {
        var newZones: [RoonZone] = []
        
        for (zoneId, zoneData) in zonesDict {
            print("🔍 Processing zone: \(zoneId)")
            if let zone = parseZone(from: zoneData) {
                newZones.append(zone)
            }
        }
        
        updateZonesList(with: newZones)
    }
    
    private func updateZonesList(with newZones: [RoonZone]) {
        print("🔍 Total zones parsed: \(newZones.count)")
        
        // Store the currently selected zone ID before updating
        let selectedZoneId = currentZone?.id
        
        // Update the zones list
        zones = newZones
        
        // Try to restore the zone in this order:
        // 1. Currently selected zone (if switching zones manually)
        // 2. Last saved zone from UserDefaults (on app launch)
        // 3. First available zone (fallback)
        
        if let selectedZoneId = selectedZoneId {
            // User has manually selected a zone - keep it
            print("🔍 Looking for currently selected zone: \(selectedZoneId)")
            if let updatedZone = zones.first(where: { $0.id == selectedZoneId }) {
                currentZone = updatedZone
                print("✅ Found and updated current zone: \(updatedZone.displayName) - nowPlaying: \(updatedZone.nowPlaying?.title ?? "none")")
            } else {
                print("⚠️ Selected zone \(selectedZoneId) not found in updated zones")
                // Selected zone no longer exists, try to restore from UserDefaults
                restoreLastZone()
            }
        } else {
            // No zone currently selected, try to restore from UserDefaults
            restoreLastZone()
        }
    }
    
    private func restoreLastZone() {
        // Try to restore the last saved zone
        if let lastZoneId = UserDefaults.standard.string(forKey: "lastSelectedZoneId") {
            print("💾 Attempting to restore last zone: \(lastZoneId)")
            if let restoredZone = zones.first(where: { $0.id == lastZoneId }) {
                currentZone = restoredZone
                print("✅ Restored last zone: \(restoredZone.displayName)")
                return
            } else {
                print("⚠️ Last zone \(lastZoneId) not found, using first available zone")
            }
        }
        
        // Fallback to first zone
        currentZone = zones.first
        if let zone = currentZone {
            print("🔍 Set default zone: \(zone.displayName)")
        }
    }
    
    private func parseZone(from data: [String: Any]) -> RoonZone? {
        guard let zoneId = data["zone_id"] as? String,
              let displayName = data["display_name"] as? String else {
            print("⚠️ Missing zone_id or display_name")
            return nil
        }
        
        print("📋 Parsing zone: \(displayName) (ID: \(zoneId))")
        
        // State can be at the top level or inside now_playing
        var state: RoonZone.PlaybackState = .stopped
        
        var nowPlaying: NowPlaying?
        if let nowPlayingData = data["now_playing"] as? [String: Any] {
            print("  📀 Now playing data found")
            
            // Check for state in now_playing first (more accurate)
            if let stateStr = nowPlayingData["state"] as? String {
                print("  State (from now_playing): \(stateStr)")
                switch stateStr {
                case "playing": state = .playing
                case "paused": state = .paused
                case "loading": state = .loading
                default: state = .stopped
                }
            }
            
            if let threeLine = nowPlayingData["three_line"] as? [String: Any] {
                let title = threeLine["line1"] as? String ?? "Unknown"
                let artist = threeLine["line2"] as? String ?? ""
                let album = threeLine["line3"] as? String ?? ""
                
                print("    Title: \(title)")
                print("    Artist: \(artist)")
                print("    Album: \(album)")
                
                // Get the image_key and construct the proper URL via the bridge
                var imageUrl: String?
                let rawImageKey = nowPlayingData["image_key"] as? String
                if let imageKey = rawImageKey {
                    print("    Image key: \(imageKey)")
                    imageUrl = "\(bridgeURL)/image/\(imageKey)"
                    print("    Image URL: \(imageUrl ?? "nil")")
                }
                
                // Extract format info if available
                var sampleRate: Int?
                var bitsPerSample: Int?
                var channels: Int?
                if let format = nowPlayingData["format"] as? [String: Any] {
                    sampleRate = format["sample_rate"] as? Int
                    bitsPerSample = format["bits_per_sample"] as? Int
                    channels = format["channels"] as? Int
                }

                nowPlaying = NowPlaying(
                    queueItemId: nowPlayingData["queue_item_id"] as? Int,
                    title: title,
                    artist: artist,
                    album: album,
                    imageKey: rawImageKey,
                    imageUrl: imageUrl,
                    length: nowPlayingData["length"] as? Int,
                    seekPosition: nowPlayingData["seek_position"] as? Int,
                    sampleRate: sampleRate,
                    bitsPerSample: bitsPerSample,
                    channels: channels
                )
            } else {
                print("  ⚠️ No three_line found in now_playing")
                print("  Keys available: \(nowPlayingData.keys)")
            }
        } else {
            print("  ⚠️ No now_playing data for this zone")
        }
        
        // Fall back to top-level state if not found in now_playing
        if state == .stopped, let stateStr = data["state"] as? String {
            print("  State (from top level): \(stateStr)")
            switch stateStr {
            case "playing": state = .playing
            case "paused": state = .paused
            case "loading": state = .loading
            default: state = .stopped
            }
        }
        
        // Parse zone settings (shuffle, loop, auto_radio)
        var zoneSettings: ZoneSettings?
        if let settingsData = data["settings"] as? [String: Any] {
            let loopStr = settingsData["loop"] as? String ?? "disabled"
            let loop: LoopMode
            switch loopStr {
            case "loop": loop = .loop
            case "loop_one": loop = .loopOne
            default: loop = .disabled
            }
            let shuffle = settingsData["shuffle"] as? Bool ?? false
            let autoRadio = settingsData["auto_radio"] as? Bool ?? false
            zoneSettings = ZoneSettings(loop: loop, shuffle: shuffle, autoRadio: autoRadio)
        }

        // Parse volume from first output
        var volumeInfo: VolumeInfo?
        if let outputs = data["outputs"] as? [[String: Any]],
           let firstOutput = outputs.first,
           let outputId = firstOutput["output_id"] as? String,
           let volData = firstOutput["volume"] as? [String: Any] {
            let type = volData["type"] as? String ?? "number"
            let min = (volData["min"] as? NSNumber)?.doubleValue ?? 0
            let max = (volData["max"] as? NSNumber)?.doubleValue ?? 100
            let value = (volData["value"] as? NSNumber)?.doubleValue ?? 0
            let step = (volData["step"] as? NSNumber)?.doubleValue ?? 1
            volumeInfo = VolumeInfo(outputId: outputId, type: type, min: min, max: max, value: value, step: step)
        }

        let zone = RoonZone(id: zoneId, displayName: displayName, state: state, nowPlaying: nowPlaying, settings: zoneSettings, volume: volumeInfo)
        print("  ✅ Created zone: \(displayName) - State: \(state) - nowPlaying: \(nowPlaying != nil ? "YES" : "NO")")
        return zone
    }
    
    // MARK: - Transport Control
    
    func play(zoneId: String) async {
        optimisticallyUpdateState(zoneId: zoneId, newState: .playing)
        await control(zoneId: zoneId, command: "play")
    }
    
    func pause(zoneId: String) async {
        optimisticallyUpdateState(zoneId: zoneId, newState: .paused)
        await control(zoneId: zoneId, command: "pause")
    }
    
    func playPause(zoneId: String) async {
        // Toggle the state optimistically
        if let currentState = currentZone?.state {
            let newState: RoonZone.PlaybackState = currentState == .playing ? .paused : .playing
            optimisticallyUpdateState(zoneId: zoneId, newState: newState)
        }
        await control(zoneId: zoneId, command: "playpause")
    }
    
    func stop(zoneId: String) async {
        optimisticallyUpdateState(zoneId: zoneId, newState: .stopped)
        await control(zoneId: zoneId, command: "stop")
    }
    
    func next(zoneId: String) async {
        // Keep the current playback state when skipping tracks
        // (don't show loading state since it's confusing for users)
        await control(zoneId: zoneId, command: "next")
    }
    
    func previous(zoneId: String) async {
        // Keep the current playback state when skipping tracks
        // (don't show loading state since it's confusing for users)
        await control(zoneId: zoneId, command: "previous")
    }
    
    func seek(zoneId: String, seconds: Int) async {
        await control(zoneId: zoneId, command: "seek/\(seconds)")
    }

    func toggleShuffle(zoneId: String) async {
        print("🔀 toggleShuffle called for zone: \(zoneId), settings: \(String(describing: currentZone?.settings))")
        if var settings = currentZone?.settings {
            settings.shuffle.toggle()
            optimisticallyUpdateState(zoneId: zoneId, newSettings: settings)
            await changeSettings(zoneId: zoneId, settings: ["shuffle": settings.shuffle])
        } else {
            print("⚠️ No settings available for shuffle toggle")
        }
    }

    func cycleLoop(zoneId: String) async {
        print("🔁 cycleLoop called for zone: \(zoneId), settings: \(String(describing: currentZone?.settings))")
        if var settings = currentZone?.settings {
            settings.loop = settings.loop.next
            optimisticallyUpdateState(zoneId: zoneId, newSettings: settings)
            await changeSettings(zoneId: zoneId, settings: ["loop": settings.loop.rawValue])
        } else {
            print("⚠️ No settings available for loop cycle")
        }
    }

    func changeVolume(zoneId: String, value: Double) async {
        guard let vol = currentZone?.volume else { return }
        let clamped = min(vol.max, max(vol.min, value))
        let updatedVol = VolumeInfo(outputId: vol.outputId, type: vol.type, min: vol.min, max: vol.max, value: clamped, step: vol.step)
        optimisticallyUpdateState(zoneId: zoneId, newVolume: updatedVol)
        do {
            guard let encodedOutputId = vol.outputId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
            let urlString = "\(bridgeURL)/volume/\(encodedOutputId)"
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["how": "absolute", "value": Int(clamped)]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, _) = try await URLSession.shared.data(for: request)
            print("✅ Volume changed to \(Int(clamped)) on output \(vol.outputId)")
        } catch {
            print("❌ Failed to change volume: \(error)")
        }
    }

    private func changeSettings(zoneId: String, settings: [String: Any]) async {
        do {
            guard let encodedZoneId = zoneId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
            let urlString = "\(bridgeURL)/settings/\(encodedZoneId)"
            guard let url = URL(string: urlString) else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: settings)

            let (_, _) = try await URLSession.shared.data(for: request)
            print("✅ Sent settings change to zone \(zoneId): \(settings)")
        } catch {
            print("❌ Failed to change settings: \(error)")
        }
    }
    
    private func optimisticallyUpdateState(zoneId: String, newState: RoonZone.PlaybackState? = nil, newSettings: ZoneSettings? = nil, newVolume: VolumeInfo? = nil) {
        // Find the zone and update its state immediately for responsive UI
        if let zoneIndex = zones.firstIndex(where: { $0.id == zoneId }) {
            let zone = zones[zoneIndex]
            let updatedZone = RoonZone(
                id: zone.id,
                displayName: zone.displayName,
                state: newState ?? zone.state,
                nowPlaying: zone.nowPlaying,
                settings: newSettings ?? zone.settings,
                volume: newVolume ?? zone.volume
            )
            zones[zoneIndex] = updatedZone

            // Update currentZone if this is the selected zone
            if currentZone?.id == zoneId {
                currentZone = updatedZone
                if let newState = newState {
                    print("🎯 Optimistically updated state to: \(newState)")
                }
                if newSettings != nil {
                    print("🎯 Optimistically updated settings")
                }
            }
        }
    }
    
    func fetchQueue() async {
        guard let zoneId = currentZone?.id else { return }
        guard Date() > suppressQueueUpdatesUntil else { return }
        do {
            guard let encodedZoneId = zoneId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
            let url = URL(string: "\(bridgeURL)/queue/\(encodedZoneId)")!
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                let newItems = items.compactMap { item -> QueueItem? in
                    guard let queueItemId = item["queue_item_id"] as? Int else { return nil }
                    let threeLine = item["three_line"] as? [String: Any]
                    let title = threeLine?["line1"] as? String ?? "Unknown"
                    let artist = threeLine?["line2"] as? String ?? ""
                    let album = threeLine?["line3"] as? String ?? ""
                    let length = item["length"] as? Int
                    let imageKey = item["image_key"] as? String
                    return QueueItem(id: queueItemId, title: title, artist: artist, album: album, length: length, imageKey: imageKey)
                }

                // Detect queue changes
                if preserveHistoryOnNextQueueChange {
                    // playFromHere already updated history — just accept the new queue
                    preserveHistoryOnNextQueueChange = false
                } else if !queueItems.isEmpty && !newItems.isEmpty {
                    let newFirstId = newItems.first!.id
                    let oldIds = queueItems.map { $0.id }
                    if let idx = oldIds.firstIndex(of: newFirstId) {
                        if idx > 0 {
                            // Tracks before idx have been played — add to history
                            let played = Array(queueItems.prefix(idx))
                            queueHistory.append(contentsOf: played)
                        }
                    } else {
                        // New first item wasn't in old queue — entirely new queue, clear history
                        queueHistory.removeAll()
                    }
                }

                queueItems = newItems
                saveQueueState()
            }
        } catch {
            print("⚠️ Failed to fetch queue: \(error)")
        }
    }

    /// Clear play history (e.g. when switching zones)
    func clearQueueHistory() {
        queueHistory = []
    }

    // MARK: - Queue Persistence

    private func saveQueueState() {
        guard let zoneId = currentZone?.id else { return }
        let encoder = JSONEncoder()
        if let historyData = try? encoder.encode(queueHistory),
           let queueData = try? encoder.encode(queueItems) {
            UserDefaults.standard.set(historyData, forKey: "queueHistory")
            UserDefaults.standard.set(queueData, forKey: "queueItems")
            UserDefaults.standard.set(zoneId, forKey: "queueZoneId")
        }
    }

    private func restoreQueueState() {
        guard let zoneId = currentZone?.id,
              zoneId == UserDefaults.standard.string(forKey: "queueZoneId") else { return }
        let decoder = JSONDecoder()
        if let historyData = UserDefaults.standard.data(forKey: "queueHistory"),
           let history = try? decoder.decode([QueueItem].self, from: historyData) {
            queueHistory = history
        }
        if let queueData = UserDefaults.standard.data(forKey: "queueItems"),
           let items = try? decoder.decode([QueueItem].self, from: queueData) {
            queueItems = items
        }
    }

    /// Set before playFromHere to preserve history through the queue change
    private var preserveHistoryOnNextQueueChange = false
    /// Suppress queue updates until this time (prevents visual jumping during queue rebuild)
    private var suppressQueueUpdatesUntil: Date = .distantPast

    func playFromHere(zoneId: String, queueItemId: Int) async {
        // Build the new history and optimistic queue from our combined list
        let allItems = queueHistory + queueItems
        if let targetIndex = allItems.firstIndex(where: { $0.id == queueItemId }) {
            queueHistory = Array(allItems.prefix(targetIndex))
            queueItems = Array(allItems.suffix(from: targetIndex))
        }
        preserveHistoryOnNextQueueChange = true
        suppressQueueUpdatesUntil = Date().addingTimeInterval(3)

        do {
            guard let encodedZoneId = zoneId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
            let urlString = "\(bridgeURL)/play_from_here/\(encodedZoneId)/\(queueItemId)"
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let (_, _) = try await URLSession.shared.data(for: request)
            print("✅ Playing from queue item \(queueItemId)")
        } catch {
            print("❌ Failed to play from here: \(error)")
        }
    }

    private func control(zoneId: String, command: String) async {
        do {
            let urlString = "\(bridgeURL)/control/\(zoneId)/\(command)"
            guard let url = URL(string: urlString) else { return }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            let (_, _) = try await URLSession.shared.data(for: request)
            print("✅ Sent \(command) to zone \(zoneId)")
        } catch {
            print("❌ Failed to send control: \(error)")
        }
    }
}

// MARK: - Supporting Types

struct QueueItem: Identifiable, Hashable, Codable {
    let id: Int          // queue_item_id
    let title: String
    let artist: String
    let album: String
    let length: Int?     // seconds
    let imageKey: String?

    var durationString: String {
        guard let length = length else { return "" }
        let minutes = length / 60
        let seconds = length % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct RoonAppInfo {
    let extensionId: String
    let displayName: String
    let displayVersion: String
    let publisher: String
    let email: String
}

enum LoopMode: String, Hashable {
    case disabled
    case loop
    case loopOne = "loop_one"

    var next: LoopMode {
        switch self {
        case .disabled: return .loop
        case .loop: return .loopOne
        case .loopOne: return .disabled
        }
    }
}

struct ZoneSettings: Hashable {
    var loop: LoopMode
    var shuffle: Bool
    var autoRadio: Bool
}

struct VolumeInfo: Hashable {
    let outputId: String
    let type: String       // "number" or "db"
    let min: Double
    let max: Double
    let value: Double
    let step: Double
}

struct RoonZone: Identifiable, Hashable {
    let id: String
    let displayName: String
    let state: PlaybackState
    let nowPlaying: NowPlaying?
    let settings: ZoneSettings?
    let volume: VolumeInfo?

    enum PlaybackState: String, Hashable {
        case playing
        case paused
        case stopped
        case loading
    }

    // Hash and equality based only on ID so that zones with updated
    // nowPlaying data are still considered "the same zone"
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RoonZone, rhs: RoonZone) -> Bool {
        lhs.id == rhs.id
    }
}

struct NowPlaying: Hashable {
    let queueItemId: Int? // queue_item_id from Roon
    let title: String
    let artist: String
    let album: String
    let imageKey: String? // raw image_key from Roon
    let imageUrl: String?
    let length: Int? // seconds
    let seekPosition: Int? // seconds
    let sampleRate: Int? // Hz (e.g., 44100)
    let bitsPerSample: Int? // (e.g., 16, 24)
    let channels: Int? // (e.g., 2)

    var kbpsDisplay: Int {
        guard let sr = sampleRate, let bps = bitsPerSample, let ch = channels else { return 0 }
        return sr * bps * ch / 1000
    }

    var kHzDisplay: Int {
        guard let sr = sampleRate else { return 0 }
        return sr / 1000
    }
}
// MARK: - Roon Extension Server

import Network

/// Runs a TCP server that Roon Core can connect to
@MainActor
class RoonExtensionServer: ObservableObject {
    @Published var isRunning = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    
    private var listener: NWListener?
    private var connection: NWConnection?
    private let appInfo: RoonAppInfo
    private let port: UInt16 = 9876
    
    init(appInfo: RoonAppInfo) {
        self.appInfo = appInfo
    }
    
    func start() {
        print("🚀 Starting Roon extension server on port \(port)")
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    print("📡 Roon Core is connecting!")
                    self?.handleIncomingConnection(connection)
                }
            }
            
            listener?.start(queue: .main)
            
        } catch {
            print("❌ Failed to start server: \(error)")
            errorMessage = "Failed to start server: \(error.localizedDescription)"
        }
    }
    
    func stop() {
        listener?.cancel()
        connection?.cancel()
        isRunning = false
        isConnected = false
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        print("🎧 Server state: \(state)")
        
        switch state {
        case .ready:
            print("✅ Extension server is ready on port \(port)")
            isRunning = true
            broadcastPresence()
            
        case .failed(let error):
            print("❌ Server failed: \(error)")
            errorMessage = "Server failed: \(error.localizedDescription)"
            isRunning = false
            
        default:
            break
        }
    }
    
    private func handleIncomingConnection(_ newConnection: NWConnection) {
        print("📡 Accepting connection from Roon Core")
        self.connection = newConnection
        
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        
        newConnection.start(queue: .main)
        startReceiving()
    }
    
    private func handleConnectionState(_ state: NWConnection.State) {
        print("🔗 Connection state: \(state)")
        
        switch state {
        case .ready:
            print("✅ Connected to Roon Core!")
            isConnected = true
            
        case .failed(let error):
            print("❌ Connection failed: \(error)")
            errorMessage = "Connection failed: \(error.localizedDescription)"
            isConnected = false
            
        default:
            break
        }
    }
    
    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    await self.handleReceivedData(data)
                }
            }
            
            if !isComplete {
                self.startReceiving()
            }
        }
    }
    
    private func handleReceivedData(_ data: Data) async {
        if let message = String(data: data, encoding: .utf8) {
            print("📨 Received from Roon: \(message)")
        }
    }
    
    private func broadcastPresence() {
        print("📢 Broadcasting extension presence via SOOD")
        
        // Proper SOOD format: SOOD ROON/<version> <host>:<port> <service_id> [<display_name>]
        // Based on node-roon-api implementation
        let ipAddress = getLocalIPAddress() ?? "localhost"
        let serviceId = appInfo.extensionId
        let displayName = appInfo.displayName
        
        let message = "SOOD ROON/1.0 \(ipAddress):\(port) \(serviceId) \(displayName)\n"
        guard let data = message.data(using: .utf8) else { return }
        
        print("📤 SOOD message: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // Send to broadcast address
        let connection = NWConnection(host: .ipv4(.broadcast), port: 9003, using: .udp)
        connection.start(queue: .main)
        
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("❌ Broadcast failed: \(error)")
            } else {
                print("✅ Broadcast sent successfully")
                // Keep broadcasting periodically
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.broadcastPresence()
                }
            }
            connection.cancel()
        })
    }
    
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                
                let interface = ptr?.pointee
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: (interface?.ifa_name)!)
                    if name == "en0" || name == "en1" || name == "en7" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        
        return address
    }
}

// MARK: - Node.js Bridge
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
        const RoonApiImage = require('node-roon-api-image');
        const http = require('http');
        
        let core;
        let transport;
        let image;
        
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
                image = core.services.RoonApiImage;
            },
            core_unpaired: () => {
                console.log('UNPAIRED');
                core = null;
                transport = null;
                image = null;
            }
        });
        
        roon.init_services({
            required_services: [RoonApiTransport, RoonApiImage]
        });
        
        roon.start_discovery();
        
        const server = http.createServer((req, res) => {
            res.setHeader('Access-Control-Allow-Origin', '*');
            
            const url = new URL(req.url, `http://localhost:\(serverPort)`);
            
            if (url.pathname === '/status') {
                res.setHeader('Content-Type', 'application/json');
                res.end(JSON.stringify({ 
                    connected: !!core,
                    core_name: core?.display_name 
                }));
            } else if (url.pathname === '/zones') {
                res.setHeader('Content-Type', 'application/json');
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
                        res.end(JSON.stringify(zones || {}));
                    }
                });
            } else if (url.pathname.startsWith('/image/')) {
                // Handle image requests
                const imageKey = decodeURIComponent(url.pathname.substring(7));
                
                if (!image) {
                    res.statusCode = 503;
                    res.setHeader('Content-Type', 'application/json');
                    res.end(JSON.stringify({ error: 'Not connected' }));
                    return;
                }
                
                const options = {
                    scale: 'fit',
                    width: 600,
                    height: 600,
                    format: 'image/jpeg'
                };
                
                image.get_image(imageKey, options, (err, contentType, imageData) => {
                    if (err) {
                        res.statusCode = 404;
                        res.setHeader('Content-Type', 'application/json');
                        res.end(JSON.stringify({ error: 'Image not found' }));
                    } else {
                        res.setHeader('Content-Type', contentType);
                        res.setHeader('Cache-Control', 'public, max-age=86400');
                        res.end(imageData);
                    }
                });
            } else if (url.pathname === '/control') {
                res.setHeader('Content-Type', 'application/json');
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
                res.setHeader('Content-Type', 'application/json');
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
        let nodePath = getNodePath()
        let scriptPath = getScriptPath()
        
        // Verify Node.js exists
        guard FileManager.default.fileExists(atPath: nodePath) else {
            let errorMsg = "Node.js not found at \(nodePath). Please install Node.js from https://nodejs.org or via Homebrew: brew install node"
            print("❌ \(errorMsg)")
            errorMessage = errorMsg
            return
        }
        
        // Verify script directory exists
        let scriptDir = "/Users/stuart/Sites/Roonamp/node_modules_bridge"
        guard FileManager.default.fileExists(atPath: scriptDir) else {
            let errorMsg = "node_modules_bridge directory not found. Please run: cd /Users/stuart/Sites/Roonamp && mkdir -p node_modules_bridge && cd node_modules_bridge && npm init -y && npm install node-roon-api node-roon-api-transport node-roon-api-image"
            print("❌ \(errorMsg)")
            errorMessage = errorMsg
            return
        }
        
        print("✅ Using Node.js at: \(nodePath)")
        print("✅ Script path: \(scriptPath)")
        
        nodeProcess = Process()
        // Use the node path directly with arguments
        nodeProcess?.launchPath = nodePath
        nodeProcess?.arguments = [scriptPath]
        nodeProcess?.currentDirectoryPath = scriptDir
        
        // Set up environment to include NVM path
        var environment = ProcessInfo.processInfo.environment
        if let nvmBinPath = nodePath.components(separatedBy: "/node").first {
            let pathValue = "\(nvmBinPath):" + (environment["PATH"] ?? "")
            environment["PATH"] = pathValue
        }
        nodeProcess?.environment = environment
        
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
                    } else if output.contains("Cannot find module") {
                        self.errorMessage = "Node modules not installed. Please run: cd /Users/stuart/Sites/Roonamp/node_modules_bridge && npm install RoonLabs/node-roon-api RoonLabs/node-roon-api-transport RoonLabs/node-roon-api-image"
                    } else if output.contains("Error") || output.contains("error") {
                        self.errorMessage = "Node.js error: \(output)"
                    }
                }
            }
        }
        
        // Use launch() instead of run() for deprecated API
        nodeProcess?.launch()
        print("✅ Node.js process launched")
    }
    
    private func getScriptPath() -> String {
        let projectPath = "/Users/stuart/Sites/Roonamp/node_modules_bridge"
        return projectPath + "/roon-bridge.js"
    }
    
    private func getNodePath() -> String {
        // Hardcoded path for your NVM installation (most reliable for sandboxed apps)
        let hardcodedPath = "/Users/stuart/.nvm/versions/node/v24.8.0/bin/node"
        if FileManager.default.fileExists(atPath: hardcodedPath) {
            print("✅ Found Node.js at hardcoded path: \(hardcodedPath)")
            return hardcodedPath
        }
        
        // Try to find any NVM installation
        let nvmDir = "/Users/stuart/.nvm/versions/node"
        if let nvmContents = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for version in nvmContents.sorted().reversed() { // Use latest version
                let nodePath = "\(nvmDir)/\(version)/bin/node"
                if FileManager.default.fileExists(atPath: nodePath) {
                    print("✅ Found Node.js in NVM: \(nodePath)")
                    return nodePath
                }
            }
        }
        
        // Fallback: Try common locations
        let paths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
            "/opt/local/bin/node"
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                print("✅ Found Node.js at: \(path)")
                return path
            }
        }
        
        print("⚠️ Node.js not found, returning default path")
        return "/usr/local/bin/node"
    }
    
    // MARK: - API Methods
    
    func getStatus() async throws -> [String: Any] {
        let url = URL(string: "http://localhost:\(serverPort)/status")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    
    func getZones() async throws -> [[String: Any]] {
        let url = URL(string: "http://localhost:\(serverPort)/zones")!
        let (data, _) = try await URLSession.shared.data(from: url)
        
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let zones = dict["zones"] as? [[String: Any]] {
            return zones
        }
        return []
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

// MARK: - Notification Names
extension Notification.Name {
    static let alwaysOnTopChanged = Notification.Name("alwaysOnTopChanged")
}

