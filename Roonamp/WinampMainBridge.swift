//
//  WinampMainBridge.swift
//  Roonamp
//
//  NSViewRepresentable bridge between SwiftUI and WinampMainView.
//  Handles Combine subscriptions and windowshade mode switching.
//

import SwiftUI
import Combine

struct WinampMainBridge: View {
    let skin: WinampSkin
    @EnvironmentObject var roonAPI: RoonAPI
    @EnvironmentObject var playback: PlaybackState
    @EnvironmentObject var skinManager: WinampSkinManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @AppStorage("windowScale") private var windowScale: Double = 2.0
    @AppStorage("windowShade") private var isWindowShade: Bool = false
    @AppStorage("showRemaining") private var showRemaining: Bool = false
    @AppStorage("wsDisplayMode") private var wsDisplayMode: WinampWindowShadeView.WSDisplayMode = .spectrum
    @AppStorage("displayKbps") private var displayKbps: String = ""
    @AppStorage("displayKHz") private var displayKHz: String = ""

    @State private var isWindowActive: Bool = true
    @State private var visualizerMode: VisualizerMode = .spectrum

    // Position tracking (shared between normal and shade modes)
    @State private var currentSeekPosition: Int = 0
    @State private var lastUpdateTime: Date = Date()
    @State private var positionTimer: Timer?
    @State private var localSeekPosition: Int?

    private var scale: CGFloat { CGFloat(windowScale) }
    private let windowWidth: CGFloat = 275
    private let windowHeight: CGFloat = 116

    private var currentHeight: CGFloat {
        isWindowShade ? CGFloat(WinampSkin.windowShadeHeight) : windowHeight
    }

    var body: some View {
        Group {
            if isWindowShade {
                WinampWindowShadeView(
                    skin: skin,
                    isWindowActive: isWindowActive,
                    currentSeekPosition: currentSeekPosition,
                    showRemaining: $showRemaining,
                    displayMode: $wsDisplayMode,
                    onOptions: { openSettings() },
                    onUnshade: { isWindowShade = false },
                    onMinimize: { WinampWindow.current?.miniaturize(nil) },
                    onClose: { WinampWindow.current?.orderOut(nil) },
                    onSeek: { newProgress in
                        guard let zone = roonAPI.currentZone,
                              let length = zone.nowPlaying?.length, length > 0 else { return }
                        let newPosition = Int(newProgress * Double(length))
                        currentSeekPosition = newPosition
                        localSeekPosition = newPosition
                        lastUpdateTime = Date()
                        Task { await roonAPI.seek(zoneId: zone.id, seconds: newPosition) }
                    }
                )
                .environment(\.winampScale, scale)
            } else {
                WinampMainNSViewRepresentable(
                    skin: skin,
                    roonAPI: roonAPI,
                    skinManager: skinManager,
                    scale: scale,
                    showRemaining: showRemaining,
                    displayKbps: displayKbps,
                    displayKHz: displayKHz,
                    visualizerMode: $visualizerMode,
                    isWindowActive: $isWindowActive,
                    onOptions: { openSettings() },
                    onMinimize: { WinampWindow.current?.miniaturize(nil) },
                    onShade: { isWindowShade = true },
                    onClose: { WinampWindow.current?.orderOut(nil) },
                    onOpenWindow: { id in openWindow(id: id, value: true) },
                    onShowRemainingToggle: { showRemaining.toggle() },
                    onCycleScale: {
                        switch windowScale {
                        case 1.0: windowScale = 1.5
                        case 1.5: windowScale = 2.0
                        default: windowScale = 1.0
                        }
                    }
                )
                .frame(width: windowWidth * scale, height: windowHeight * scale)
            }
        }
        .frame(width: windowWidth * scale, height: currentHeight * scale)
        .clipShape(WinampRegionShape(
            polygons: isWindowShade ? skin.windowShadeRegion : skin.normalRegion,
            scale: scale
        ))
        .background(WindowAccessorWinamp(scale: scale, isWindowShade: isWindowShade, hasRegion: skin.normalRegion != nil, isWindowActive: $isWindowActive))
        .onAppear {
            if !roonAPI.isConnected {
                roonAPI.connect()
            }
            if playback.seekPosition > 0 {
                currentSeekPosition = playback.seekPosition
                lastUpdateTime = Date()
            }
            if playback.state == .playing {
                startPositionTimer()
            }
            if roonAPI.isPlaylistVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    openWindow(id: "playlist", value: true)
                }
            }
            if roonAPI.isAlbumArtVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    openWindow(id: "album-art", value: true)
                }
            }
        }
        .onDisappear {
            stopPositionTimer()
        }
        .onReceive(playback.seekPositionPublisher) { newPosition in
            if let localSeek = localSeekPosition {
                if abs(newPosition - localSeek) <= 3 {
                    localSeekPosition = nil
                    currentSeekPosition = newPosition
                    lastUpdateTime = Date()
                }
            } else {
                currentSeekPosition = newPosition
                lastUpdateTime = Date()
            }
        }
        .onChange(of: playback.state) { oldValue, newValue in
            if newValue == .playing {
                lastUpdateTime = Date()
                startPositionTimer()
            } else {
                stopPositionTimer()
            }
        }
    }

    // Position timer only used for windowshade mode — normal mode has its own comboTimer
    private func startPositionTimer() {
        guard isWindowShade else { return }
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if playback.state == .playing {
                let elapsed = Date().timeIntervalSince(lastUpdateTime)
                if let localBase = localSeekPosition {
                    currentSeekPosition = localBase + Int(elapsed)
                } else {
                    let basePosition = playback.seekPosition
                    currentSeekPosition = basePosition + Int(elapsed)
                }
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }
}

// MARK: - NSViewRepresentable for WinampMainView

struct WinampMainNSViewRepresentable: NSViewRepresentable {
    let skin: WinampSkin
    let roonAPI: RoonAPI
    let skinManager: WinampSkinManager
    let scale: CGFloat
    let showRemaining: Bool
    let displayKbps: String
    let displayKHz: String
    @Binding var visualizerMode: VisualizerMode
    @Binding var isWindowActive: Bool
    let onOptions: () -> Void
    let onMinimize: () -> Void
    let onShade: () -> Void
    let onClose: () -> Void
    let onOpenWindow: (String) -> Void
    let onShowRemainingToggle: () -> Void
    let onCycleScale: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WinampMainView {
        let view = WinampMainView(frame: NSRect(x: 0, y: 0, width: 275 * scale, height: 116 * scale))
        view.scale = scale
        view.showRemaining = showRemaining
        view.displayKbps = displayKbps
        view.displayKHz = displayKHz
        if let cached = skinManager.currentSpriteCache {
            view.sprites = cached
        } else {
            let sprites = SpriteCache.build(from: skin)
            skinManager.currentSpriteCache = sprites
            view.sprites = sprites
            DispatchQueue.main.async { skinManager.clearSourceBitmaps() }
        }

        // Wire up callbacks
        wireCallbacks(view, context: context)

        // Set up Combine subscriptions
        context.coordinator.setupSubscriptions(roonAPI: roonAPI, view: view)

        // Initial state
        view.updateZone(roonAPI.currentZone)
        view.updatePlaylistVisible(roonAPI.isPlaylistVisible)
        view.updateAlbumArtVisible(roonAPI.isAlbumArtVisible)
        view.updateAlwaysOnTop(roonAPI.alwaysOnTop)
        view.updateVisualizer(colors: skin.visColors,
                              isPlaying: roonAPI.currentZone?.state == .playing,
                              mode: visualizerMode)

        return view
    }

    func updateNSView(_ view: WinampMainView, context: Context) {
        // Scale change
        if view.scale != scale {
            view.scale = scale
            view.updateVisualizer(colors: skin.visColors,
                                  isPlaying: roonAPI.currentZone?.state == .playing,
                                  mode: visualizerMode)
        }

        // Show remaining toggle
        if view.showRemaining != showRemaining {
            view.showRemaining = showRemaining
        }

        // Info display values
        if view.displayKbps != displayKbps || view.displayKHz != displayKHz {
            view.displayKbps = displayKbps
            view.displayKHz = displayKHz
            view.updateInfoDisplays()
        }

        // Skin change
        if context.coordinator.currentSkinName != skin.name {
            context.coordinator.currentSkinName = skin.name
            let sprites = SpriteCache.build(from: skin)
            skinManager.currentSpriteCache = sprites
            view.sprites = sprites
            DispatchQueue.main.async { skinManager.clearSourceBitmaps() }
            view.updateVisualizer(colors: skin.visColors,
                                  isPlaying: roonAPI.currentZone?.state == .playing,
                                  mode: visualizerMode)
        }

        // Visualizer mode change
        if context.coordinator.currentVisualizerMode != visualizerMode {
            context.coordinator.currentVisualizerMode = visualizerMode
            view.updateVisualizer(colors: skin.visColors,
                                  isPlaying: roonAPI.currentZone?.state == .playing,
                                  mode: visualizerMode)
        }

        // Window active state
        view.updateWindowActive(isWindowActive)

        // Re-wire callbacks (closures may capture new values)
        wireCallbacks(view, context: context)
    }

    private func wireCallbacks(_ view: WinampMainView, context: Context) {
        view.onPrevious = {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.previous(zoneId: zoneId) }
        }
        view.onPlay = {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.playPause(zoneId: zoneId) }
        }
        view.onPause = {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.playPause(zoneId: zoneId) }
        }
        view.onStop = {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.pause(zoneId: zoneId) }
        }
        view.onNext = {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.next(zoneId: zoneId) }
        }
        view.onEject = { /* no action */ }
        view.onSeek = { newPosition in
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.seek(zoneId: zoneId, seconds: newPosition) }
        }
        view.onVolumeChange = { newProgress in
            guard let zoneId = roonAPI.currentZone?.id,
                  let v = roonAPI.currentZone?.volume else { return }
            let newValue = v.min + newProgress * (v.max - v.min)
            Task { await roonAPI.changeVolume(zoneId: zoneId, value: newValue) }
        }
        view.onShuffleToggle = {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.toggleShuffle(zoneId: zoneId) }
        }
        view.onLoopCycle = {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.cycleLoop(zoneId: zoneId) }
        }
        view.onPlaylistToggle = {
            roonAPI.isPlaylistVisible.toggle()
            if roonAPI.isPlaylistVisible {
                if WinampWindow.isSnapped,
                   let playlist = WinampWindow.playlist,
                   let mainWindow = WinampWindow.current {
                    let mainFrame = mainWindow.frame
                    let isBelow = WinampWindow.snapOffset.y < 0
                    let plSize = playlist.frame.size
                    let y: CGFloat = isBelow ? mainFrame.minY - plSize.height : mainFrame.maxY
                    playlist.setFrameOrigin(NSPoint(x: mainFrame.minX, y: y))
                }
                onOpenWindow("playlist")
            } else {
                WinampWindow.playlist?.orderOut(nil)
            }
        }
        view.onOptions = onOptions
        view.onMinimize = onMinimize
        view.onShade = onShade
        view.onClose = onClose
        view.onAlwaysOnTopToggle = {
            roonAPI.alwaysOnTop.toggle()
        }
        view.onAlbumArtToggle = {
            if roonAPI.isAlbumArtVisible {
                roonAPI.isAlbumArtVisible = false
                WinampWindow.albumArt?.orderOut(nil)
            } else {
                roonAPI.isAlbumArtVisible = true
                onOpenWindow("album-art")
            }
        }
        view.onCycleScale = onCycleScale
        view.onTimeDisplayTap = onShowRemainingToggle
        view.onVisualizerTap = { [context] in
            let all = VisualizerMode.allCases
            let idx = all.firstIndex(of: visualizerMode) ?? 0
            let newMode = all[(idx + 1) % all.count]
            DispatchQueue.main.async {
                context.coordinator.parent.visualizerMode = newMode
            }
        }
    }

    static func dismantleNSView(_ view: WinampMainView, coordinator: Coordinator) {
        view.tearDown()
        coordinator.cancelSubscriptions()
    }

    // MARK: - Coordinator

    class Coordinator {
        var parent: WinampMainNSViewRepresentable
        var cancellables = Set<AnyCancellable>()
        var currentSkinName: String = ""
        var currentVisualizerMode: VisualizerMode = .spectrum

        init(_ parent: WinampMainNSViewRepresentable) {
            self.parent = parent
            self.currentSkinName = parent.skin.name
            self.currentVisualizerMode = parent.visualizerMode
        }

        func setupSubscriptions(roonAPI: RoonAPI, view: WinampMainView) {
            // Zone changes (track, state, volume — but NOT high-frequency seek)
            roonAPI.$currentZone
                .receive(on: DispatchQueue.main)
                .sink { [weak view] zone in
                    view?.updateZone(zone)
                }
                .store(in: &cancellables)

            // Seek position (high-frequency, separate from zone changes)
            roonAPI.playback.seekPositionPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak view] seekPos in
                    view?.updateSeekPosition(seekPos)
                }
                .store(in: &cancellables)

            // Playlist visibility
            roonAPI.$isPlaylistVisible
                .receive(on: DispatchQueue.main)
                .sink { [weak view] visible in
                    view?.updatePlaylistVisible(visible)
                }
                .store(in: &cancellables)

            // Album art visibility
            roonAPI.$isAlbumArtVisible
                .receive(on: DispatchQueue.main)
                .sink { [weak view] visible in
                    view?.updateAlbumArtVisible(visible)
                }
                .store(in: &cancellables)

            // Always on top
            roonAPI.$alwaysOnTop
                .receive(on: DispatchQueue.main)
                .sink { [weak view] onTop in
                    view?.updateAlwaysOnTop(onTop)
                }
                .store(in: &cancellables)

            // Album art window closed via traffic light button
            NotificationCenter.default.publisher(for: .albumArtVisibilityChanged)
                .receive(on: DispatchQueue.main)
                .sink { notification in
                    if let visible = notification.object as? Bool {
                        roonAPI.isAlbumArtVisible = visible
                    }
                }
                .store(in: &cancellables)

            // Settings window visibility
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.willCloseNotification))
                .receive(on: DispatchQueue.main)
                .sink { [weak view] notification in
                    guard let window = notification.object as? NSWindow,
                          window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" else { return }
                    let visible = notification.name == NSWindow.didBecomeKeyNotification
                    view?.updateSettingsVisible(visible)
                }
                .store(in: &cancellables)
        }

        func cancelSubscriptions() {
            cancellables.removeAll()
        }
    }
}
