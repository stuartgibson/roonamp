//
//  RoonAPI.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import Combine

/// Main class for communicating with Roon Core via native SOOD/MOO protocols
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
            syncPlayback()
        }
    }
    let playback = PlaybackState()
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
    private let sood = RoonSOOD()
    private var moo: RoonMOO?
    private var imageCache = RoonImageCache()
    private var coreInfo: RoonCoreInfo?
    private var reconnectTask: Task<Void, Never>?
    private var zoneSubscriptionId: Int?
    private var queueSubscriptionId: Int?
    private var subscribedQueueZoneId: String?
    private var pairingSubscribers: [Int: Int] = [:] // requestId -> subKey
    private var pairedCoreId: String?

    init(appInfo: RoonAppInfo) {
        self.appInfo = appInfo
        // Restore preferences
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        self.isPlaylistVisible = UserDefaults.standard.bool(forKey: "isPlaylistVisible")
        self.isAlbumArtVisible = UserDefaults.standard.bool(forKey: "isAlbumArtVisible")
    }

    private func syncPlayback() {
        playback.state = currentZone?.state
        playback.nowPlaying = currentZone?.nowPlaying
        playback.seekPosition = currentZone?.nowPlaying?.seekPosition ?? 0
        playback.zoneId = currentZone?.id
        playback.displayName = currentZone?.displayName
    }

    // MARK: - Connection Management

    private var isDiscovering = false

    func connect() {
        guard !isConnected && !isDiscovering else { return }
        isDiscovering = true
        rlog("Starting native Roon Core discovery...")
        errorMessage = "Searching for Roon Core on the network..."
        startDiscovery()
    }

    func disconnect() {
        print("🔌 Disconnecting")
        isDiscovering = false
        sood.stopDiscovery()
        reconnectTask?.cancel()
        reconnectTask = nil
        if let moo = moo {
            Task {
                await moo.disconnect()
            }
        }
        moo = nil
        isConnected = false
    }

    private func startDiscovery() {
        sood.startDiscovery { [weak self] core in
            guard let self = self else { return }
            Task { @MainActor in
                self.isDiscovering = false
                self.sood.stopDiscovery()
                self.coreInfo = core
                self.imageCache.coreIP = core.ip
                self.imageCache.corePort = core.port
                await self.connectWebSocket(ip: core.ip, port: core.port)
            }
        }
    }

    private func connectWebSocket(ip: String, port: Int) async {
        let newMoo = RoonMOO()
        self.moo = newMoo

        await newMoo.connect(
            ip: ip, port: port,
            onRequest: { [weak self] msg, moo in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleIncomingRequest(msg, moo: moo)
                }
            },
            onDisconnect: { [weak self] in
                guard let self = self else { return }
                Task { @MainActor in
                    self.handleDisconnect()
                }
            }
        )

        // Step 1: Request core info
        await newMoo.sendRequest("com.roonlabs.registry:1/info") { [weak self] msg in
            guard let self = self, let msg = msg, let body = msg.body else { return }
            Task { @MainActor in
                let coreId = body["core_id"] as? String ?? ""
                let coreName = body["display_name"] as? String ?? "Roon Core"
                rlog("Connected to \(coreName) (core_id: \(coreId))")
                await self.registerExtension(coreId: coreId, moo: newMoo)
            }
        }
    }

    private func registerExtension(coreId: String, moo: RoonMOO) async {
        // Look up saved token for this core
        let tokenKey = "roon_token_\(coreId)"
        let savedToken = UserDefaults.standard.string(forKey: tokenKey)

        var regBody: [String: Any] = [
            "extension_id": appInfo.extensionId,
            "display_name": appInfo.displayName,
            "display_version": appInfo.displayVersion,
            "publisher": appInfo.publisher,
            "email": appInfo.email,
            "required_services": ["com.roonlabs.transport:2"],
            "optional_services": [],
            "provided_services": ["com.roonlabs.pairing:1", "com.roonlabs.ping:1"]
        ]
        if let token = savedToken {
            regBody["token"] = token
        }

        errorMessage = "Waiting for Roon Core authorization..."
        rlog("Registering extension with Roon Core...")

        await moo.sendRequest("com.roonlabs.registry:1/register", body: regBody) { [weak self] msg in
            guard let self = self, let msg = msg else { return }
            guard msg.name == "Registered", let body = msg.body else {
                print("⚠️ Registration response: \(msg.name)")
                return
            }

            let newCoreId = body["core_id"] as? String ?? coreId
            let token = body["token"] as? String

            Task { @MainActor in
                // Save token for future reconnections
                if let token = token {
                    let key = "roon_token_\(newCoreId)"
                    UserDefaults.standard.set(token, forKey: key)
                    print("💾 Saved auth token for core \(newCoreId)")
                }

                self.pairedCoreId = newCoreId
                self.isConnected = true
                self.errorMessage = nil
                rlog("Registered with Roon Core!")

                // Subscribe to zones
                await self.subscribeZones(moo: moo)
            }
        }
    }

    // MARK: - Incoming Request Handling

    private func handleIncomingRequest(_ msg: MOOMessage, moo: RoonMOO) async {
        // The name for incoming REQUESTs is "service/method"
        let parts = msg.name.split(separator: "/", maxSplits: 1)
        let service = parts.count > 0 ? String(parts[0]) : ""
        let method = parts.count > 1 ? String(parts[1]) : ""

        if service == "com.roonlabs.ping:1" && method == "ping" {
            await moo.sendComplete(requestId: msg.requestId, name: "Success")
        } else if service == "com.roonlabs.pairing:1" {
            await handlePairingRequest(method: method, msg: msg, moo: moo)
        } else {
            print("⚠️ Unknown incoming request: \(msg.name)")
            await moo.sendComplete(requestId: msg.requestId, name: "NotImplemented")
        }
    }

    private func handlePairingRequest(method: String, msg: MOOMessage, moo: RoonMOO) async {
        if method == "subscribe_pairing" {
            let subKey = msg.body?["subscription_key"] as? Int ?? 0
            pairingSubscribers[msg.requestId] = subKey
            await moo.sendContinue(requestId: msg.requestId, name: "Subscribed",
                                   body: ["paired_core_id": pairedCoreId as Any])
        } else if method == "unsubscribe_pairing" {
            pairingSubscribers.removeValue(forKey: msg.requestId)
            await moo.sendComplete(requestId: msg.requestId, name: "Unsubscribed")
        } else {
            await moo.sendComplete(requestId: msg.requestId, name: "NotImplemented")
        }
    }

    // MARK: - Zone Subscription

    private func subscribeZones(moo: RoonMOO) async {
        let subKey = await moo.nextSubKey()
        let body: [String: Any] = ["subscription_key": subKey]

        zoneSubscriptionId = await moo.sendRequest(
            "com.roonlabs.transport:2/subscribe_zones",
            body: body
        ) { [weak self] msg in
            guard let self = self, let msg = msg, let body = msg.body else { return }
            Task { @MainActor in
                self.handleZoneEvent(response: msg.name, data: body)
                // After initial zone subscription, subscribe to queue if playlist is visible
                if msg.name == "Subscribed" && self.isPlaylistVisible {
                    await self.subscribeQueue()
                }
            }
        }
    }

    private func handleZoneEvent(response: String, data: [String: Any]) {
        if response == "Subscribed" {
            // Full zone list
            if let zonesArray = data["zones"] as? [[String: Any]] {
                var newZones: [RoonZone] = []
                for zoneData in zonesArray {
                    if let zone = parseZone(from: zoneData) {
                        newZones.append(zone)
                    }
                }
                rlog("Zones: \(newZones.map { $0.displayName })")
                updateZonesList(with: newZones)
            }
        } else if response == "Changed" {
            handleZoneChanged(data)
        }
    }

    private func handleZoneChanged(_ data: [String: Any]) {
        // Handle removed zones
        if let removed = data["zones_removed"] as? [String] {
            zones.removeAll { removed.contains($0.id) }
        }

        // Handle added zones
        if let added = data["zones_added"] as? [[String: Any]] {
            for zoneData in added {
                if let zone = parseZone(from: zoneData) {
                    zones.append(zone)
                }
            }
        }

        // Handle changed zones
        if let changed = data["zones_changed"] as? [[String: Any]] {
            for zoneData in changed {
                if let zone = parseZone(from: zoneData) {
                    if let idx = zones.firstIndex(where: { $0.id == zone.id }) {
                        zones[idx] = zone
                    } else {
                        zones.append(zone)
                    }
                }
            }
        }

        // Handle seek changes (high frequency, only updates seek position)
        // NOTE: We intentionally do NOT update the @Published zones array here,
        // as that would fire roonAPI.objectWillChange on every tick and cause
        // all observing views to re-evaluate unnecessarily.
        var seekOnly = false
        if let seekChanged = data["zones_seek_changed"] as? [[String: Any]] {
            seekOnly = (data["zones_changed"] == nil && data["zones"] == nil && data["zones_removed"] == nil)
            for seekData in seekChanged {
                guard let zoneId = seekData["zone_id"] as? String,
                      let seekPos = seekData["seek_position"] as? Int else { continue }
                // Update playback seek position for current zone
                if zoneId == currentZone?.id {
                    playback.seekPosition = seekPos
                }
            }
        }

        // Update currentZone if it was affected (skip for seek-only events)
        if !seekOnly,
           let selectedId = currentZone?.id,
           let updated = zones.first(where: { $0.id == selectedId }) {
            let oldTitle = currentZone?.nowPlaying?.title
            currentZone = updated

            // When now_playing track changes, re-subscribe queue to get fresh data
            if let newTitle = updated.nowPlaying?.title,
               newTitle != oldTitle,
               isPlaylistVisible {
                Task { await self.resubscribeQueue() }
            }
        }
    }

    // MARK: - Queue Subscription

    func subscribeQueue() async {
        guard let zoneId = currentZone?.id, let moo = moo else { return }

        // Unsubscribe from previous queue subscription
        if subscribedQueueZoneId != nil, let subId = queueSubscriptionId {
            await moo.sendRequest(
                "com.roonlabs.transport:2/unsubscribe_queue",
                body: ["subscription_key": subId]
            ) { _ in }
            queueSubscriptionId = nil
        }

        subscribedQueueZoneId = zoneId
        let subKey = await moo.nextSubKey()
        let body: [String: Any] = [
            "subscription_key": subKey,
            "zone_or_output_id": zoneId,
            "max_item_count": 100
        ]

        queueSubscriptionId = await moo.sendRequest(
            "com.roonlabs.transport:2/subscribe_queue",
            body: body
        ) { [weak self] msg in
            guard let self = self, let msg = msg, let body = msg.body else { return }
            Task { @MainActor in
                self.handleQueueEvent(response: msg.name, data: body)
            }
        }
    }

    /// Force a fresh queue subscription to get current queue state.
    private func resubscribeQueue() async {
        // Force re-subscribe by clearing the tracked zone so subscribeQueue doesn't skip
        subscribedQueueZoneId = nil
        await subscribeQueue()
    }

    private func handleQueueEvent(response: String, data: [String: Any]) {
        guard Date() > suppressQueueUpdatesUntil else { return }

        if let items = data["items"] as? [[String: Any]] {
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

            // Update history: move played items from old queue into history
            if preserveHistoryOnNextQueueChange {
                preserveHistoryOnNextQueueChange = false
            } else if !queueItems.isEmpty && !newItems.isEmpty {
                let newFirstId = newItems.first!.id
                let allItems = queueHistory + queueItems
                if let idx = allItems.firstIndex(where: { $0.id == newFirstId }) {
                    queueHistory = Array(allItems.prefix(idx))
                } else {
                    // Completely new queue (e.g. different album)
                    queueHistory.removeAll()
                }
            }
            queueItems = newItems
            saveQueueState()
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        print("⚠️ Disconnected from Roon Core")
        isConnected = false
        moo = nil
        zoneSubscriptionId = nil
        queueSubscriptionId = nil
        subscribedQueueZoneId = nil
        pairingSubscribers.removeAll()
        errorMessage = "Lost connection to Roon Core. Reconnecting..."

        // Start reconnection after a short delay
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled else { return }
            startDiscovery()
        }
    }

    // MARK: - Zone Parsing

    private func updateZonesList(with newZones: [RoonZone]) {
        let selectedZoneId = currentZone?.id
        zones = newZones

        if let selectedZoneId = selectedZoneId {
            if let updatedZone = zones.first(where: { $0.id == selectedZoneId }) {
                currentZone = updatedZone
            } else {
                restoreLastZone()
            }
        } else {
            restoreLastZone()
        }
    }

    private func restoreLastZone() {
        if let lastZoneId = UserDefaults.standard.string(forKey: "lastSelectedZoneId") {
            if let restoredZone = zones.first(where: { $0.id == lastZoneId }) {
                currentZone = restoredZone
                return
            }
        }
        currentZone = zones.first
    }

    private func parseZone(from data: [String: Any]) -> RoonZone? {
        guard let zoneId = data["zone_id"] as? String,
              let displayName = data["display_name"] as? String else {
            return nil
        }

        var state: RoonZone.PlaybackState = .stopped

        var nowPlaying: NowPlaying?
        if let nowPlayingData = data["now_playing"] as? [String: Any] {
            // Check for state in now_playing first
            if let stateStr = nowPlayingData["state"] as? String {
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

                let rawImageKey = nowPlayingData["image_key"] as? String
                let imageUrl = rawImageKey.flatMap { imageCache.imageURL(for: $0) }

                var sampleRate: Int?
                var bitsPerSample: Int?
                var channels: Int?
                if let format = nowPlayingData["format"] as? [String: Any] {
                    sampleRate = format["sample_rate"] as? Int
                    bitsPerSample = format["bits_per_sample"] as? Int
                    channels = format["channels"] as? Int
                }

                let queueItemId: Int? = nil  // not provided in zone subscription data

                nowPlaying = NowPlaying(
                    queueItemId: queueItemId,
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
            }
        }

        // Fall back to top-level state
        if state == .stopped, let stateStr = data["state"] as? String {
            switch stateStr {
            case "playing": state = .playing
            case "paused": state = .paused
            case "loading": state = .loading
            default: state = .stopped
            }
        }

        // Parse zone settings
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

        return RoonZone(id: zoneId, displayName: displayName, state: state, nowPlaying: nowPlaying, settings: zoneSettings, volume: volumeInfo)
    }

    // MARK: - Transport Control

    func play(zoneId: String) async {
        if currentZone?.nowPlaying != nil {
            optimisticallyUpdateState(zoneId: zoneId, newState: .playing)
        }
        await sendControl(zoneId: zoneId, control: "play")
    }

    func pause(zoneId: String) async {
        optimisticallyUpdateState(zoneId: zoneId, newState: .paused)
        await sendControl(zoneId: zoneId, control: "pause")
    }

    func playPause(zoneId: String) async {
        if let currentState = currentZone?.state, currentZone?.nowPlaying != nil {
            let newState: RoonZone.PlaybackState = currentState == .playing ? .paused : .playing
            optimisticallyUpdateState(zoneId: zoneId, newState: newState)
        }
        await sendControl(zoneId: zoneId, control: "playpause")
    }

    func stop(zoneId: String) async {
        optimisticallyUpdateState(zoneId: zoneId, newState: .stopped)
        await sendControl(zoneId: zoneId, control: "stop")
    }

    func next(zoneId: String) async {
        await sendControl(zoneId: zoneId, control: "next")
    }

    func previous(zoneId: String) async {
        await sendControl(zoneId: zoneId, control: "previous")
    }

    func seek(zoneId: String, seconds: Int) async {
        guard let moo = moo else { return }
        let body: [String: Any] = [
            "zone_or_output_id": zoneId,
            "how": "absolute",
            "seconds": seconds
        ]
        await moo.sendRequest("com.roonlabs.transport:2/seek", body: body) { msg in
            if let msg = msg, msg.name != "Success" {
                print("⚠️ Seek response: \(msg.name)")
            }
        }
    }

    func toggleShuffle(zoneId: String) async {
        if var settings = currentZone?.settings {
            settings.shuffle.toggle()
            optimisticallyUpdateState(zoneId: zoneId, newSettings: settings)
            await changeSettings(zoneId: zoneId, settings: ["shuffle": settings.shuffle])
        }
    }

    func cycleLoop(zoneId: String) async {
        if var settings = currentZone?.settings {
            settings.loop = settings.loop.next
            optimisticallyUpdateState(zoneId: zoneId, newSettings: settings)
            await changeSettings(zoneId: zoneId, settings: ["loop": settings.loop.rawValue])
        }
    }

    func changeVolume(zoneId: String, value: Double) async {
        guard let vol = currentZone?.volume, let moo = moo else { return }
        let clamped = min(vol.max, max(vol.min, value))
        let updatedVol = VolumeInfo(outputId: vol.outputId, type: vol.type, min: vol.min, max: vol.max, value: clamped, step: vol.step)
        optimisticallyUpdateState(zoneId: zoneId, newVolume: updatedVol)

        let body: [String: Any] = [
            "output_id": vol.outputId,
            "how": "absolute",
            "value": Int(clamped)
        ]
        await moo.sendRequest("com.roonlabs.transport:2/change_volume", body: body) { msg in
            if let msg = msg, msg.name != "Success" {
                print("⚠️ Volume response: \(msg.name)")
            }
        }
    }

    private func changeSettings(zoneId: String, settings: [String: Any]) async {
        guard let moo = moo else { return }
        var body = settings
        body["zone_or_output_id"] = zoneId
        await moo.sendRequest("com.roonlabs.transport:2/change_settings", body: body) { msg in
            if let msg = msg, msg.name != "Success" {
                print("⚠️ Settings response: \(msg.name)")
            }
        }
    }

    private func sendControl(zoneId: String, control: String) async {
        guard let moo = moo else { return }
        let body: [String: Any] = [
            "zone_or_output_id": zoneId,
            "control": control
        ]
        await moo.sendRequest("com.roonlabs.transport:2/control", body: body) { msg in
            if let msg = msg, msg.name != "Success" {
                print("⚠️ Control \(control) response: \(msg.name)")
            }
        }
    }

    private func optimisticallyUpdateState(zoneId: String, newState: RoonZone.PlaybackState? = nil, newSettings: ZoneSettings? = nil, newVolume: VolumeInfo? = nil) {
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

            if currentZone?.id == zoneId {
                currentZone = updatedZone
            }
        }
    }

    // MARK: - Queue

    func fetchQueue() async {
        // For native API, subscribe to queue updates instead of polling
        await subscribeQueue()
    }

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

    private var preserveHistoryOnNextQueueChange = false
    private var suppressQueueUpdatesUntil: Date = .distantPast

    func playFromHere(zoneId: String, queueItemId: Int) async {
        let allItems = queueHistory + queueItems
        if let targetIndex = allItems.firstIndex(where: { $0.id == queueItemId }) {
            queueHistory = Array(allItems.prefix(targetIndex))
            queueItems = Array(allItems.suffix(from: targetIndex))
        }
        preserveHistoryOnNextQueueChange = true
        suppressQueueUpdatesUntil = Date().addingTimeInterval(3)

        guard let moo = moo else { return }
        let body: [String: Any] = [
            "zone_or_output_id": zoneId,
            "queue_item_id": queueItemId
        ]
        await moo.sendRequest("com.roonlabs.transport:2/play_from_here", body: body) { msg in
            if let msg = msg, msg.name != "Success" {
                print("⚠️ Play from here response: \(msg.name)")
            }
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RoonZone, rhs: RoonZone) -> Bool {
        lhs.id == rhs.id
    }
}

struct NowPlaying: Hashable {
    let queueItemId: Int?
    let title: String
    let artist: String
    let album: String
    let imageKey: String?
    let imageUrl: String?
    let length: Int?
    let seekPosition: Int?
    let sampleRate: Int?
    let bitsPerSample: Int?
    let channels: Int?

    var kbpsDisplay: Int {
        guard let sr = sampleRate, let bps = bitsPerSample, let ch = channels else { return 0 }
        return sr * bps * ch / 1000
    }

    var kHzDisplay: Int {
        guard let sr = sampleRate else { return 0 }
        return sr / 1000
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let alwaysOnTopChanged = Notification.Name("alwaysOnTopChanged")
    static let albumArtVisibilityChanged = Notification.Name("albumArtVisibilityChanged")
}
