//
//  WinampSkinView.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import SwiftUI
import Combine

// Environment key for pixel-perfect scaling (avoids bilinear .scaleEffect)
private struct WinampScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 2.0
}
extension EnvironmentValues {
    var winampScale: CGFloat {
        get { self[WinampScaleKey.self] }
        set { self[WinampScaleKey.self] = newValue }
    }
}

struct WinampSkinView: View {
    let skin: WinampSkin
    @EnvironmentObject var roonAPI: RoonAPI
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    
    // Winamp main window is 275x116, scaled
    @AppStorage("windowScale") private var windowScale: Double = 2.0
    private var scale: CGFloat { CGFloat(windowScale) }
    private let windowWidth: CGFloat = 275
    private let windowHeight: CGFloat = 116
    
    // Window active state for titlebar
    @State private var isWindowActive: Bool = true

    // Windowshade mode
    @AppStorage("windowShade") private var isWindowShade: Bool = false

    // Time display mode (shared between normal, windowshade, and playlist)
    @AppStorage("showRemaining") private var showRemaining: Bool = false

    // Visualizer mode
    @State private var visualizerMode: VisualizerMode = .spectrum

    // Windowshade display mode
    @AppStorage("wsDisplayMode") private var wsDisplayMode: WinampWindowShadeView.WSDisplayMode = .spectrum

    // Track position state for smooth updates
    @State private var currentSeekPosition: Int = 0
    @State private var lastUpdateTime: Date = Date()
    @State private var timer: Timer?
    @State private var localSeekPosition: Int? = nil // non-nil after local seek, cleared on server confirm
    
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
            } else {
                ZStack {
                    // Main window background
                    if let mainBitmap = skin.mainWindowBitmap {
                        Image(nsImage: mainBitmap)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: windowWidth * scale, height: windowHeight * scale)
                    } else {
                        Rectangle()
                            .fill(Color.gray)
                            .frame(width: windowWidth * scale, height: windowHeight * scale)
                    }

                    // Title bar (active/inactive state overlay)
                    if let titleBarBitmap = skin.titleBarBitmap {
                        WinampTitleBar(
                            bitmap: titleBarBitmap,
                            isActive: isWindowActive,
                            onOptions: { openSettings() },
                            onMinimize: {
                                WinampWindow.current?.miniaturize(nil)
                            },
                            onShade: {
                                isWindowShade = true
                            },
                            onClose: {
                                WinampWindow.current?.orderOut(nil)
                            }
                        )
                    }

                    // Clutterbar (O, A, I, D, V buttons)
                    if let titleBarBitmap = skin.titleBarBitmap {
                        WinampClutterBar(
                            bitmap: titleBarBitmap,
                            region: WinampSkin.clutterBarRegion,
                            isAlwaysOnTop: roonAPI.alwaysOnTop,
                            isInfoOpen: roonAPI.isAlbumArtVisible,
                            isScaled: windowScale > 1.0,
                            onOptions: { openSettings() },
                            onAlwaysOnTop: { roonAPI.alwaysOnTop.toggle() },
                            onInfo: {
                                if roonAPI.isAlbumArtVisible {
                                    roonAPI.isAlbumArtVisible = false
                                    WinampWindow.albumArt?.orderOut(nil)
                                } else {
                                    roonAPI.isAlbumArtVisible = true
                                    openWindow(id: "album-art", value: true)
                                }
                            },
                            onCycleScale: {
                                switch windowScale {
                                case 1.0: windowScale = 1.5
                                case 1.5: windowScale = 2.0
                                default: windowScale = 1.0
                                }
                            }
                        )
                    }

                    // Title text overlay
                    if let zone = roonAPI.currentZone, let nowPlaying = zone.nowPlaying {
                        let titleText = "\(nowPlaying.artist) - \(nowPlaying.title)"

                        if let textBitmap = skin.textBitmap {
                            WinampBitmapText(
                                text: titleText,
                                bitmap: textBitmap,
                                region: WinampSkin.titleRegion
                            )
                        }

                        // Play/pause status indicator + work LEDs
                        if let playpausBitmap = skin.playpausBitmap,
                           let state = roonAPI.currentZone?.state,
                           state == .playing || state == .paused {
                            WinampPlayPausIndicator(
                                bitmap: playpausBitmap,
                                state: state,
                                region: WinampSkin.playPausIndicatorRegion
                            )
                            if state == .playing {
                                WinampWorkLED(
                                    bitmap: playpausBitmap,
                                    isPlaying: true,
                                    greenRegion: WinampSkin.workGreenRegion,
                                    redRegion: WinampSkin.workRedRegion
                                )
                            }
                        }

                        // Track time display
                        if let numbersBitmap = skin.numbersBitmap {
                            WinampTimeDisplay(
                                seekPosition: roonAPI.currentZone?.state == .playing ? currentSeekPosition : (nowPlaying.seekPosition ?? 0),
                                bitmap: numbersBitmap,
                                region: WinampSkin.timeRegion,
                                isPaused: roonAPI.currentZone?.state == .paused,
                                showRemaining: $showRemaining
                            )
                        }

                        // Bitrate and sample rate display
                        if let textBitmap = skin.textBitmap {
                            WinampInfoDisplay(
                                text: "\(nowPlaying.kbpsDisplay)",
                                bitmap: textBitmap,
                                region: WinampSkin.kbpsRegion
                            )
                            WinampInfoDisplay(
                                text: "\(nowPlaying.kHzDisplay)",
                                bitmap: textBitmap,
                                region: WinampSkin.kHzRegion
                            )
                        }

                        // Mono/Stereo indicator
                        if let monosterBitmap = skin.monosterBitmap {
                            let isStereo = (nowPlaying.channels ?? 2) >= 2
                            WinampMonoStereoDisplay(
                                bitmap: monosterBitmap,
                                isStereo: isStereo,
                                region: WinampSkin.monoStereoRegion
                            )
                        }
                    }

                    // Visualizer
                    WinampVisualizer(
                        colors: skin.visColors,
                        isPlaying: roonAPI.currentZone?.state == .playing,
                        region: WinampSkin.visualizerRegion,
                        scale: scale,
                        mode: $visualizerMode
                    )

                    // Position slider (seek bar)
                    createPositionSlider()

                    // Interactive buttons
                    createButtons()
                }
            }
        }
        .environment(\.winampScale, scale)
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
            if let pos = roonAPI.currentZone?.nowPlaying?.seekPosition {
                currentSeekPosition = pos
                lastUpdateTime = Date()
            }
            if roonAPI.currentZone?.state == .playing {
                startPositionTimer()
            }
            // Reopen windows if they were visible last session
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
        .onChange(of: roonAPI.currentZone?.nowPlaying?.seekPosition) { oldValue, newValue in
            if let newPosition = newValue {
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
        }
        .onChange(of: roonAPI.currentZone?.state) { oldValue, newValue in
            if newValue == .playing {
                lastUpdateTime = Date()
                startPositionTimer()
            } else {
                stopPositionTimer()
            }
        }
    }
    
    @ViewBuilder
    private func createPositionSlider() -> some View {
        if let zone = roonAPI.currentZone,
           let nowPlaying = zone.nowPlaying,
           let length = nowPlaying.length,
           length > 0 {
            
            // Use local state for smooth updates when playing
            let seekPosition = roonAPI.currentZone?.state == .playing ? currentSeekPosition : (nowPlaying.seekPosition ?? 0)
            let progress = min(1.0, max(0.0, Double(seekPosition) / Double(length)))
            
            ZStack {
                if let posbarBitmap = skin.positionBarBitmap {
                    // Use the skin's position bar graphics
                    WinampPositionSlider(
                        bitmap: posbarBitmap,
                        progress: progress,
                        region: WinampSkin.positionBarRegion,
                        onSeek: { newProgress in
                            let newPosition = Int(newProgress * Double(length))
                            currentSeekPosition = newPosition
                            localSeekPosition = newPosition
                            lastUpdateTime = Date()
                            if let zoneId = roonAPI.currentZone?.id {
                                Task {
                                    await roonAPI.seek(zoneId: zoneId, seconds: newPosition)
                                }
                            }
                        }
                    )
                } else {
                    // Fallback to simple progress bar
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.black.opacity(0.3))
                            .frame(width: CGFloat(WinampSkin.positionBarRegion.width) * scale,
                                   height: CGFloat(WinampSkin.positionBarRegion.height) * scale)
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: CGFloat(WinampSkin.positionBarRegion.width) * scale * progress,
                                   height: CGFloat(WinampSkin.positionBarRegion.height) * scale)
                    }
                    .padding(.leading, CGFloat(WinampSkin.positionBarRegion.x) * scale)
                    .padding(.top, CGFloat(WinampSkin.positionBarRegion.y) * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let localX = value.location.x
                                let newProgress = max(0, min(1, localX / (CGFloat(WinampSkin.positionBarRegion.width) * scale)))
                                let newPosition = Int(newProgress * Double(length))
                                currentSeekPosition = newPosition
                            }
                            .onEnded { value in
                                if let zoneId = roonAPI.currentZone?.id {
                                    Task {
                                        await roonAPI.seek(zoneId: zoneId, seconds: currentSeekPosition)
                                    }
                                }
                            }
                    )
                }
            }
            .allowsHitTesting(true)
        }
    }
    
    private func startPositionTimer() {
        stopPositionTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if roonAPI.currentZone?.state == .playing {
                let elapsed = Date().timeIntervalSince(lastUpdateTime)
                if let localBase = localSeekPosition {
                    // Use local seek position as base until server confirms
                    currentSeekPosition = localBase + Int(elapsed)
                } else if let basePosition = roonAPI.currentZone?.nowPlaying?.seekPosition {
                    currentSeekPosition = basePosition + Int(elapsed)
                }
            }
        }
    }
    
    private func stopPositionTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    @ViewBuilder
    private func createButtons() -> some View {
        // Use GeometryReader to position buttons from top-left corner
        GeometryReader { geometry in
            if let cbuttonsBitmap = skin.playPauseBitmap {
                // Previous button
                WinampButton(
                    bitmap: cbuttonsBitmap,
                    buttonIndex: 0,
                    region: WinampSkin.previousButton
                ) {
                    guard let zoneId = roonAPI.currentZone?.id else { return }
                    Task { await roonAPI.previous(zoneId: zoneId) }
                }
                
                // Play button
                WinampButton(
                    bitmap: cbuttonsBitmap,
                    buttonIndex: 1,
                    region: WinampSkin.playButton
                ) {
                    guard let zoneId = roonAPI.currentZone?.id else { return }
                    Task { await roonAPI.playPause(zoneId: zoneId) }
                }
                
                // Pause button
                WinampButton(
                    bitmap: cbuttonsBitmap,
                    buttonIndex: 2,
                    region: WinampSkin.pauseButton
                ) {
                    guard let zoneId = roonAPI.currentZone?.id else { return }
                    Task { await roonAPI.playPause(zoneId: zoneId) }
                }

                // Stop button
                WinampButton(
                    bitmap: cbuttonsBitmap,
                    buttonIndex: 3,
                    region: WinampSkin.stopButton
                ) {
                    guard let zoneId = roonAPI.currentZone?.id else { return }
                    Task { await roonAPI.pause(zoneId: zoneId) }
                }
                
                // Next button
                WinampButton(
                    bitmap: cbuttonsBitmap,
                    buttonIndex: 4,
                    region: WinampSkin.nextButton
                ) {
                    guard let zoneId = roonAPI.currentZone?.id else { return }
                    Task { await roonAPI.next(zoneId: zoneId) }
                }

                // Eject button (display-only)
                WinampButton(
                    bitmap: cbuttonsBitmap,
                    buttonIndex: 5,
                    region: WinampSkin.ejectButton
                ) {
                    // No action for eject
                }
            } else {
                // Fallback to invisible buttons if bitmap not available
                createInvisibleButtons()
            }

            // Volume slider
            if let volumeBitmap = skin.volumeBitmap {
                let vol = roonAPI.currentZone?.volume
                let volProgress: Double = {
                    guard let v = vol else { return 0.75 }
                    let range = v.max - v.min
                    return range > 0 ? (v.value - v.min) / range : 0
                }()
                WinampVolumeSlider(
                    bitmap: volumeBitmap,
                    progress: volProgress,
                    region: WinampSkin.volumeBarRegion,
                    frameCount: 28,
                    frameHeight: 15,
                    bitmapWidth: 68,
                    onValueChange: { newProgress in
                        guard let zoneId = roonAPI.currentZone?.id,
                              let v = roonAPI.currentZone?.volume else { return }
                        let newValue = v.min + newProgress * (v.max - v.min)
                        Task { await roonAPI.changeVolume(zoneId: zoneId, value: newValue) }
                    }
                )
            }

            // Balance slider (decorative, fixed at center)
            if let balanceBitmap = skin.balanceBitmap {
                WinampVolumeSlider(
                    bitmap: balanceBitmap,
                    progress: 0.0,
                    region: WinampSkin.balanceBarRegion,
                    frameCount: 28,
                    frameHeight: 15,
                    bitmapWidth: 68,
                    onValueChange: nil,
                    thumbBitmap: skin.volumeBitmap,
                    thumbProgress: 0.5,
                    cropX: 9,
                    centerBased: true
                )
            }

            // Shuffle toggle button
            if let shufrepBitmap = skin.shuffleRepeatBitmap {
                WinampToggleButton(
                    bitmap: shufrepBitmap,
                    isOn: roonAPI.currentZone?.settings?.shuffle ?? false,
                    region: WinampSkin.shuffleButton,
                    bitmapX: 28,
                    bitmapWidth: 47
                ) {
                    guard let zoneId = roonAPI.currentZone?.id else { return }
                    Task { await roonAPI.toggleShuffle(zoneId: zoneId) }
                }

                // Repeat toggle button
                WinampToggleButton(
                    bitmap: shufrepBitmap,
                    isOn: (roonAPI.currentZone?.settings?.loop ?? .disabled) != .disabled,
                    region: WinampSkin.repeatButton,
                    bitmapX: 0,
                    bitmapWidth: 28
                ) {
                    guard let zoneId = roonAPI.currentZone?.id else { return }
                    Task { await roonAPI.cycleLoop(zoneId: zoneId) }
                }

                // EQ button (decorative, always off)
                WinampToggleButton(
                    bitmap: shufrepBitmap,
                    isOn: false,
                    region: WinampSkin.eqButton,
                    bitmapX: 0,
                    bitmapWidth: 23,
                    bitmapY: 60,
                    rowHeight: 12,
                    topBorder: 1,
                    twoRow: true
                ) {
                    // Decorative only
                }

                // PL button (toggles playlist window)
                WinampToggleButton(
                    bitmap: shufrepBitmap,
                    isOn: roonAPI.isPlaylistVisible,
                    region: WinampSkin.plButton,
                    bitmapX: 23,
                    bitmapWidth: 23,
                    bitmapY: 60,
                    rowHeight: 12,
                    topBorder: 1,
                    twoRow: true
                ) {
                    roonAPI.isPlaylistVisible.toggle()
                    if roonAPI.isPlaylistVisible {
                        // Pre-position hidden window at snap location before showing
                        if WinampWindow.isSnapped,
                           let playlist = WinampWindow.playlist,
                           let mainWindow = WinampWindow.current {
                            let mainFrame = mainWindow.frame
                            let isBelow = WinampWindow.snapOffset.y < 0
                            let plSize = playlist.frame.size
                            let y: CGFloat = isBelow ? mainFrame.minY - plSize.height : mainFrame.maxY
                            playlist.setFrameOrigin(NSPoint(x: mainFrame.minX, y: y))
                        }
                        openWindow(id: "playlist", value: true)
                    } else {
                        WinampWindow.playlist?.orderOut(nil)
                    }
                }
            }

            // Clutterbar buttons handled via overlay in WinampClutterBar
        }
    }
    
    @ViewBuilder
    private func createInvisibleButtons() -> some View {
        Button {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.previous(zoneId: zoneId) }
        } label: {
            Color.clear
                .frame(width: CGFloat(WinampSkin.previousButton.width) * scale, height: CGFloat(WinampSkin.previousButton.height) * scale)
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(WinampSkin.previousButton.x) * scale, y: CGFloat(WinampSkin.previousButton.y) * scale)

        Button {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.playPause(zoneId: zoneId) }
        } label: {
            Color.clear
                .frame(width: CGFloat(WinampSkin.playButton.width) * scale, height: CGFloat(WinampSkin.playButton.height) * scale)
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(WinampSkin.playButton.x) * scale, y: CGFloat(WinampSkin.playButton.y) * scale)

        Button {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.pause(zoneId: zoneId) }
        } label: {
            Color.clear
                .frame(width: CGFloat(WinampSkin.pauseButton.width) * scale, height: CGFloat(WinampSkin.pauseButton.height) * scale)
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(WinampSkin.pauseButton.x) * scale, y: CGFloat(WinampSkin.pauseButton.y) * scale)

        Button {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.pause(zoneId: zoneId) }
        } label: {
            Color.clear
                .frame(width: CGFloat(WinampSkin.stopButton.width) * scale, height: CGFloat(WinampSkin.stopButton.height) * scale)
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(WinampSkin.stopButton.x) * scale, y: CGFloat(WinampSkin.stopButton.y) * scale)

        Button {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.next(zoneId: zoneId) }
        } label: {
            Color.clear
                .frame(width: CGFloat(WinampSkin.nextButton.width) * scale, height: CGFloat(WinampSkin.nextButton.height) * scale)
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(WinampSkin.nextButton.x) * scale, y: CGFloat(WinampSkin.nextButton.y) * scale)
    }
}

// MARK: - Winamp Visualizer

private class VisualizerPeaks {
    var values: [Double]
    init(count: Int) { values = Array(repeating: 0, count: count) }
}

enum VisualizerMode: CaseIterable {
    case spectrum
    case oscilloscope
    case off
}

struct WinampVisualizer: View {
    let colors: [Color]
    let isPlaying: Bool
    let region: WinampSkin.ButtonRegion
    let scale: CGFloat
    @Binding var mode: VisualizerMode
    var handleTapCycle: Bool = true

    @State private var peakState: VisualizerPeaks

    // Pre-computed RGB bytes — avoids Color→NSColor conversion every frame
    private let colorRGB: [(UInt8, UInt8, UInt8)]

    private let width: Int
    private let height: Int
    private let barCount: Int

    // Precomputed spectrum data from real audio analysis
    private static let spectrumData: Data? = {
        guard let url = Bundle.main.url(forResource: "spectrum_data", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data
    }()
    private static let spectrumBands = 19
    private static var spectrumFrameCount: Int {
        (spectrumData?.count ?? 0) / spectrumBands
    }

    init(colors: [Color], isPlaying: Bool, region: WinampSkin.ButtonRegion, scale: CGFloat,
         mode: Binding<VisualizerMode>, handleTapCycle: Bool = true,
         sourceWidth: Int = 76, sourceHeight: Int = 16, barCount: Int = 19) {
        self.colors = colors
        self.isPlaying = isPlaying
        self.region = region
        self.scale = scale
        self._mode = mode
        self.handleTapCycle = handleTapCycle
        self.width = sourceWidth
        self.height = sourceHeight
        self.barCount = barCount
        self._peakState = State(initialValue: VisualizerPeaks(count: barCount))
        self.colorRGB = colors.map { color in
            let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
            return (UInt8(nsColor.redComponent * 255),
                    UInt8(nsColor.greenComponent * 255),
                    UInt8(nsColor.blueComponent * 255))
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pointW = CGFloat(width) * scale
            let pointH = CGFloat(height) * scale
            if let cg = renderVisualizer(time: time) {
                let ns = NSImage(cgImage: cg, size: NSSize(width: pointW, height: pointH))
                Image(nsImage: ns)
                    .interpolation(.none)
                    .frame(width: pointW, height: pointH)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let all = VisualizerMode.allCases
                        let idx = all.firstIndex(of: mode) ?? 0
                        mode = all[(idx + 1) % all.count]
                    }
                    .allowsHitTesting(handleTapCycle)
                    .padding(.leading, CGFloat(region.x) * scale)
                    .padding(.top, CGFloat(region.y) * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .allowsHitTesting(handleTapCycle)
    }

    private func colorAt(_ index: Int) -> (UInt8, UInt8, UInt8) {
        guard index >= 0 && index < colorRGB.count else { return (0, 0, 0) }
        return colorRGB[index]
    }

    private func renderVisualizer(time: Double) -> CGImage? {
        let w = width   // 76
        let h = height  // 16
        let backing = NSScreen.main?.backingScaleFactor ?? 2.0
        let ps = max(1, Int(scale * backing))  // device pixels per source pixel (4 for 2x+Retina)
        let imgW = w * ps  // 304
        let imgH = h * ps  // 64
        var pixels = [UInt8](repeating: 0, count: imgW * imgH * 4)

        // Fill a ps×ps block at source coordinates (sx, sy) with color c
        func fill(_ sx: Int, _ sy: Int, _ c: (UInt8, UInt8, UInt8)) {
            let bx = sx * ps
            let by = sy * ps
            for dy in 0..<ps {
                let rowOffset = ((by + dy) * imgW + bx) * 4
                for dx in 0..<ps {
                    let offset = rowOffset + dx * 4
                    pixels[offset] = c.0
                    pixels[offset+1] = c.1
                    pixels[offset+2] = c.2
                    pixels[offset+3] = 255
                }
            }
        }

        let bg = colorAt(0)
        let grid = colorAt(1)

        // Background + grid at device pixel resolution
        for y in 0..<h {
            for x in 0..<w {
                fill(x, y, (x % 2 == 0 && y % 2 == 0) ? grid : bg)
            }
        }

        // Spectrum / oscilloscope
        if isPlaying && mode != .off {
            switch mode {
            case .spectrum:
                let peakColor = colorAt(23)
                for i in 0..<barCount {
                    let amplitude = amplitudeForBar(i, time: time)
                    if amplitude >= peakState.values[i] {
                        peakState.values[i] = amplitude
                    } else {
                        peakState.values[i] = max(0, peakState.values[i] - 0.02)
                    }
                    let barHeight = Int(amplitude * Double(h))
                    let sx = i * 4
                    for py in 0..<barHeight {
                        let screenY = h - 1 - py
                        let scaledPy = h >= 16 ? (py & ~1) : Int(Double(py) / Double(h - 1) * 16) & ~1
                        let c = colorAt(min(17, 17 - scaledPy))
                        for dx in 0..<3 { fill(sx + dx, screenY, c) }
                    }
                    let peakPixel = Int(peakState.values[i] * Double(h - 1))
                    if peakPixel > 0 {
                        let peakY = h - 1 - peakPixel
                        for dx in 0..<3 { fill(sx + dx, peakY, peakColor) }
                    }
                }
            case .oscilloscope:
                // Instantaneous frequency readout — each x maps to a spectrum position
                var bandAmps = [Double](repeating: 0, count: barCount)
                for i in 0..<barCount {
                    bandAmps[i] = amplitudeForBar(i, time: time)
                }
                for x in 0..<w {
                    // Map x to a position in the band array with linear interpolation
                    let bandPos = Double(x) / Double(w - 1) * Double(barCount - 1)
                    let lo = Int(bandPos)
                    let hi = min(lo + 1, barCount - 1)
                    let frac = bandPos - Double(lo)
                    let amp = bandAmps[lo] * (1 - frac) + bandAmps[hi] * frac
                    let pixelY = max(0, min(h - 1, Int(Double(h - 1) * (1 - amp))))
                    let dist = abs(pixelY - h / 2)
                    let maxDist = h / 2
                    let ci: Int
                    if maxDist <= 3 {
                        ci = dist == 0 ? 18 : dist == 1 ? 20 : 22
                    } else {
                        ci = dist <= 1 ? 18 : dist <= 3 ? 19 : dist <= 5 ? 20 : dist <= 6 ? 21 : 22
                    }
                    fill(x, pixelY, colorAt(ci))
                }
            case .off: break
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: imgW, height: imgH,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: imgW * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private func amplitudeForBar(_ i: Int, time: Double) -> Double {
        // Map bar index to the 19 spectrum bands when using fewer bars
        let bandIndex = barCount < Self.spectrumBands
            ? Int(Double(i) / Double(barCount) * Double(Self.spectrumBands))
            : i
        guard let data = Self.spectrumData, Self.spectrumFrameCount > 0 else {
            let freq = Double(bandIndex) / Double(Self.spectrumBands)
            let base = (1.0 - freq * 0.5) * 0.55
            return max(0, min(1, base + sin(time * 2.3 + Double(bandIndex) * 0.5) * 0.25))
        }
        let frameIndex = Int(time * 30) % Self.spectrumFrameCount
        let offset = frameIndex * Self.spectrumBands + min(bandIndex, Self.spectrumBands - 1)
        return Double(data[offset]) / 255.0
    }
}

// MARK: - Winamp Title Bar

struct WinampTitleBar: View {
    let bitmap: NSImage
    var isActive: Bool = true
    var onOptions: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onShade: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.winampScale) private var scale

    // Button sprite locations in titlebar.bmp (all 9x9)
    struct TitleButton {
        let region: WinampSkin.ButtonRegion  // position on main window
        let normalX: CGFloat                  // sprite x for normal state
        let normalY: CGFloat                  // sprite y for normal state
        let pressedX: CGFloat                 // sprite x for pressed state
        let pressedY: CGFloat                 // sprite y for pressed state
    }

    private let optionsBtn = TitleButton(
        region: WinampSkin.titleBarOptionsButton,
        normalX: 0, normalY: 0, pressedX: 0, pressedY: 9)
    private let minimizeBtn = TitleButton(
        region: WinampSkin.titleBarMinimizeButton,
        normalX: 9, normalY: 0, pressedX: 9, pressedY: 9)
    private let shadeBtn = TitleButton(
        region: WinampSkin.titleBarShadeButton,
        normalX: 0, normalY: 18, pressedX: 9, pressedY: 18)
    private let closeBtn = TitleButton(
        region: WinampSkin.titleBarCloseButton,
        normalX: 18, normalY: 0, pressedX: 18, pressedY: 9)

    var body: some View {
        GeometryReader { _ in
            // Title bar background
            if let bgImage = extractBackground() {
                Image(nsImage: bgImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(WinampSkin.titleBarRegion.width) * scale,
                           height: CGFloat(WinampSkin.titleBarRegion.height) * scale)
                    .offset(x: CGFloat(WinampSkin.titleBarRegion.x) * scale,
                            y: CGFloat(WinampSkin.titleBarRegion.y) * scale)
                    .onTapGesture(count: 2) {
                        onShade?()
                    }
            }

            // Options button
            WinampTitleBarButton(bitmap: bitmap, button: optionsBtn) {
                onOptions?()
            }

            // Minimize button
            WinampTitleBarButton(bitmap: bitmap, button: minimizeBtn) {
                onMinimize?()
            }

            // Shade button
            WinampTitleBarButton(bitmap: bitmap, button: shadeBtn) {
                onShade?()
            }

            // Close button
            WinampTitleBarButton(bitmap: bitmap, button: closeBtn) {
                onClose?()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func extractBackground() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Active: (27, 0) 275x14, Inactive: (27, 15) 275x14
        let y: CGFloat = isActive ? 0 : 15
        let sourceRect = CGRect(x: 27, y: y, width: 275, height: 14)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 275, height: 14))
    }
}

struct WinampTitleBarButton: View {
    let bitmap: NSImage
    let button: WinampTitleBar.TitleButton
    let action: () -> Void
    @Environment(\.winampScale) private var scale

    @State private var isPressed = false

    var body: some View {
        if let sprite = extractSprite() {
            Image(nsImage: sprite)
                .resizable()
                .interpolation(.none)
                .frame(width: CGFloat(button.region.width) * scale, height: CGFloat(button.region.height) * scale)
                .offset(x: CGFloat(button.region.x) * scale, y: CGFloat(button.region.y) * scale)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPressed = true }
                        .onEnded { _ in
                            isPressed = false
                            action()
                        }
                )
        }
    }

    private func extractSprite() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let x = isPressed ? button.pressedX : button.normalX
        let y = isPressed ? button.pressedY : button.normalY
        let sourceRect = CGRect(x: x, y: y, width: 9, height: 9)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 9, height: 9))
    }
}

// MARK: - Winamp Clutterbar

struct WinampClutterBar: View {
    let bitmap: NSImage
    let region: WinampSkin.ButtonRegion
    var isAlwaysOnTop: Bool = false
    var isInfoOpen: Bool = false
    var isScaled: Bool = true
    var onOptions: (() -> Void)? = nil
    var onAlwaysOnTop: (() -> Void)? = nil
    var onInfo: (() -> Void)? = nil
    var onCycleScale: (() -> Void)? = nil
    @Environment(\.winampScale) private var scale

    // Button layout within clutterbar: (yOffset, height)
    // Selected sprite locations in titlebar.bmp: (x, y, w, h)
    private struct ClutterButton {
        let yOffset: CGFloat
        let height: CGFloat
        let spriteX: CGFloat
        let spriteY: CGFloat
    }

    private let buttons: [ClutterButton] = [
        ClutterButton(yOffset: 3, height: 8, spriteX: 304, spriteY: 47),   // O
        ClutterButton(yOffset: 11, height: 7, spriteX: 312, spriteY: 55),  // A
        ClutterButton(yOffset: 18, height: 7, spriteX: 320, spriteY: 62),  // I
        ClutterButton(yOffset: 25, height: 8, spriteX: 328, spriteY: 69),  // D
        ClutterButton(yOffset: 33, height: 7, spriteX: 336, spriteY: 77),  // V
    ]

    var body: some View {
        GeometryReader { _ in
            // Visual overlay at x=10
            if let rendered = renderClutterBar() {
                Image(nsImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
                    .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            // Hit area at x=13 (3px right of image to match main.bmp letter positions)
            Color.clear
                .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let localY = value.location.y / scale
                            for (index, button) in buttons.enumerated() {
                                if localY >= button.yOffset && localY < button.yOffset + button.height {
                                    handleTap(index)
                                    break
                                }
                            }
                        }
                )
                .padding(.leading, CGFloat(region.x + 3) * scale)
                .padding(.top, CGFloat(region.y) * scale)
        }
    }

    private func handleTap(_ index: Int) {
        switch index {
        case 0: onOptions?()      // O
        case 1: onAlwaysOnTop?()  // A
        case 2: onInfo?()         // I
        case 3: onCycleScale?()   // D
        default: break
        }
    }

    private func renderClutterBar() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        // Background: x=304, y=0, 8x43
        let bgRect = CGRect(x: 304, y: 0, width: 8, height: 43)
        guard let bgCropped = cgImage.cropping(to: bgRect) else { return nil }

        let rendered = NSImage(size: NSSize(width: 8, height: 43))
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        // Draw background
        let bgImage = NSImage(cgImage: bgCropped, size: NSSize(width: 8, height: 43))
        bgImage.draw(at: .zero, from: NSRect(origin: .zero, size: bgImage.size), operation: .copy, fraction: 1.0)

        // Overlay selected sprites for active buttons
        let activeButtons: [(Int, Bool)] = [(1, isAlwaysOnTop), (2, isInfoOpen), (3, isScaled)]
        for (index, isActive) in activeButtons where isActive {
            let btn = buttons[index]
            let spriteRect = CGRect(x: btn.spriteX, y: btn.spriteY, width: 8, height: btn.height)
            if let sprite = cgImage.cropping(to: spriteRect) {
                let spriteImage = NSImage(cgImage: sprite, size: NSSize(width: 8, height: btn.height))
                spriteImage.draw(at: NSPoint(x: 0, y: 43 - btn.yOffset - btn.height),
                                from: NSRect(origin: .zero, size: spriteImage.size),
                                operation: .sourceOver, fraction: 1.0)
            }
        }

        rendered.unlockFocus()
        return rendered
    }
}

// MARK: - Winamp Work LEDs

struct WinampWorkLED: View {
    let bitmap: NSImage
    let isPlaying: Bool
    let greenRegion: WinampSkin.ButtonRegion
    let redRegion: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    var body: some View {
        GeometryReader { _ in
            if let greenSprite = extractLED(spriteY: 0) {
                Image(nsImage: greenSprite)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(greenRegion.width) * scale, height: CGFloat(greenRegion.height) * scale)
                    .offset(x: CGFloat(greenRegion.x) * scale, y: CGFloat(greenRegion.y) * scale)
            }
            if let redSprite = extractLED(spriteY: 6) {
                Image(nsImage: redSprite)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(redRegion.width) * scale, height: CGFloat(redRegion.height) * scale)
                    .offset(x: CGFloat(redRegion.x) * scale, y: CGFloat(redRegion.y) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func extractLED(spriteY: CGFloat) -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // playpaus.bmp work LEDs: x=36 bright, x=39 dim
        // Green (y=0): bright when playing, dim otherwise
        // Red (y=6): dim when playing, bright otherwise
        let spriteX: CGFloat = isPlaying ? 36 : 39
        let sourceRect = CGRect(x: spriteX, y: spriteY, width: 3, height: 3)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 3, height: 3))
    }
}

// MARK: - Winamp Play/Pause Status Indicator

struct WinampPlayPausIndicator: View {
    let bitmap: NSImage
    let state: RoonZone.PlaybackState
    let region: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            if let sprite = extractSprite() {
                Image(nsImage: sprite)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
                    .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func extractSprite() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // playpaus.bmp: playing at x=0, paused at x=9, stopped at x=18 (all 9x9)
        let spriteX: CGFloat
        switch state {
        case .playing: spriteX = 0
        case .paused: spriteX = 9
        case .stopped: spriteX = 18
        case .loading: spriteX = 18
        }
        let sourceRect = CGRect(x: spriteX, y: 0, width: CGFloat(region.width), height: CGFloat(region.height))
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: region.width, height: region.height))
    }

    private func extractWorkLED(y: CGFloat) -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // playpaus.bmp work LEDs: two columns of 3x3 LEDs
        // x=36: bright state, x=39: dim state
        // Green LED at y=0, red LED at y=6
        let spriteX: CGFloat
        if y == 0 {
            // Green LED: bright when playing, dim otherwise
            spriteX = (state == .playing) ? 36 : 39
        } else {
            // Red LED: dim when playing, bright otherwise
            spriteX = (state == .playing) ? 36 : 39
        }
        let sourceRect = CGRect(x: spriteX, y: y, width: 3, height: 3)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 3, height: 3))
    }
}

// MARK: - Winamp Time Display Component

struct WinampTimeDisplay: View {
    let seekPosition: Int // seconds
    let bitmap: NSImage
    let region: WinampSkin.ButtonRegion
    var isPaused: Bool = false
    @Binding var showRemaining: Bool

    @EnvironmentObject var roonAPI: RoonAPI
    @Environment(\.winampScale) private var scale

    private func blinkVisible(at date: Date) -> Bool {
        guard isPaused else { return true }
        let half = Int(date.timeIntervalSinceReferenceDate)
        return half % 2 == 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            timeContent(at: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timeContent(at date: Date) -> some View {
        GeometryReader { geometry in
            if let renderedTime = renderTimeDisplay() {
                let charWidth: CGFloat = 9
                let baseOffset = CGFloat(region.x) + 9 - 12 - (charWidth + 4)

                Image(nsImage: renderedTime)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: renderedTime.size.width * scale, height: renderedTime.size.height * scale)
                    .offset(x: baseOffset * scale, y: CGFloat(region.y) * scale)
                    .opacity(blinkVisible(at: date) ? 1 : 0)
                    .allowsHitTesting(true)
                    .onTapGesture {
                        showRemaining.toggle()
                    }
            }
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        // Calculate time to display
        let timeToShow: Int
        let isNegative: Bool
        
        if showRemaining, let zone = roonAPI.currentZone, 
           let nowPlaying = zone.nowPlaying, 
           let length = nowPlaying.length {
            // Show remaining time
            timeToShow = max(0, length - seconds)
            isNegative = true
        } else {
            // Show elapsed time
            timeToShow = seconds
            isNegative = false
        }
        
        let minutes = timeToShow / 60
        let secs = timeToShow % 60
        
        // Format as individual digits with leading zero for minutes: M1 M2 S1 S2
        let m1 = minutes / 10
        let m2 = minutes % 10
        let s1 = secs / 10
        let s2 = secs % 10
        
        // Always show 4 digits with leading zero for minutes if needed
        if isNegative {
            return "-\(m1)\(m2)\(s1)\(s2)"  // -MM SS (always 4 digits)
        } else {
            return "\(m1)\(m2)\(s1)\(s2)"  // MM SS (always 4 digits)
        }
    }
    
    private func renderTimeDisplay() -> NSImage? {
        let timeString = formatTime(seekPosition)
        let charWidth: CGFloat = 9
        let charHeight: CGFloat = 13
        
        // Check if we have a minus sign
        let hasMinus = timeString.first == "-"
        let digits = hasMinus ? String(timeString.dropFirst()) : timeString
        let digitCount = 4  // Always 4 digits now (MM SS)
        
        // Calculate width needed for digits with proper spacing
        // Layout: M1 [3px] M2 [9px] S1 [3px] S2
        let digitsWidth: CGFloat = (CGFloat(digitCount) * charWidth) + 3 + 9 + 3
        
        // ALWAYS include space for the minus sign on the left, even when not showing it
        // This keeps the image width constant and the digits in the same position
        let minusSpace: CGFloat = charWidth + 4  // 9px for minus + 4px gap
        let totalWidth: CGFloat = minusSpace + digitsWidth
        
        // Create image for the time display
        let renderedImage = NSImage(size: NSSize(width: totalWidth, height: charHeight))
        
        renderedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        // Fill with transparent background
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: totalWidth, height: charHeight).fill()
        
        // Digits ALWAYS start at position minusSpace (after the space reserved for minus)
        let digitStartX: CGFloat = minusSpace
        var xOffset: CGFloat = digitStartX
        
        // Draw minus sign before digits if needed
        if hasMinus {
            if let minusImage = extractDigit("-", charWidth: charWidth, charHeight: charHeight) {
                minusImage.draw(at: NSPoint(x: 0, y: 0),
                              from: NSRect(origin: .zero, size: minusImage.size),
                              operation: .sourceOver,
                              fraction: 1.0)
            }
        }
        
        for (index, char) in digits.enumerated() {
            if let charImage = extractDigit(char, charWidth: charWidth, charHeight: charHeight) {
                charImage.draw(at: NSPoint(x: xOffset, y: 0),
                              from: NSRect(origin: .zero, size: charImage.size),
                              operation: .sourceOver,  // Changed from .copy to .sourceOver
                              fraction: 1.0)
            }
            
            xOffset += charWidth
            
            // Add spacing after this digit (always 4 digits: M1 [3px] M2 [9px] S1 [3px] S2)
            if index == 0 {
                xOffset += 3  // After M1
            } else if index == 1 {
                xOffset += 9  // After M2 (before seconds)
            } else if index == 2 {
                xOffset += 3  // After S1
            }
        }
        
        renderedImage.unlockFocus()
        
        return renderedImage
    }
    
    private func extractDigit(_ char: Character, charWidth: CGFloat, charHeight: CGFloat) -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let bitmapWidth = CGFloat(cgImage.width)
        let digitMap = "0123456789 -"  // Blank at position 10, minus at position 11
        
        guard let index = digitMap.firstIndex(of: char) else {
            return NSImage(size: NSSize(width: charWidth, height: charHeight))
        }
        
        let col = digitMap.distance(from: digitMap.startIndex, to: index)
        let xPosition = CGFloat(col) * charWidth
        
        if xPosition + charWidth > bitmapWidth {
            if char == ":" {
                let colonImage = NSImage(size: NSSize(width: charWidth, height: charHeight))
                colonImage.lockFocus()
                NSColor.green.set()
                NSRect(x: 3, y: 3, width: 2, height: 2).fill()
                NSRect(x: 3, y: 8, width: 2, height: 2).fill()
                colonImage.unlockFocus()
                return colonImage
            } else if char == "-" {
                // Extract minus dash from numbers.bmp at (20, 6) size 5x1
                // This is the standard Webamp approach - a pixel strip from within the digit area
                let dashRect = CGRect(x: 20, y: 6, width: 5, height: 1)
                if let dash = cgImage.cropping(to: dashRect) {
                    let result = NSImage(size: NSSize(width: charWidth, height: charHeight))
                    result.lockFocus()
                    NSImage(cgImage: dash, size: NSSize(width: 5, height: 1))
                        .draw(in: NSRect(x: 3, y: 6, width: 5, height: 1),
                              from: NSRect(origin: .zero, size: NSSize(width: 5, height: 1)),
                              operation: .copy, fraction: 1.0)
                    result.unlockFocus()
                    return result
                }
                return NSImage(size: NSSize(width: charWidth, height: charHeight))
            }
            return NSImage(size: NSSize(width: charWidth, height: charHeight))
        }
        
        let sourceRect = CGRect(x: xPosition, y: 0, width: charWidth, height: charHeight)
        
        guard let croppedCGImage = cgImage.cropping(to: sourceRect) else {
            return nil
        }
        
        return NSImage(cgImage: croppedCGImage, size: NSSize(width: charWidth, height: charHeight))
    }
}

// MARK: - Winamp Bitmap Text Component

struct WinampBitmapText: View {
    let text: String
    let bitmap: NSImage
    let region: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollTimer: Timer?
    @State private var scrollDirection: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            if let renderedText = renderBitmapText() {
                let textWidth = renderedText.size.width
                let regionWidth = CGFloat(region.width)
                let needsScrolling = textWidth > regionWidth

                ZStack(alignment: .leading) {
                    Image(nsImage: renderedText)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: textWidth * scale, height: 6 * scale)
                        .offset(x: needsScrolling ? -scrollOffset * scale : 0)
                }
                .frame(width: regionWidth * scale, height: 6 * scale, alignment: .leading)
                .clipped()
                .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
                .onAppear {
                    if needsScrolling {
                        startScrolling(textWidth: textWidth, regionWidth: regionWidth)
                    }
                }
                .onDisappear {
                    stopScrolling()
                }
            } else {
                Text("TEXT NIL")
                    .foregroundColor(.red)
                    .font(.system(size: 8))
                    .offset(x: CGFloat(region.x), y: CGFloat(region.y))
                    .onAppear {
                        print("❌ renderBitmapText returned nil for text: '\(text)'")
                    }
            }
        }
    }

    private func startScrolling(textWidth: CGFloat, regionWidth: CGFloat) {
        scrollOffset = 0
        scrollDirection = 1.0
        let maxScroll = textWidth - regionWidth + 10

        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            scrollOffset += scrollDirection * 0.5

            if scrollOffset >= maxScroll {
                scrollDirection = -1.0
                scrollOffset = maxScroll
            } else if scrollOffset <= 0 {
                scrollDirection = 1.0
                scrollOffset = 0
            }
        }
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }
    
    private func renderBitmapText() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6
        let spacing: CGFloat = 1
        
        let upperText = text.uppercased()
        let totalWidth = CGFloat(upperText.count) * (charWidth + spacing)
        
        let renderedImage = NSImage(size: NSSize(width: totalWidth, height: charHeight))
        
        renderedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        var xOffset: CGFloat = 0
        
        for char in upperText {
            if let charImage = extractCharacter(char, charWidth: charWidth, charHeight: charHeight) {
                charImage.draw(at: NSPoint(x: xOffset, y: 0),
                              from: NSRect(origin: .zero, size: charImage.size),
                              operation: .copy,
                              fraction: 1.0)
            }
            xOffset += charWidth + spacing
        }
        
        renderedImage.unlockFocus()
        
        return renderedImage
    }
    
    private func extractCharacter(_ char: Character, charWidth: CGFloat, charHeight: CGFloat) -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let bitmapHeight = CGFloat(cgImage.height)
        
        let row0 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@   "
        let row1 = "0123456789 .:()-\'!_+\\/[]^&%,=$#"
        let row2 = "  ?*                            "
        
        let charMaps = [row0, row1, row2]
        
        // Handle space - return blank
        if char == " " {
            return NSImage(size: NSSize(width: charWidth, height: charHeight))
        }
        
        // Find character in the map
        for (rowIndex, charMap) in charMaps.enumerated() {
            if let index = charMap.firstIndex(of: char) {
                let col = charMap.distance(from: charMap.startIndex, to: index)
                
                // For text.bmp, row 0 starts at y=0 (top), not bottom
                // Standard Winamp text.bmp is 155x18 (31 chars x 3 rows)
                let yPosition = CGFloat(rowIndex) * charHeight
                
                let sourceRect = CGRect(
                    x: CGFloat(col) * charWidth,
                    y: yPosition,
                    width: charWidth,
                    height: charHeight
                )
                
                guard let croppedCGImage = cgImage.cropping(to: sourceRect) else {
                    return nil
                }
                
                return NSImage(cgImage: croppedCGImage, size: NSSize(width: charWidth, height: charHeight))
            }
        }
        
        // Unknown character - return blank
        return NSImage(size: NSSize(width: charWidth, height: charHeight))
    }
}

// MARK: - Winamp Info Display (kbps/kHz)

struct WinampInfoDisplay: View {
    let text: String
    let bitmap: NSImage
    let region: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            if let rendered = renderText() {
                Image(nsImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: rendered.size.width * scale, height: rendered.size.height * scale)
                    .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func renderText() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6

        let totalWidth = CGFloat(text.count) * charWidth
        let renderedImage = NSImage(size: NSSize(width: totalWidth, height: charHeight))

        renderedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        var xOffset: CGFloat = 0
        for char in text.uppercased() {
            if let charImage = extractCharacter(char, from: cgImage, charWidth: charWidth, charHeight: charHeight) {
                charImage.draw(at: NSPoint(x: xOffset, y: 0),
                              from: NSRect(origin: .zero, size: charImage.size),
                              operation: .copy,
                              fraction: 1.0)
            }
            xOffset += charWidth
        }

        renderedImage.unlockFocus()
        return renderedImage
    }

    private func extractCharacter(_ char: Character, from cgImage: CGImage, charWidth: CGFloat, charHeight: CGFloat) -> NSImage? {
        let row0 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@   "
        let row1 = "0123456789 .:()-\'!_+\\/[]^&%,=$#"
        let row2 = "  ?*                            "
        let charMaps = [row0, row1, row2]

        if char == " " {
            return NSImage(size: NSSize(width: charWidth, height: charHeight))
        }

        for (rowIndex, charMap) in charMaps.enumerated() {
            if let index = charMap.firstIndex(of: char) {
                let col = charMap.distance(from: charMap.startIndex, to: index)
                let yPosition = CGFloat(rowIndex) * charHeight
                let sourceRect = CGRect(x: CGFloat(col) * charWidth, y: yPosition, width: charWidth, height: charHeight)
                guard let croppedCGImage = cgImage.cropping(to: sourceRect) else { return nil }
                return NSImage(cgImage: croppedCGImage, size: NSSize(width: charWidth, height: charHeight))
            }
        }
        return NSImage(size: NSSize(width: charWidth, height: charHeight))
    }
}

// MARK: - Winamp Mono/Stereo Display

struct WinampMonoStereoDisplay: View {
    let bitmap: NSImage
    let isStereo: Bool
    let region: WinampSkin.ButtonRegion
    @Environment(\.winampScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            if let rendered = renderIndicator() {
                Image(nsImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: rendered.size.width * scale, height: rendered.size.height * scale)
                    .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func renderIndicator() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        // monoster.bmp layout (58x24):
        // Top row (y=0-11): active states - stereo (0,0 29x12) | mono (29,0 29x12)
        // Bottom row (y=12-23): inactive states - stereo (0,12 29x12) | mono (29,12 29x12)
        let halfWidth: CGFloat = 29
        let halfHeight: CGFloat = 12
        let totalWidth: CGFloat = 58
        let bitmapHeight = CGFloat(cgImage.height)

        let renderedImage = NSImage(size: NSSize(width: totalWidth, height: halfHeight))
        renderedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        // Display order: mono (left), stereo (right) — matching Winamp layout
        // Bitmap layout: stereo at x=0, mono at x=29; top row=active, bottom row=inactive

        // Mono indicator (drawn on left): active if mono, inactive if stereo
        let monoY: CGFloat = isStereo ? halfHeight : 0
        let monoRect = CGRect(x: halfWidth, y: monoY, width: halfWidth, height: halfHeight)
        if let monoImage = cgImage.cropping(to: monoRect) {
            let nsImage = NSImage(cgImage: monoImage, size: NSSize(width: halfWidth, height: halfHeight))
            nsImage.draw(at: NSPoint(x: 0, y: 0),
                        from: NSRect(origin: .zero, size: nsImage.size),
                        operation: .copy,
                        fraction: 1.0)
        }

        // Stereo indicator (drawn on right): active if stereo, inactive if mono
        let stereoY: CGFloat = isStereo ? 0 : halfHeight
        let stereoRect = CGRect(x: 0, y: stereoY, width: halfWidth, height: halfHeight)
        if let stereoImage = cgImage.cropping(to: stereoRect) {
            let nsImage = NSImage(cgImage: stereoImage, size: NSSize(width: halfWidth, height: halfHeight))
            nsImage.draw(at: NSPoint(x: halfWidth, y: 0),
                        from: NSRect(origin: .zero, size: nsImage.size),
                        operation: .copy,
                        fraction: 1.0)
        }

        renderedImage.unlockFocus()
        return renderedImage
    }
}

// MARK: - Winamp Position Slider Component

struct WinampPositionSlider: View {
    let bitmap: NSImage
    let progress: Double
    let region: WinampSkin.ButtonRegion
    let onSeek: (Double) -> Void
    @Environment(\.winampScale) private var scale

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var dragStartProgress: Double = 0
    @State private var pendingSeekProgress: Double? = nil

    private let thumbWidth: CGFloat = 29

    var body: some View {
        ZStack(alignment: .leading) {
            if let backgroundImage = extractPositionBarBackground() {
                Image(nsImage: backgroundImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            }

            if let sliderButton = extractSliderButton() {
                Image(nsImage: sliderButton)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: thumbWidth * scale, height: 10 * scale)
                    .offset(x: calculateSliderPosition())
            }
        }
        .overlay(WindowDragBlocker())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let maxOffset = (CGFloat(region.width) - thumbWidth) * scale

                    if !isDragging {
                        isDragging = true
                        dragStartProgress = pendingSeekProgress ?? progress
                        dragProgress = dragStartProgress
                    }

                    let progressDelta = value.translation.width / maxOffset
                    let newProgress = max(0, min(1, dragStartProgress + progressDelta))
                    dragProgress = newProgress
                }
                .onEnded { value in
                    isDragging = false
                    pendingSeekProgress = dragProgress
                    onSeek(dragProgress)
                }
        )
        .padding(.leading, CGFloat(region.x) * scale)
        .padding(.top, CGFloat(region.y) * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var effectiveProgress: Double {
        if isDragging { return dragProgress }
        if let pending = pendingSeekProgress {
            // Clear pending once the live progress has moved past it (server confirmed seek)
            if abs(progress - pending) > 0.01 {
                Task { @MainActor in pendingSeekProgress = nil }
                return progress
            }
            return pending
        }
        return progress
    }

    private func calculateSliderPosition() -> CGFloat {
        let maxOffset = (CGFloat(region.width) - thumbWidth) * scale
        return effectiveProgress * maxOffset
    }
    
    private func extractPositionBarBackground() -> NSImage? {
        // posbar.bmp layout:
        // Top half: position bar background (248x10)
        // Bottom half: slider button states
        
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        // Extract the top portion (background)
        let sourceRect = CGRect(x: 0, y: 0, width: 248, height: 10)
        
        guard let croppedCGImage = cgImage.cropping(to: sourceRect) else {
            return nil
        }
        
        return NSImage(cgImage: croppedCGImage, size: NSSize(width: 248, height: 10))
    }
    
    private func extractSliderButton() -> NSImage? {
        // posbar.bmp layout:
        // The slider button (thumb) is typically in the lower portion
        // Standard Winamp slider button: 29x10 pixels
        // Position: (248, 0) - normal state
        
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        // Extract the slider button (thumb)
        let sourceRect = CGRect(x: 248, y: 0, width: 29, height: 10)
        
        guard let croppedCGImage = cgImage.cropping(to: sourceRect) else {
            return nil
        }
        
        return NSImage(cgImage: croppedCGImage, size: NSSize(width: 29, height: 10))
    }
}

// MARK: - Winamp Volume/Balance Slider Component

struct WinampVolumeSlider: View {
    let bitmap: NSImage
    let progress: Double
    let region: WinampSkin.ButtonRegion
    let frameCount: Int
    let frameHeight: CGFloat
    let bitmapWidth: CGFloat
    let onValueChange: ((Double) -> Void)?
    var thumbBitmap: NSImage? = nil
    var thumbProgress: Double? = nil
    var cropX: CGFloat = 0
    var centerBased: Bool = false
    @Environment(\.winampScale) private var scale

    private let thumbWidth: CGFloat = 14
    private let thumbHeight: CGFloat = 11

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var dragStartProgress: Double = 0

    var body: some View {
        ZStack(alignment: .leading) {
            if let bgImage = extractBackgroundFrame() {
                Image(nsImage: bgImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            }

            if let thumbImage = extractThumb() {
                Image(nsImage: thumbImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: thumbWidth * scale, height: thumbHeight * scale)
                    .offset(x: calculateThumbPosition())
            }
        }
        .overlay(WindowDragBlocker())
        .offset(x: CGFloat(region.x) * scale, y: (CGFloat(region.y) - 1) * scale)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let maxOffset = (CGFloat(region.width) - thumbWidth) * scale
                    if !isDragging {
                        isDragging = true
                        let startProgress = thumbProgress ?? progress
                        dragStartProgress = startProgress
                        dragProgress = dragStartProgress
                    }
                    let progressDelta = value.translation.width / maxOffset
                    dragProgress = max(0, min(1, dragStartProgress + progressDelta))
                }
                .onEnded { _ in
                    isDragging = false
                    onValueChange?(dragProgress)
                }
        )
    }

    private var effectiveProgress: Double {
        let thumbPos = effectiveThumbProgress
        if centerBased {
            return abs(thumbPos - 0.5) * 2
        }
        return isDragging ? dragProgress : progress
    }

    private var effectiveThumbProgress: Double {
        isDragging ? dragProgress : (thumbProgress ?? progress)
    }

    private func calculateThumbPosition() -> CGFloat {
        let maxOffset = (CGFloat(region.width) - thumbWidth) * scale
        return effectiveThumbProgress * maxOffset
    }

    private func extractBackgroundFrame() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let frameIndex = min(frameCount - 1, Int(effectiveProgress * Double(frameCount - 1)))
        let displayHeight = CGFloat(region.height)
        let sourceRect = CGRect(x: 0, y: CGFloat(frameIndex) * frameHeight, width: bitmapWidth, height: displayHeight)
        guard let fullFrame = cgImage.cropping(to: sourceRect) else { return nil }

        // If display region is narrower than bitmap, crop from cropX offset
        let regionW = CGFloat(region.width)
        if regionW < bitmapWidth {
            let cropRect = CGRect(x: cropX, y: 0, width: regionW, height: displayHeight)
            guard let cropped = fullFrame.cropping(to: cropRect) else { return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: regionW, height: displayHeight))
        }
        return NSImage(cgImage: fullFrame, size: NSSize(width: bitmapWidth, height: displayHeight))
    }

    private func extractThumb() -> NSImage? {
        let source = thumbBitmap ?? bitmap
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let thumbY = CGFloat(frameCount) * frameHeight + 2  // thumbs at y=422 (2px below frame area)
        // Normal thumb at x=15, pressed at x=0
        let thumbX: CGFloat = isDragging ? 0 : 15
        let sourceRect = CGRect(x: thumbX, y: thumbY, width: thumbWidth, height: thumbHeight)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: thumbWidth, height: thumbHeight))
    }
}

// MARK: - Winamp Button Component

struct WinampButton: View {
    let bitmap: NSImage
    let buttonIndex: Int
    let region: WinampSkin.ButtonRegion
    let action: () -> Void
    @Environment(\.winampScale) private var scale

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            if let buttonImage = extractButtonImage() {
                Image(nsImage: buttonImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            } else {
                Color.clear
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            }
        }
        .buttonStyle(WinampButtonStyle(isPressed: $isPressed))
        .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
    }
    
    private func extractButtonImage() -> NSImage? {
        // cbuttons.bmp layout (136x36):
        // [Previous 23px][Play 23px][Pause 23px][Stop 23px][Next 22px][Open 22px]
        // Top row: normal state, bottom row: pressed state

        let buttonHeight = CGFloat(region.height)
        let buttonWidth = CGFloat(region.width)

        // Button x offsets in bitmap: 0, 23, 46, 69, 92, 114
        let bitmapOffsets: [CGFloat] = [0, 23, 46, 69, 92, 114]
        guard buttonIndex < bitmapOffsets.count else { return nil }

        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let x = bitmapOffsets[buttonIndex]
        let y: CGFloat = isPressed ? buttonHeight : 0

        let sourceRect = CGRect(x: x, y: y, width: buttonWidth, height: buttonHeight)

        guard let croppedCGImage = cgImage.cropping(to: sourceRect) else {
            return nil
        }

        return NSImage(cgImage: croppedCGImage, size: NSSize(width: buttonWidth, height: buttonHeight))
    }
}

// MARK: - Winamp Toggle Button Component (Shuffle/Repeat)

struct WinampToggleButton: View {
    let bitmap: NSImage
    let isOn: Bool
    let region: WinampSkin.ButtonRegion
    let bitmapX: CGFloat
    let bitmapWidth: CGFloat
    var bitmapY: CGFloat = 0
    var rowHeight: CGFloat = 15
    var topBorder: CGFloat = 0
    var twoRow: Bool = false  // EQ/PL buttons only have 2 rows (off, on) — no separate pressed states
    let action: () -> Void
    @Environment(\.winampScale) private var scale

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            if let buttonImage = extractToggleImage() {
                Image(nsImage: buttonImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            } else {
                Color.clear
                    .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            }
        }
        .buttonStyle(WinampButtonStyle(isPressed: $isPressed))
        .offset(x: CGFloat(region.x) * scale, y: CGFloat(region.y) * scale)
    }

    private func extractToggleImage() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let y: CGFloat
        if twoRow {
            // 2-row layout (EQ/PL): row 0 = off, row 1 = on
            y = bitmapY + (isOn ? rowHeight : 0)
        } else {
            // 4-row layout (shuffle/repeat): off-unpressed, off-pressed, on-unpressed, on-pressed
            if isOn {
                y = bitmapY + (isPressed ? rowHeight * 3 : rowHeight * 2)
            } else {
                y = bitmapY + (isPressed ? rowHeight : 0)
            }
        }

        let contentHeight = rowHeight - topBorder
        let sourceRect = CGRect(x: bitmapX, y: y + topBorder, width: bitmapWidth, height: contentHeight)
        guard let croppedCGImage = cgImage.cropping(to: sourceRect) else {
            return nil
        }

        return NSImage(cgImage: croppedCGImage, size: NSSize(width: bitmapWidth, height: contentHeight))
    }
}

struct WinampButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

/// Blocks window dragging in an area so SwiftUI gestures can handle drags instead
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NoDragView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Window Region Shape

/// Clips the window content to the polygons defined in region.txt
struct WinampRegionShape: Shape {
    let polygons: [[CGPoint]]?
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        guard let polygons = polygons, !polygons.isEmpty else {
            return Path(rect)
        }
        var path = Path()
        for polygon in polygons {
            guard polygon.count >= 3 else { continue }
            var poly = Path()
            poly.move(to: CGPoint(x: polygon[0].x * scale, y: polygon[0].y * scale))
            for i in 1..<polygon.count {
                poly.addLine(to: CGPoint(x: polygon[i].x * scale, y: polygon[i].y * scale))
            }
            poly.closeSubpath()
            path.addPath(poly)
        }
        return path
    }
}

#if os(macOS)
import AppKit

enum WinampWindow {
    static weak var current: NSWindow?
    static weak var playlist: NSWindow?
    static weak var albumArt: NSWindow?
    static var isSnapped: Bool = false {
        didSet {
            guard isSnapped != oldValue else { return }
            if isSnapped {
                if let main = current, let pl = playlist,
                   !(main.childWindows?.contains(pl) ?? false) {
                    main.addChildWindow(pl, ordered: .below)
                }
            } else {
                if let main = current, let pl = playlist {
                    main.removeChildWindow(pl)
                }
            }
        }
    }
    static var snapOffset: NSPoint = .zero
    static var isMovingProgrammatically: Bool = false
    static var isPlaylistDragging: Bool = false
}


struct WindowAccessorWinamp: NSViewRepresentable {
    let scale: CGFloat
    let isWindowShade: Bool
    let hasRegion: Bool
    @Binding var isWindowActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                WinampWindow.current = window
                self.configureWindow(window)
                window.delegate = context.coordinator
                context.coordinator.window = window

                // Listen for alwaysOnTop changes
                NotificationCenter.default.addObserver(
                    forName: .alwaysOnTopChanged,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let alwaysOnTop = notification.object as? Bool {
                        window.level = alwaysOnTop ? .floating : .normal
                    }
                }

                // When main window moves while snapped, update saved playlist frame
                // so reopening the playlist places it at the correct position
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    guard WinampWindow.isSnapped else { return }
                    let mainFrame = window.frame
                    if let pl = WinampWindow.playlist, pl.isVisible {
                        // Playlist is visible — its own didMove observer saves its frame
                    } else {
                        // Playlist is hidden — save the expected snap position
                        let expectedX = mainFrame.origin.x + WinampWindow.snapOffset.x
                        let expectedY = mainFrame.origin.y + WinampWindow.snapOffset.y
                        let defaults = UserDefaults.standard
                        let oldW = defaults.double(forKey: "playlistWindowW")
                        let oldH = defaults.double(forKey: "playlistWindowH")
                        guard oldW > 0, oldH > 0 else { return }
                        defaults.set(expectedX, forKey: "playlistWindowX")
                        defaults.set(expectedY, forKey: "playlistWindowY")
                    }
                }

                // Track app active state for titlebar
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { _ in isWindowActive = true }
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { _ in isWindowActive = false }

            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            DispatchQueue.main.async {
                self.configureWindow(window)
            }
        }
    }

    private func configureWindow(_ window: NSWindow) {
        let height: CGFloat = isWindowShade ? CGFloat(WinampSkin.windowShadeHeight) : 116
        let size = NSSize(width: 275 * scale, height: height * scale)

        // Completely borderless - no title bar at all
        window.styleMask = [.borderless, .miniaturizable]

        // Anchor resize to top-left: preserve the top of the window frame
        let oldFrame = window.frame
        let newOriginY = oldFrame.maxY - size.height
        let newFrame = NSRect(x: oldFrame.minX, y: newOriginY, width: size.width, height: size.height)
        if window.frame.size != size {
            window.setFrame(newFrame, display: true, animate: false)
        }
        window.minSize = size
        window.maxSize = size

        // Make window movable by dragging anywhere
        window.isMovableByWindowBackground = true

        // Transparent background for shaped windows (region.txt), near-zero alpha
        // for rectangular windows to prevent macOS click-through on borderless windows
        window.isOpaque = false
        window.backgroundColor = hasRegion ? .clear : NSColor(white: 0, alpha: 0.005)

        // No shadow (Winamp classic didn't have shadows)
        window.hasShadow = false

        // Set window level based on preference
        let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        window.level = alwaysOnTop ? .floating : .normal
    }

    class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        private var dragMonitor: Any?
        private var mouseUpMonitor: Any?

        func windowWillMove(_ notification: Notification) {
            // When snapped, child window handles movement automatically.
            // Only set up snap detection when not snapped.
            if !WinampWindow.isSnapped {
                startDragMonitors()
            }
        }

        private func startDragMonitors() {
            if dragMonitor == nil {
                dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                    self?.checkSnapDuringDrag()
                    return event
                }
            }
            if mouseUpMonitor == nil {
                mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                    self?.cleanupMonitors()
                    return event
                }
            }
        }

        private func checkSnapDuringDrag() {
            guard !WinampWindow.isSnapped,
                  !WinampWindow.isPlaylistDragging,
                  let mainWindow = window,
                  let playlistWindow = WinampWindow.playlist else { return }
            let mainFrame = mainWindow.frame
            let plFrame = playlistWindow.frame
            let snapDistance: CGFloat = 25
            let leftAligned = abs(plFrame.minX - mainFrame.minX) < snapDistance

            let mainBottomNearPlTop = abs(mainFrame.minY - plFrame.maxY) < snapDistance
            let mainTopNearPlBottom = abs(mainFrame.maxY - plFrame.minY) < snapDistance

            if mainBottomNearPlTop && leftAligned {
                let snappedOrigin = NSPoint(x: mainFrame.minX, y: mainFrame.minY - plFrame.height)
                WinampWindow.isMovingProgrammatically = true
                playlistWindow.setFrameOrigin(snappedOrigin)
                WinampWindow.isMovingProgrammatically = false
                WinampWindow.isSnapped = true
                WinampWindow.snapOffset = NSPoint(
                    x: snappedOrigin.x - mainFrame.origin.x,
                    y: snappedOrigin.y - mainFrame.origin.y
                )
                cleanupMonitors()
            } else if mainTopNearPlBottom && leftAligned {
                let snappedOrigin = NSPoint(x: mainFrame.minX, y: mainFrame.maxY)
                WinampWindow.isMovingProgrammatically = true
                playlistWindow.setFrameOrigin(snappedOrigin)
                WinampWindow.isMovingProgrammatically = false
                WinampWindow.isSnapped = true
                WinampWindow.snapOffset = NSPoint(
                    x: snappedOrigin.x - mainFrame.origin.x,
                    y: snappedOrigin.y - mainFrame.origin.y
                )
                cleanupMonitors()
            }
        }

        private func cleanupMonitors() {
            if let monitor = dragMonitor {
                NSEvent.removeMonitor(monitor)
                dragMonitor = nil
            }
            if let monitor = mouseUpMonitor {
                NSEvent.removeMonitor(monitor)
                mouseUpMonitor = nil
            }
        }

        deinit {
            cleanupMonitors()
        }
    }
}
#endif

// MARK: - Winamp Windowshade View

struct WinampWindowShadeView: View {
    let skin: WinampSkin
    let isWindowActive: Bool
    let currentSeekPosition: Int
    @Binding var showRemaining: Bool
    @Binding var displayMode: WSDisplayMode
    let onOptions: () -> Void
    let onUnshade: () -> Void
    let onMinimize: () -> Void
    let onClose: () -> Void
    let onSeek: (Double) -> Void
    @EnvironmentObject var roonAPI: RoonAPI
    @Environment(\.winampScale) private var scale

    enum WSDisplayMode: String, CaseIterable {
        case spectrum, oscilloscope, trackInfo, off
    }

    private let wsWidth: CGFloat = 275
    private let wsHeight: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background — contains all static graphics (transport buttons, position track, etc.)
            if let titleBarBitmap = skin.titleBarBitmap,
               let bgImage = extractWindowShadeBackground(from: titleBarBitmap) {
                Image(nsImage: bgImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: wsWidth * scale, height: wsHeight * scale)
                    .onTapGesture(count: 2) {
                        onUnshade()
                    }
            }

            // First dark rectangle: visualizer, track info, or off — single tap target
            wsVisualizerArea()

            // Playback time in the second dark rectangle, right-aligned
            if let textBitmap = skin.textBitmap {
                let seekPos = roonAPI.currentZone?.state == .playing
                    ? currentSeekPosition
                    : (roonAPI.currentZone?.nowPlaying?.seekPosition ?? 0)
                let timeText = formatCompactTime(seekPos)
                let charWidth = 5
                let textWidth = timeText.count * charWidth
                let rightEdge = WinampSkin.wsTimeRegion.x + WinampSkin.wsTimeRegion.width
                let alignedRegion = WinampSkin.ButtonRegion(
                    x: rightEdge - textWidth,
                    y: WinampSkin.wsTimeRegion.y,
                    width: textWidth,
                    height: WinampSkin.wsTimeRegion.height
                )
                WinampInfoDisplay(
                    text: timeText,
                    bitmap: textBitmap,
                    region: alignedRegion
                )
                .onTapGesture {
                    showRemaining.toggle()
                }
            }

            // Invisible transport button hit targets (graphics are in the background)
            windowShadeTransportHitTargets()

            // Position bar thumb only (track is in the background)
            if let titleBarBitmap = skin.titleBarBitmap {
                windowShadePositionBar(titleBarBitmap: titleBarBitmap)
            }

            // Window control buttons (need sprites for pressed states)
            if let titleBarBitmap = skin.titleBarBitmap {
                // Options button (top-left)
                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.titleBarOptionsButton,
                    normalX: 0, normalY: 0, pressedX: 0, pressedY: 9
                )) { onOptions() }

                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.wsMinimizeButton,
                    normalX: 9, normalY: 0, pressedX: 9, pressedY: 9
                )) { onMinimize() }

                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.wsUnshadeButton,
                    normalX: 0, normalY: 27, pressedX: 9, pressedY: 27
                )) { onUnshade() }

                WinampTitleBarButton(bitmap: titleBarBitmap, button: WinampTitleBar.TitleButton(
                    region: WinampSkin.wsCloseButton,
                    normalX: 18, normalY: 0, pressedX: 18, pressedY: 9
                )) { onClose() }
            }
        }
        .frame(width: wsWidth * scale, height: wsHeight * scale)
    }

    @ViewBuilder
    private func wsVisualizerArea() -> some View {
        let region = WinampSkin.wsVisualizerRegion
        ZStack {
            switch displayMode {
            case .spectrum, .oscilloscope:
                let visMode: VisualizerMode = displayMode == .spectrum ? .spectrum : .oscilloscope
                WinampVisualizer(
                    colors: skin.visColors,
                    isPlaying: roonAPI.currentZone?.state == .playing,
                    region: region,
                    scale: scale,
                    mode: .constant(visMode),
                    handleTapCycle: false,
                    sourceWidth: region.width,
                    sourceHeight: region.height,
                    barCount: region.width / 4
                )
                .allowsHitTesting(false)
            case .trackInfo:
                if let zone = roonAPI.currentZone, let nowPlaying = zone.nowPlaying,
                   let textBitmap = skin.textBitmap {
                    WinampBitmapText(
                        text: "\(nowPlaying.artist) - \(nowPlaying.title)",
                        bitmap: textBitmap,
                        region: region
                    )
                    .allowsHitTesting(false)
                }
            case .off:
                EmptyView()
            }

            // Single tap target covering the region
            Color.clear
                .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
                .contentShape(Rectangle())
                .onTapGesture { cycleDisplayMode() }
                .padding(.leading, CGFloat(region.x) * scale)
                .padding(.top, CGFloat(region.y) * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func cycleDisplayMode() {
        let all = WSDisplayMode.allCases
        let idx = all.firstIndex(of: displayMode) ?? 0
        displayMode = all[(idx + 1) % all.count]
    }

    private func formatCompactTime(_ seconds: Int) -> String {
        let timeToShow: Int
        let isNegative: Bool
        if showRemaining,
           let length = roonAPI.currentZone?.nowPlaying?.length {
            timeToShow = max(0, length - seconds)
            isNegative = true
        } else {
            timeToShow = seconds
            isNegative = false
        }
        let m = timeToShow / 60
        let s = timeToShow % 60
        let prefix = isNegative ? "-" : ""
        return String(format: "%@%02d %02d", prefix, m, s)
    }

    private func extractWindowShadeBackground(from bitmap: NSImage) -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let y: CGFloat = isWindowActive ? 29 : 42
        let sourceRect = CGRect(x: 27, y: y, width: 275, height: 14)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 275, height: 14))
    }

    @ViewBuilder
    private func windowShadeTransportHitTargets() -> some View {
        // Invisible hit areas — the button graphics are baked into the background
        invisibleHitTarget(region: WinampSkin.wsPreviousButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.previous(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsPlayButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.playPause(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsPauseButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.playPause(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsStopButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.pause(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsNextButton) {
            guard let zoneId = roonAPI.currentZone?.id else { return }
            Task { await roonAPI.next(zoneId: zoneId) }
        }
        invisibleHitTarget(region: WinampSkin.wsEjectButton) {
            // No eject action
        }
    }

    private func invisibleHitTarget(region: WinampSkin.ButtonRegion, action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: CGFloat(region.width) * scale, height: CGFloat(region.height) * scale)
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .padding(.leading, CGFloat(region.x) * scale)
            .padding(.top, CGFloat(region.y) * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func windowShadePositionBar(titleBarBitmap: NSImage) -> some View {
        let region = WinampSkin.wsPositionBarRegion
        let zone = roonAPI.currentZone
        let length = zone?.nowPlaying?.length ?? 0
        let seekPos = zone?.state == .playing ? currentSeekPosition : (zone?.nowPlaying?.seekPosition ?? 0)
        let progress = length > 0 ? min(1.0, max(0.0, Double(seekPos) / Double(length))) : 0.0

        WinampWindowShadePositionBar(
            bitmap: titleBarBitmap,
            progress: progress,
            region: region,
            onSeek: onSeek
        )
    }
}

// MARK: - Windowshade Position Bar (thumb only — track is in background)

private struct WinampWindowShadePositionBar: View {
    let bitmap: NSImage       // titlebar.bmp
    let progress: Double
    let region: WinampSkin.ButtonRegion
    let onSeek: (Double) -> Void
    @Environment(\.winampScale) private var scale

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var dragStartProgress: Double = 0

    private let thumbWidth: CGFloat = 3
    private let barWidth: CGFloat = 17
    private let barHeight: CGFloat = 7

    var body: some View {
        ZStack(alignment: .leading) {
            // Invisible area matching the bar dimensions for gesture detection
            Color.clear
                .frame(width: barWidth * scale, height: barHeight * scale)

            // Thumb only — track background is baked into the windowshade background
            if let thumb = extractThumb() {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: thumbWidth * scale, height: barHeight * scale)
                    .offset(x: calculateThumbPosition())
                    .allowsHitTesting(false)
            }
        }
        .overlay(WindowDragBlocker())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let maxOffset = (barWidth - thumbWidth) * scale
                    if !isDragging {
                        isDragging = true
                        dragStartProgress = progress
                        dragProgress = dragStartProgress
                    }
                    let progressDelta = value.translation.width / maxOffset
                    dragProgress = max(0, min(1, dragStartProgress + progressDelta))
                }
                .onEnded { _ in
                    isDragging = false
                    onSeek(dragProgress)
                }
        )
        .padding(.leading, CGFloat(region.x) * scale)
        .padding(.top, CGFloat(region.y) * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var effectiveProgress: Double {
        isDragging ? dragProgress : progress
    }

    private func calculateThumbPosition() -> CGFloat {
        let maxOffset = (barWidth - thumbWidth) * scale
        return effectiveProgress * maxOffset
    }

    private func extractThumb() -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sourceRect = CGRect(x: 20, y: 36, width: 3, height: 7)
        guard let cropped = cgImage.cropping(to: sourceRect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: 3, height: 7))
    }
}

#Preview {
    if let skinURL = Bundle.main.url(forResource: "base-2.91", withExtension: "wsz"),
       let skin = WinampSkinParser.parse(url: skinURL) {
        WinampSkinView(skin: skin)
            .environmentObject(RoonAPI(
                appInfo: RoonAppInfo(
                    extensionId: "com.yourcompany.roonamp",
                    displayName: "Roonamp",
                    displayVersion: "1.0.0",
                    publisher: "Your Name",
                    email: "your.email@example.com"
                )
            ))
    } else {
        Text("Failed to load skin")
    }
}
