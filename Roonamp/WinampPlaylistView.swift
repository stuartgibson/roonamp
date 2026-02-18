//
//  WinampPlaylistView.swift
//  Roonamp
//
//  Created by Stuart Gibson on 16/02/2026.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Main Playlist View

struct WinampPlaylistView: View {
    let skin: WinampSkin
    @EnvironmentObject var roonAPI: RoonAPI
    @EnvironmentObject var playback: PlaybackState
    @AppStorage("windowScale") private var windowScale: Double = 2.0
    private var scale: CGFloat { CGFloat(windowScale) }

    @State private var playlistSize: CGSize = CGSize(width: 275, height: 232) // default: 275x(116+116)
    @State private var isWindowActive: Bool = true
    @State private var scrollFractionState: CGFloat = 0
    @AppStorage("showRemaining") private var showRemaining: Bool = false
    @AppStorage("playlistWindowShade") private var isPlaylistShade: Bool = false
    @State private var selectedItemId: Int? = nil
    @State private var currentSeekPosition: Int = 0
    @StateObject private var scrollState = PlaylistScrollState()

    private var currentHeight: CGFloat {
        isPlaylistShade ? CGFloat(WinampSkin.playlistShadeHeight) : playlistSize.height
    }

    private var contentHeight: CGFloat {
        max(1, playlistSize.height - CGFloat(WinampSkin.playlistTitleBarHeight) - CGFloat(WinampSkin.playlistBottomHeight))
    }

    private var visibleTrackCount: Int {
        max(1, Int(contentHeight / CGFloat(WinampSkin.playlistTrackRowHeight)))
    }

    var body: some View {
        Group {
            if isPlaylistShade {
                playlistShadeView
            } else {
                ZStack(alignment: .topLeading) {
                    // Background color
                    Rectangle()
                        .fill(skin.playlistColors.normalBG)

                    // Frame: titlebar
                    playlistTitleBar

                    // Frame: left border
                    tiledLeftBorder

                    // Frame: right border with scrollbar track
                    tiledRightBorder

                    // Frame: bottom bar
                    playlistBottomBar

                    // Track list content area
                    trackListView
                        .padding(.leading, CGFloat(WinampSkin.playlistLeftWidth) * scale)
                        .padding(.trailing, CGFloat(WinampSkin.playlistRightWidth) * scale)
                        .padding(.top, CGFloat(WinampSkin.playlistTitleBarHeight) * scale)
                        .padding(.bottom, CGFloat(WinampSkin.playlistBottomHeight) * scale)

                    // Custom scrollbar handle
                    playlistScrollbar

                    // Scroll up/down buttons (bottom of scrollbar, within bottom-right corner)
                    scrollUpDownButtons

                    // Bottom-left menu buttons (SEL, REM functional; ADD, MISC, LIST decorative)
                    bottomLeftButtons

                    // Mini transport controls in bottom bar
                    miniTransportButtons

                    // Running time info (track time / playlist time) in bottom bar
                    runningTimeDisplay

                    // Time display in bottom bar
                    miniTimeDisplay

                    // Resize handle at bottom-right corner
                    PlaylistResizeHandle(
                        scale: scale,
                        playlistSize: $playlistSize,
                        isShade: false
                    )
                    .frame(width: 20 * scale, height: 20 * scale)
                    .padding(.leading, (playlistSize.width - 20) * scale)
                    .padding(.top, (playlistSize.height - 20) * scale)
                }
            }
        }
        .frame(width: playlistSize.width * scale, height: currentHeight * scale)
        .background(PlaylistWindowAccessor(
            scale: scale,
            playlistSize: $playlistSize,
            isWindowActive: $isWindowActive,
            isPlaylistShade: $isPlaylistShade
        ))
        .onAppear {
            roonAPI.isPlaylistVisible = true
            currentSeekPosition = playback.seekPosition
            Task { await roonAPI.fetchQueue() }
        }
        .onDisappear {
            roonAPI.isPlaylistVisible = false
        }
        .onReceive(playback.seekPositionPublisher) { newPosition in
            currentSeekPosition = newPosition
        }
    }

    // MARK: - Titlebar

    @ViewBuilder
    private var playlistTitleBar: some View {
        if let bitmap = skin.playlistBitmap {
            let skinId = "\(Unmanaged.passUnretained(bitmap).toOpaque())"
            let key = "\(skinId)-\(isWindowActive)-\(Int(playlistSize.width))"
            let titleImage: NSImage? = {
                if key == cachedTitleBarKey, let cached = cachedTitleBar { return cached }
                let img = composeTitleBar(bitmap: bitmap, isActive: isWindowActive, width: playlistSize.width)
                DispatchQueue.main.async { cachedTitleBarKey = key; cachedTitleBar = img }
                return img
            }()
            if let titleImage {
            ZStack(alignment: .topLeading) {
                Image(nsImage: titleImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: playlistSize.width * scale, height: CGFloat(WinampSkin.playlistTitleBarHeight) * scale)
                    .overlay(
                        DoubleClickOverlay {
                            isPlaylistShade = true
                        }
                    )

                // Shade button (left of close)
                Button {
                    isPlaylistShade = true
                } label: {
                    Color.white.opacity(0.001)
                        .frame(width: 9 * scale, height: 9 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, (playlistSize.width - 20) * scale)
                .padding(.top, 3 * scale)

                // Close button
                Button {
                    roonAPI.isPlaylistVisible = false
                    WinampWindow.playlist?.orderOut(nil)
                } label: {
                    Color.white.opacity(0.001)
                        .frame(width: 9 * scale, height: 9 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, (playlistSize.width - 11) * scale)
                .padding(.top, 3 * scale)
            }
            }
        }
    }

    // Shade view caches
    @State private var cachedShadeBar: NSImage?
    @State private var cachedShadeBarKey: String = ""
    @State private var cachedShadeTitle: NSImage?
    @State private var cachedShadeTitleKey: String = ""
    @State private var cachedShadeTime: NSImage?
    @State private var cachedShadeTimeKey: String = ""

    // Titlebar / bottom bar caches
    @State private var cachedTitleBar: NSImage?
    @State private var cachedTitleBarKey: String = ""
    @State private var cachedBottomBar: NSImage?
    @State private var cachedBottomBarKey: String = ""

    // Time display caches
    @State private var cachedRunningTime: NSImage?
    @State private var cachedRunningTimeKey: String = ""
    @State private var cachedMiniTime: NSImage?
    @State private var cachedMiniTimeKey: String = ""

    // MARK: - Playlist Shade View

    @ViewBuilder
    private var playlistShadeView: some View {
        if let bitmap = skin.playlistBitmap {
            let shadeH = CGFloat(WinampSkin.playlistShadeHeight)
            let totalW = playlistSize.width
            let skinId = "\(Unmanaged.passUnretained(bitmap).toOpaque())"
            let barKey = "\(skinId)-\(isWindowActive)-\(Int(totalW))"
            let shadeImage: NSImage? = {
                if barKey == cachedShadeBarKey, let cached = cachedShadeBar { return cached }
                let img = composeShadeBar(bitmap: bitmap, isActive: isWindowActive, width: totalW)
                DispatchQueue.main.async { cachedShadeBarKey = barKey; cachedShadeBar = img }
                return img
            }()
            if let shadeImage {
            ZStack(alignment: .topLeading) {
                // Background bar
                Image(nsImage: shadeImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: totalW * scale, height: shadeH * scale)
                    .onTapGesture(count: 2) {
                        isPlaylistShade = false
                    }

                // Track title text (left side)
                if let textBitmap = skin.textBitmap {
                    let textSkinId = "\(Unmanaged.passUnretained(textBitmap).toOpaque())"
                    let rightReserved: CGFloat = 30
                    let leftPad: CGFloat = 5
                    let timeCharW: CGFloat = 5
                    let timeText = shadeTimeText()
                    let timeWidth = CGFloat(timeText.count) * timeCharW
                    let availableW = totalW - leftPad - timeWidth - rightReserved

                    let titleText = shadeTitleText()
                    let maxChars = Int(availableW / 5)
                    let truncatedTitle = String(titleText.prefix(maxChars))

                    if !truncatedTitle.isEmpty {
                        let titleKey = "\(textSkinId)-\(truncatedTitle)"
                        let rendered: NSImage? = {
                            if titleKey == cachedShadeTitleKey, let cached = cachedShadeTitle { return cached }
                            let img = renderBitmapText(truncatedTitle, from: textBitmap)
                            DispatchQueue.main.async { cachedShadeTitleKey = titleKey; cachedShadeTitle = img }
                            return img
                        }()
                        if let rendered {
                            let renderW = CGFloat(truncatedTitle.count) * 5
                            Image(nsImage: rendered)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: renderW * scale, height: 6 * scale)
                                .padding(.leading, leftPad * scale)
                                .padding(.top, 4 * scale)
                                .allowsHitTesting(false)
                        }
                    }

                    // Time display (before right sprite area)
                    let timeKey = "\(textSkinId)-\(timeText)"
                    let timeRendered: NSImage? = {
                        if timeKey == cachedShadeTimeKey, let cached = cachedShadeTime { return cached }
                        let img = renderBitmapText(timeText, from: textBitmap)
                        DispatchQueue.main.async { cachedShadeTimeKey = timeKey; cachedShadeTime = img }
                        return img
                    }()
                    if let timeRendered {
                        Image(nsImage: timeRendered)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: timeWidth * scale, height: 6 * scale)
                            .padding(.leading, (totalW - rightReserved - timeWidth) * scale)
                            .padding(.top, 4 * scale)
                            .allowsHitTesting(false)
                    }
                }

                // Unshade button (9x9, same position as shade button in normal titlebar)
                Button {
                    isPlaylistShade = false
                } label: {
                    Color.white.opacity(0.001)
                        .frame(width: 9 * scale, height: 9 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, (totalW - 20) * scale)
                .padding(.top, 3 * scale)

                // Close button (9x9, rightmost in shade bar)
                Button {
                    roonAPI.isPlaylistVisible = false
                    WinampWindow.playlist?.orderOut(nil)
                } label: {
                    Color.white.opacity(0.001)
                        .frame(width: 9 * scale, height: 9 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, (totalW - 11) * scale)
                .padding(.top, 3 * scale)
            }
            }
        }
    }

    private func shadeTitleText() -> String {
        guard let zone = roonAPI.currentZone, let nowPlaying = zone.nowPlaying else {
            return ""
        }
        // Track number from queue position (history count + 1 = current track)
        let trackNum = roonAPI.queueHistory.count + 1
        let name = nowPlaying.artist.isEmpty
            ? nowPlaying.title
            : "\(nowPlaying.artist) - \(nowPlaying.title)"
        return "\(trackNum). \(name)"
    }

    private func shadeTimeText() -> String {
        let length = roonAPI.currentZone?.nowPlaying?.length ?? 0
        return formatDuration(length)
    }

    private func composeShadeBar(bitmap: NSImage, isActive: Bool, width: CGFloat) -> NSImage? {
        guard let cgBitmap = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let leftW = WinampSkin.plShadeLeft.width       // 25
        let tileW = WinampSkin.plShadeTile.width       // 25
        let rightW = WinampSkin.plShadeRightActive.width // 50
        let h = WinampSkin.playlistShadeHeight           // 14
        let totalWidth = Int(width)

        let resultImage = NSImage(size: NSSize(width: totalWidth, height: h))
        resultImage.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        ctx.interpolationQuality = .none

        // Draw left sprite
        let leftRegion = WinampSkin.plShadeLeft
        if let sprite = cgBitmap.cropping(to: CGRect(x: leftRegion.x, y: leftRegion.y, width: leftW, height: h)) {
            let nsImg = NSImage(cgImage: sprite, size: NSSize(width: leftW, height: h))
            nsImg.draw(in: NSRect(x: 0, y: 0, width: leftW, height: h))
        }

        // Tile the middle
        let tileRegion = WinampSkin.plShadeTile
        let middleEnd = totalWidth - rightW
        if let tile = cgBitmap.cropping(to: CGRect(x: tileRegion.x, y: tileRegion.y, width: tileW, height: h)) {
            let tileNS = NSImage(cgImage: tile, size: NSSize(width: tileW, height: h))
            var x = leftW
            while x < middleEnd {
                let drawW = min(tileW, middleEnd - x)
                tileNS.draw(in: NSRect(x: x, y: 0, width: drawW, height: h))
                x += tileW
            }
        }

        // Draw right sprite (active/inactive)
        let rightRegion = isActive ? WinampSkin.plShadeRightActive : WinampSkin.plShadeRightInactive
        if let sprite = cgBitmap.cropping(to: CGRect(x: rightRegion.x, y: rightRegion.y, width: rightW, height: h)) {
            let nsImg = NSImage(cgImage: sprite, size: NSSize(width: rightW, height: h))
            nsImg.draw(in: NSRect(x: totalWidth - rightW, y: 0, width: rightW, height: h))
        }

        resultImage.unlockFocus()
        return resultImage
    }

    // MARK: - Left Border

    @ViewBuilder
    private var tiledLeftBorder: some View {
        if let bitmap = skin.playlistBitmap,
           let tileImage = extractSprite(from: bitmap, region: WinampSkin.plLeftTile) {
            let tileH = CGFloat(WinampSkin.plLeftTile.height)
            let repeatCount = Int(ceil(contentHeight / tileH))
            VStack(spacing: 0) {
                ForEach(0..<repeatCount, id: \.self) { _ in
                    Image(nsImage: tileImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(WinampSkin.playlistLeftWidth) * scale, height: tileH * scale)
                }
            }
            .frame(width: CGFloat(WinampSkin.playlistLeftWidth) * scale, height: contentHeight * scale, alignment: .top)
            .clipped()
            .padding(.top, CGFloat(WinampSkin.playlistTitleBarHeight) * scale)
        }
    }

    // MARK: - Right Border

    @ViewBuilder
    private var tiledRightBorder: some View {
        if let bitmap = skin.playlistBitmap,
           let tileImage = extractSprite(from: bitmap, region: WinampSkin.plRightTile) {
            let tileH = CGFloat(WinampSkin.plRightTile.height)
            let repeatCount = Int(ceil(contentHeight / tileH))
            VStack(spacing: 0) {
                ForEach(0..<repeatCount, id: \.self) { _ in
                    Image(nsImage: tileImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(WinampSkin.playlistRightWidth) * scale, height: tileH * scale)
                }
            }
            .frame(width: CGFloat(WinampSkin.playlistRightWidth) * scale, height: contentHeight * scale, alignment: .top)
            .clipped()
            .padding(.leading, (playlistSize.width - CGFloat(WinampSkin.playlistRightWidth)) * scale)
            .padding(.top, CGFloat(WinampSkin.playlistTitleBarHeight) * scale)
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var playlistBottomBar: some View {
        if let bitmap = skin.playlistBitmap {
            let skinId = "\(Unmanaged.passUnretained(bitmap).toOpaque())"
            let key = "\(skinId)-\(Int(playlistSize.width))"
            let bottomImage: NSImage? = {
                if key == cachedBottomBarKey, let cached = cachedBottomBar { return cached }
                let img = composeBottomBar(bitmap: bitmap, width: playlistSize.width)
                DispatchQueue.main.async { cachedBottomBarKey = key; cachedBottomBar = img }
                return img
            }()
            if let bottomImage {
                Image(nsImage: bottomImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: playlistSize.width * scale, height: CGFloat(WinampSkin.playlistBottomHeight) * scale)
                    .padding(.top, (playlistSize.height - CGFloat(WinampSkin.playlistBottomHeight)) * scale)
            }
        }
    }

    // MARK: - Track List

    /// Combined list: history (played) + current queue
    private var allPlaylistItems: [(item: QueueItem, isHistory: Bool)] {
        let history = roonAPI.queueHistory.map { (item: $0, isHistory: true) }
        let current = roonAPI.queueItems.map { (item: $0, isHistory: false) }
        return history + current
    }

    @ViewBuilder
    private var trackListView: some View {
        PlaylistTableView(
            skin: skin,
            roonAPI: roonAPI,
            scale: scale,
            selectedItemId: $selectedItemId,
            scrollFraction: $scrollFractionState,
            scrollState: scrollState
        )
    }

    // MARK: - Custom Scrollbar

    private var scrollFraction: CGFloat { scrollFractionState }

    @ViewBuilder
    private var playlistScrollbar: some View {
        if let bitmap = skin.playlistBitmap {
            let handleNormal = extractSprite(from: bitmap, region: WinampSkin.plScrollHandleNormal)
            let handlePressed = extractSprite(from: bitmap, region: WinampSkin.plScrollHandlePressed)
            let trackHeight = contentHeight

            PlaylistScrollbarView(
                handleNormal: handleNormal,
                handlePressed: handlePressed,
                scrollFraction: scrollFraction,
                trackHeight: trackHeight,
                scale: scale,
                onScroll: { fraction in scrollState.scrollToFraction(fraction) }
            )
            .frame(width: 8 * scale, height: trackHeight * scale)
            .padding(.leading, (playlistSize.width - CGFloat(WinampSkin.playlistRightWidth) + 5) * scale)
            .padding(.top, CGFloat(WinampSkin.playlistTitleBarHeight) * scale)
        }
    }

    // MARK: - Scroll Up/Down Buttons

    @ViewBuilder
    private var scrollUpDownButtons: some View {
        VStack(spacing: 0) {
            // Scroll up
            Button { scrollState.scrollByRows(-3, scale: scale) } label: {
                Color.white.opacity(0.001)
                    .frame(width: 8 * scale, height: 5 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Scroll down
            Button { scrollState.scrollByRows(3, scale: scale) } label: {
                Color.white.opacity(0.001)
                    .frame(width: 8 * scale, height: 5 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, (playlistSize.width - 15) * scale)
        .padding(.top, (playlistSize.height - 36) * scale)
    }

    // MARK: - Bottom Left Buttons (ADD, REM, SEL, MISC)

    @ViewBuilder
    private var bottomLeftButtons: some View {
        let h = playlistSize.height
        // Buttons sit within the bottom-left corner sprite at relative y=9, each 25x18
        let btnY = (h - CGFloat(WinampSkin.playlistBottomHeight) + 9) * scale
        let btnW: CGFloat = 25 * scale
        let btnH: CGFloat = 18 * scale

        HStack(spacing: 0) {
            // ADD — decorative
            Color.white.opacity(0.001)
                .frame(width: btnW, height: btnH)
                .contentShape(Rectangle())

            // REM — clear play history
            Button {
                roonAPI.clearQueueHistory()
            } label: {
                Color.white.opacity(0.001)
                    .frame(width: btnW, height: btnH)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // SEL — scroll to currently playing track
            Button {
                scrollToNowPlaying()
            } label: {
                Color.white.opacity(0.001)
                    .frame(width: btnW, height: btnH)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // MISC — decorative
            Color.white.opacity(0.001)
                .frame(width: btnW, height: btnH)
                .contentShape(Rectangle())
        }
        .padding(.leading, 11 * scale)
        .padding(.top, btnY)
    }

    private func scrollToNowPlaying() {
        let items = allPlaylistItems
        // The currently playing track is the first item after history
        let index = roonAPI.queueHistory.count
        guard index < items.count else { return }

        // Scroll to that position as a fraction
        let totalItems = items.count
        let visibleItems = visibleTrackCount
        let scrollableItems = max(1, totalItems - visibleItems)
        // Center the now-playing item in the visible area
        let targetIndex = max(0, index - visibleItems / 2)
        let fraction = CGFloat(targetIndex) / CGFloat(scrollableItems)
        scrollState.scrollToFraction(min(1, max(0, fraction)))
    }

    // MARK: - Mini Transport Buttons

    @ViewBuilder
    private var miniTransportButtons: some View {
        let w = playlistSize.width
        let h = playlistSize.height
        let btnY = (h - 15) * scale
        let btnH: CGFloat = 7 * scale

        HStack(spacing: 0) {
            // Previous (7px)
            Button {
                guard let zoneId = roonAPI.currentZone?.id else { return }
                Task { await roonAPI.previous(zoneId: zoneId) }
            } label: {
                Color.white.opacity(0.001).frame(width: 7 * scale, height: btnH).contentShape(Rectangle())
            }.buttonStyle(.plain)

            // Play (10px) — acts as play/pause
            Button {
                guard let zoneId = roonAPI.currentZone?.id else { return }
                Task { await roonAPI.playPause(zoneId: zoneId) }
            } label: {
                Color.white.opacity(0.001).frame(width: 10 * scale, height: btnH).contentShape(Rectangle())
            }.buttonStyle(.plain)

            // Pause (10px) — acts as play/pause
            Button {
                guard let zoneId = roonAPI.currentZone?.id else { return }
                Task { await roonAPI.playPause(zoneId: zoneId) }
            } label: {
                Color.white.opacity(0.001).frame(width: 10 * scale, height: btnH).contentShape(Rectangle())
            }.buttonStyle(.plain)

            // Stop (9px)
            Button {
                guard let zoneId = roonAPI.currentZone?.id else { return }
                Task { await roonAPI.stop(zoneId: zoneId) }
            } label: {
                Color.white.opacity(0.001).frame(width: 9 * scale, height: btnH).contentShape(Rectangle())
            }.buttonStyle(.plain)

            // Next (9px)
            Button {
                guard let zoneId = roonAPI.currentZone?.id else { return }
                Task { await roonAPI.next(zoneId: zoneId) }
            } label: {
                Color.white.opacity(0.001).frame(width: 9 * scale, height: btnH).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.leading, (w - 144) * scale)
        .padding(.top, btnY)
    }

    // MARK: - Running Time Display

    @ViewBuilder
    private var runningTimeDisplay: some View {
        if let textBitmap = skin.textBitmap {
            let textSkinId = "\(Unmanaged.passUnretained(textBitmap).toOpaque())"
            let w = playlistSize.width
            let h = playlistSize.height

            let trackLength = roonAPI.currentZone?.nowPlaying?.length ?? 0
            let totalLength = roonAPI.queueItems.reduce(0) { $0 + ($1.length ?? 0) }

            let infoStr = formatDuration(trackLength) + "/" + formatDuration(totalLength)
            let padded = infoStr.padding(toLength: 18, withPad: " ", startingAt: 0)
            let charWidth: CGFloat = 5
            let textWidth = CGFloat(padded.count) * charWidth

            let runningTimeKey = "\(textSkinId)-\(padded)"
            let rendered: NSImage? = {
                if runningTimeKey == cachedRunningTimeKey, let cached = cachedRunningTime { return cached }
                let img = renderBitmapText(padded, from: textBitmap)
                DispatchQueue.main.async { cachedRunningTimeKey = runningTimeKey; cachedRunningTime = img }
                return img
            }()
            if let rendered {
                Image(nsImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: textWidth * scale, height: 6 * scale)
                    .padding(.leading, (w - 143) * scale)
                    .padding(.top, (h - 28) * scale)
            }
        }
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - Mini Time Display

    @ViewBuilder
    private var miniTimeDisplay: some View {
        if let textBitmap = skin.textBitmap {
            let textSkinId = "\(Unmanaged.passUnretained(textBitmap).toOpaque())"
            let w = playlistSize.width
            let h = playlistSize.height
            let seekPos = currentSeekPosition
            let timeText = formatCompactTime(seekPos)
            let charWidth: CGFloat = 5
            let textWidth = CGFloat(timeText.count) * charWidth

            let miniTimeKey = "\(textSkinId)-\(timeText)"
            let rendered: NSImage? = {
                if miniTimeKey == cachedMiniTimeKey, let cached = cachedMiniTime { return cached }
                let img = renderBitmapText(timeText, from: textBitmap)
                DispatchQueue.main.async { cachedMiniTimeKey = miniTimeKey; cachedMiniTime = img }
                return img
            }()
            if let rendered {
                Image(nsImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: textWidth * scale, height: 6 * scale)
                    .padding(.leading, (w - 83) * scale)
                    .padding(.top, (h - 15) * scale)
            }
        }
    }

    private func formatCompactTime(_ seconds: Int) -> String {
        let timeToShow: Int
        let prefix: String
        if showRemaining,
           let length = playback.nowPlaying?.length {
            timeToShow = max(0, length - seconds)
            prefix = "-"
        } else {
            timeToShow = seconds
            prefix = " "  // transparent space keeps digits at fixed position
        }
        let m = timeToShow / 60
        let s = timeToShow % 60
        // Space between MM and SS — colon is baked into the background sprite
        return String(format: "%@%02d %02d", prefix, m, s)
    }

    private func renderBitmapText(_ text: String, from bitmap: NSImage) -> NSImage? {
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6
        let totalWidth = CGFloat(text.count) * charWidth

        let result = NSImage(size: NSSize(width: totalWidth, height: charHeight))
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        // text.bmp character map (same as WinampInfoDisplay)
        let row0 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@  ")
        let row1 = Array("0123456789 .:()-'!_+\\/[]^~{}")
        let row2 = Array("ÅÖÄ                           ")

        var xOffset: CGFloat = 0
        for char in text.uppercased() {
            if char != " " {
                let charMaps = [row0, row1, row2]
                for (rowIndex, charMap) in charMaps.enumerated() {
                    if let index = charMap.firstIndex(of: char) {
                        let col = charMap.distance(from: charMap.startIndex, to: index)
                        let sourceRect = CGRect(x: CGFloat(col) * charWidth, y: CGFloat(rowIndex) * charHeight, width: charWidth, height: charHeight)
                        if let cropped = cgImage.cropping(to: sourceRect) {
                            let charImg = NSImage(cgImage: cropped, size: NSSize(width: charWidth, height: charHeight))
                            charImg.draw(at: NSPoint(x: xOffset, y: 0), from: .zero, operation: .copy, fraction: 1.0)
                        }
                        break
                    }
                }
            }
            // Space: leave transparent so background colon shows through
            xOffset += charWidth
        }

        result.unlockFocus()
        return result
    }

    // MARK: - Sprite Composition Helpers

    private func composeTitleBar(bitmap: NSImage, isActive: Bool, width: CGFloat) -> NSImage? {
        guard let cgBitmap = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let yOffset = isActive ? 0 : 21
        let leftW = WinampSkin.plTitleBarLeftCorner.width   // 25
        let titleW = WinampSkin.plTitleBarTitle.width        // 100
        let tileW = WinampSkin.plTitleBarTile.width          // 25
        let rightW = WinampSkin.plTitleBarRightCorner.width  // 25
        let h = WinampSkin.playlistTitleBarHeight             // 20
        let totalWidth = Int(width)

        let resultImage = NSImage(size: NSSize(width: totalWidth, height: h))
        resultImage.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        ctx.interpolationQuality = .none

        // Draw left corner
        if let sprite = cgBitmap.cropping(to: CGRect(x: 0, y: yOffset, width: leftW, height: h)) {
            let nsImg = NSImage(cgImage: sprite, size: NSSize(width: leftW, height: h))
            nsImg.draw(in: NSRect(x: 0, y: 0, width: leftW, height: h))
        }

        // Draw right corner
        if let sprite = cgBitmap.cropping(to: CGRect(x: 153, y: yOffset, width: rightW, height: h)) {
            let nsImg = NSImage(cgImage: sprite, size: NSSize(width: rightW, height: h))
            nsImg.draw(in: NSRect(x: totalWidth - rightW, y: 0, width: rightW, height: h))
        }

        // Center the title text in the space between left and right corners
        let middleSpace = totalWidth - leftW - rightW
        let titleX = leftW + (middleSpace - titleW) / 2

        // Tile between left corner and title, then between title and right corner
        if let tile = cgBitmap.cropping(to: CGRect(x: 127, y: yOffset, width: tileW, height: h)) {
            let tileNS = NSImage(cgImage: tile, size: NSSize(width: tileW, height: h))

            // Left tiles: from left corner end to title start
            var x = leftW
            while x < titleX {
                let drawW = min(tileW, titleX - x)
                tileNS.draw(in: NSRect(x: x, y: 0, width: drawW, height: h))
                x += tileW
            }

            // Right tiles: from title end to right corner start
            let rightTileEnd = totalWidth - rightW
            x = titleX + titleW
            while x < rightTileEnd {
                let drawW = min(tileW, rightTileEnd - x)
                tileNS.draw(in: NSRect(x: x, y: 0, width: drawW, height: h))
                x += tileW
            }
        }

        // Draw title (centered)
        if let sprite = cgBitmap.cropping(to: CGRect(x: 26, y: yOffset, width: titleW, height: h)) {
            let nsImg = NSImage(cgImage: sprite, size: NSSize(width: titleW, height: h))
            nsImg.draw(in: NSRect(x: titleX, y: 0, width: titleW, height: h))
        }

        resultImage.unlockFocus()
        return resultImage
    }

    private func composeBottomBar(bitmap: NSImage, width: CGFloat) -> NSImage? {
        guard let cgBitmap = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let leftW = WinampSkin.plBottomLeft.width    // 125
        let rightW = WinampSkin.plBottomRight.width  // 150
        let tileW = WinampSkin.plBottomTile.width    // 25
        let h = WinampSkin.playlistBottomHeight       // 38
        let totalWidth = Int(width)

        let resultImage = NSImage(size: NSSize(width: totalWidth, height: h))
        resultImage.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        ctx.interpolationQuality = .none

        // Draw left corner
        if let sprite = cgBitmap.cropping(to: CGRect(x: 0, y: 72, width: leftW, height: h)) {
            let nsImg = NSImage(cgImage: sprite, size: NSSize(width: leftW, height: h))
            nsImg.draw(in: NSRect(x: 0, y: 0, width: leftW, height: h))
        }

        // Tile the middle
        let middleStart = leftW
        let middleEnd = totalWidth - rightW
        if middleEnd > middleStart, let tile = cgBitmap.cropping(to: CGRect(x: 179, y: 0, width: tileW, height: h)) {
            let tileNS = NSImage(cgImage: tile, size: NSSize(width: tileW, height: h))
            var x = middleStart
            while x < middleEnd {
                let drawW = min(tileW, middleEnd - x)
                tileNS.draw(in: NSRect(x: x, y: 0, width: drawW, height: h))
                x += tileW
            }
        }

        // Draw right corner
        if let sprite = cgBitmap.cropping(to: CGRect(x: 126, y: 72, width: rightW, height: h)) {
            let nsImg = NSImage(cgImage: sprite, size: NSSize(width: rightW, height: h))
            nsImg.draw(in: NSRect(x: totalWidth - rightW, y: 0, width: rightW, height: h))
        }

        resultImage.unlockFocus()
        return resultImage
    }

    private func extractSprite(from bitmap: NSImage, region: WinampSkin.ButtonRegion) -> NSImage? {
        guard let cgBitmap = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        guard let cropped = cgBitmap.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: region.width, height: region.height))
    }
}

// MARK: - Double-Click Overlay

/// NSView overlay that captures double-clicks at the AppKit level,
/// preventing isMovableByWindowBackground from consuming them for system zoom/minimize.
struct DoubleClickOverlay: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickNSView {
        let view = DoubleClickNSView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DoubleClickNSView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

class DoubleClickNSView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    // Allow window dragging on single click by forwarding to window
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - AppKit Scrollbar View

/// NSView-based scrollbar that captures mouse events before isMovableByWindowBackground
struct PlaylistScrollbarView: NSViewRepresentable {
    let handleNormal: NSImage?
    let handlePressed: NSImage?
    let scrollFraction: CGFloat
    let trackHeight: CGFloat
    let scale: CGFloat
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollbarNSView {
        let view = ScrollbarNSView()
        view.handleNormal = handleNormal
        view.handlePressed = handlePressed
        view.scale = scale
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollbarNSView, context: Context) {
        nsView.handleNormal = handleNormal
        nsView.handlePressed = handlePressed
        nsView.scrollFraction = scrollFraction
        nsView.trackHeight = trackHeight
        nsView.scale = scale
        nsView.onScroll = onScroll
        nsView.needsDisplay = true
    }
}

class ScrollbarNSView: NSView {
    var handleNormal: NSImage?
    var handlePressed: NSImage?
    var scrollFraction: CGFloat = 0
    var trackHeight: CGFloat = 0
    var scale: CGFloat = 2
    var onScroll: ((CGFloat) -> Void)?
    private var isDragging = false
    private var dragFraction: CGFloat? = nil  // local fraction during drag for immediate feedback

    private let handleH: CGFloat = 18

    private var handleTrackRange: CGFloat {
        max(1, trackHeight - handleH)
    }

    private var effectiveFraction: CGFloat {
        dragFraction ?? scrollFraction
    }

    /// Handle rect in flipped coordinates (top-left origin)
    private var handleRect: NSRect {
        let handleY = effectiveFraction * handleTrackRange * scale
        return NSRect(x: 0, y: handleY, width: 8 * scale, height: handleH * scale)
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let img = isDragging ? (handlePressed ?? handleNormal) : handleNormal
        img?.draw(in: handleRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        let frac = fractionFromEvent(event)
        dragFraction = frac
        needsDisplay = true
        onScroll?(frac)
    }

    override func mouseDragged(with event: NSEvent) {
        let frac = fractionFromEvent(event)
        dragFraction = frac
        needsDisplay = true
        onScroll?(frac)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        dragFraction = nil
        needsDisplay = true
    }

    private func fractionFromEvent(_ event: NSEvent) -> CGFloat {
        let localPoint = convert(event.locationInWindow, from: nil)
        let yInTrack = localPoint.y / scale
        let fraction = (yInTrack - handleH / 2) / handleTrackRange
        return max(0, min(1, fraction))
    }
}

// MARK: - Playlist Resize Handle

struct PlaylistResizeHandle: NSViewRepresentable {
    let scale: CGFloat
    @Binding var playlistSize: CGSize
    let isShade: Bool

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        view.scale = scale
        view.isShade = isShade
        view.onResize = { deltaW, deltaH in
            let minW = CGFloat(WinampSkin.playlistMinWidth)
            let incX = CGFloat(WinampSkin.playlistResizeIncrementX)
            let incY = CGFloat(WinampSkin.playlistResizeIncrementY)
            let minH = CGFloat(WinampSkin.playlistMinHeight)

            let rawW = playlistSize.width + deltaW
            let rawH = playlistSize.height + deltaH
            let newW = max(minW, minW + round((rawW - minW) / incX) * incX)
            let newH = isShade ? playlistSize.height : max(minH, minH + round((rawH - minH) / incY) * incY)

            if newW != playlistSize.width || newH != playlistSize.height {
                playlistSize = CGSize(width: newW, height: newH)
                PlaylistWindowAccessor.saveLogicalSize(playlistSize)
            }
        }
        return view
    }

    func updateNSView(_ nsView: ResizeHandleNSView, context: Context) {
        nsView.scale = scale
        nsView.isShade = isShade
    }
}

class ResizeHandleNSView: NSView {
    var scale: CGFloat = 2
    var isShade: Bool = false
    var onResize: ((CGFloat, CGFloat) -> Void)?
    private var dragStart: NSPoint?
    private var initialSize: NSSize?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        initialSize = window?.frame.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let initialSize = initialSize else { return }
        let current = event.locationInWindow
        let deltaX = (current.x - start.x) / scale
        let deltaY = (start.y - current.y) / scale  // inverted: drag down = increase height
        onResize?(deltaX, deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        initialSize = nil
        // Update snap offset after resize
        if WinampWindow.isSnapped, let window = window, let mainWindow = WinampWindow.current {
            let mainFrame = mainWindow.frame
            let plFrame = window.frame
            WinampWindow.snapOffset = NSPoint(
                x: plFrame.origin.x - mainFrame.origin.x,
                y: plFrame.origin.y - mainFrame.origin.y
            )
        }
        if let window = window {
            PlaylistWindowAccessor.saveWindowFrame(window)
        }
    }
}

// MARK: - Shared Scroll State

/// Holds a reference to the NSScrollView for direct programmatic scrolling
class PlaylistScrollState: NSObject, ObservableObject {
    weak var scrollView: NSScrollView?

    func scrollToFraction(_ fraction: CGFloat) {
        guard let scrollView = scrollView,
              let docView = scrollView.documentView else { return }
        let contentH = docView.frame.height
        let visibleH = scrollView.contentView.bounds.height
        let scrollableH = contentH - visibleH
        guard scrollableH > 0 else { return }
        let y = max(0, min(scrollableH, fraction * scrollableH))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollByRows(_ rows: Int, scale: CGFloat) {
        guard let scrollView = scrollView,
              let docView = scrollView.documentView else { return }
        let rowHeight = CGFloat(WinampSkin.playlistTrackRowHeight) * scale
        let contentH = docView.frame.height
        let visibleH = scrollView.contentView.bounds.height
        let scrollableH = contentH - visibleH
        guard scrollableH > 0 else { return }
        let currentY = scrollView.contentView.bounds.origin.y
        let newY = max(0, min(scrollableH, currentY + CGFloat(rows) * rowHeight))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: newY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - NSTableView-based Playlist Track List

struct PlaylistTableView: NSViewRepresentable {
    let skin: WinampSkin
    let roonAPI: RoonAPI
    let scale: CGFloat
    @Binding var selectedItemId: Int?
    @Binding var scrollFraction: CGFloat
    let scrollState: PlaylistScrollState

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(skin.playlistColors.normalBG)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.rowHeight = CGFloat(WinampSkin.playlistTrackRowHeight) * scale
        tableView.backgroundColor = NSColor(skin.playlistColors.normalBG)
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        column.isEditable = false
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClickRow(_:))

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        // Store scroll view reference for programmatic scrolling
        scrollState.scrollView = scrollView

        // Observe scroll position for fraction updates
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(clipView: clipView, scrollView: scrollView)

        // Subscribe to data changes
        context.coordinator.subscribeToChanges()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let oldSkin = coordinator.parent.skin
        let oldScale = coordinator.parent.scale
        coordinator.parent = self

        // Update colors
        scrollView.backgroundColor = NSColor(skin.playlistColors.normalBG)

        if let tableView = coordinator.tableView {
            let newRowHeight = CGFloat(WinampSkin.playlistTrackRowHeight) * scale
            let skinChanged = skin.playlistColors != oldSkin.playlistColors
            let scaleChanged = scale != oldScale

            if scaleChanged {
                tableView.rowHeight = newRowHeight
            }
            if skinChanged || scaleChanged {
                tableView.backgroundColor = NSColor(skin.playlistColors.normalBG)
                tableView.reloadData()
            }

            // Ensure column fills width
            if let column = tableView.tableColumns.first {
                column.width = scrollView.contentView.bounds.width
            }
        }
    }

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: PlaylistTableView
        weak var tableView: NSTableView?
        var items: [(item: QueueItem, isHistory: Bool)] = []
        private var cancellables = Set<AnyCancellable>()
        private var scrollObservation: Any?
        private var currentTrackId: Int?

        init(parent: PlaylistTableView) {
            self.parent = parent
            super.init()
        }

        func subscribeToChanges() {
            let roonAPI = parent.roonAPI

            // Observe queue changes
            roonAPI.$queueItems
                .combineLatest(roonAPI.$queueHistory)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] queueItems, queueHistory in
                    guard let self = self else { return }
                    let history = queueHistory.map { (item: $0, isHistory: true) }
                    let current = queueItems.map { (item: $0, isHistory: false) }
                    self.items = history + current
                    self.currentTrackId = queueItems.first?.id
                    self.tableView?.reloadData()
                }
                .store(in: &cancellables)
        }

        func observeScroll(clipView: NSClipView, scrollView: NSScrollView) {
            scrollObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                guard let docView = scrollView.documentView else { return }
                let contentH = docView.frame.height
                let visibleH = clipView.bounds.height
                let scrollableH = contentH - visibleH
                guard scrollableH > 0 else {
                    self?.parent.scrollFraction = 0
                    return
                }
                self?.parent.scrollFraction = min(1, max(0, clipView.bounds.origin.y / scrollableH))
            }
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < items.count else { return nil }
            let entry = items[row]
            let item = entry.item
            let scale = parent.scale

            let isCurrent = !entry.isHistory && item.id == currentTrackId
            let isSelected = item.id == parent.selectedItemId

            let textColor: NSColor = {
                if isCurrent { return NSColor(parent.skin.playlistColors.current) }
                if entry.isHistory { return NSColor(parent.skin.playlistColors.normal).withAlphaComponent(0.45) }
                return NSColor(parent.skin.playlistColors.normal)
            }()
            let bgColor = isSelected
                ? NSColor(parent.skin.playlistColors.selectedBG)
                : NSColor(parent.skin.playlistColors.normalBG)

            let font = NSFont(name: parent.skin.playlistColors.font, size: 8 * scale)
                ?? NSFont.systemFont(ofSize: 8 * scale)

            let indexText = "\(row + 1). "
            let titleText = item.artist.isEmpty ? item.title : "\(item.artist) - \(item.title)"
            let durationText = item.durationString

            // Reuse or create cell view
            let cellId = NSUserInterfaceItemIdentifier("PlaylistCell")
            let cell: PlaylistCellView
            if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? PlaylistCellView {
                cell = reused
            } else {
                cell = PlaylistCellView()
                cell.identifier = cellId
            }

            cell.configure(
                index: indexText,
                title: titleText,
                duration: durationText,
                font: font,
                textColor: textColor,
                bgColor: bgColor,
                horizontalPadding: 2 * scale
            )

            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = tableView else { return }
            let row = tableView.selectedRow
            if row >= 0, row < items.count {
                parent.selectedItemId = items[row].item.id
            }
        }

        @objc func doubleClickRow(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < items.count else { return }
            let item = items[row].item
            guard let zoneId = parent.roonAPI.currentZone?.id else { return }
            Task { @MainActor in
                await parent.roonAPI.playFromHere(zoneId: zoneId, queueItemId: item.id)
            }
        }

        deinit {
            if let obs = scrollObservation {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }
}

// MARK: - Playlist Cell View

private class PlaylistCellView: NSView {
    private let indexField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let durationField = NSTextField(labelWithString: "")
    private var bgColor: NSColor = .clear
    private var horizontalPadding: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupFields()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFields()
    }

    private func setupFields() {
        for field in [indexField, titleField, durationField] {
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byClipping
            field.cell?.truncatesLastVisibleLine = true
            addSubview(field)
        }
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        durationField.setContentHuggingPriority(.required, for: .horizontal)
        indexField.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configure(
        index: String,
        title: String,
        duration: String,
        font: NSFont,
        textColor: NSColor,
        bgColor: NSColor,
        horizontalPadding: CGFloat
    ) {
        self.bgColor = bgColor
        self.horizontalPadding = horizontalPadding

        indexField.stringValue = index
        indexField.font = font
        indexField.textColor = textColor

        titleField.stringValue = title
        titleField.font = font
        titleField.textColor = textColor

        durationField.stringValue = duration
        durationField.font = font
        durationField.textColor = textColor

        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let pad = horizontalPadding

        let indexSize = indexField.sizeThatFits(NSSize(width: 200, height: h))
        let durationSize = durationField.sizeThatFits(NSSize(width: 200, height: h))

        indexField.frame = NSRect(x: pad, y: 0, width: indexSize.width, height: h)
        durationField.frame = NSRect(
            x: bounds.width - durationSize.width - pad,
            y: 0,
            width: durationSize.width,
            height: h
        )
        titleField.frame = NSRect(
            x: pad + indexSize.width,
            y: 0,
            width: max(0, bounds.width - indexSize.width - durationSize.width - pad * 2),
            height: h
        )
    }
}

// MARK: - Playlist Host View

class PlaylistHostView: NSView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let newWindow = newWindow else { return }
        // Hide window before first render to prevent flash at wrong position
        newWindow.alphaValue = 0
        // Pre-position if snapped
        if WinampWindow.isSnapped, let mainWindow = WinampWindow.current {
            let mainFrame = mainWindow.frame
            let isBelow = WinampWindow.snapOffset.y < 0
            let size = newWindow.frame.size
            let y: CGFloat = isBelow ? mainFrame.minY - size.height : mainFrame.maxY
            newWindow.setFrameOrigin(NSPoint(x: mainFrame.minX, y: y))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        // Reposition to snap location
        if WinampWindow.isSnapped, let mainWindow = WinampWindow.current {
            let mainFrame = mainWindow.frame
            let isBelow = WinampWindow.snapOffset.y < 0
            let size = window.frame.size
            let y: CGFloat = isBelow ? mainFrame.minY - size.height : mainFrame.maxY
            window.setFrameOrigin(NSPoint(x: mainFrame.minX, y: y))
        }
        // Reveal after positioning
        DispatchQueue.main.async {
            window.alphaValue = 1
        }
    }
}

// MARK: - Playlist Window Accessor

struct PlaylistWindowAccessor: NSViewRepresentable {
    let scale: CGFloat
    @Binding var playlistSize: CGSize
    @Binding var isWindowActive: Bool
    @Binding var isPlaylistShade: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PlaylistHostView {
        let view = PlaylistHostView()
        DispatchQueue.main.async {
            if let window = view.window {
                WinampWindow.playlist = window
                configureWindow(window)
                window.delegate = context.coordinator
                context.coordinator.window = window

                // Track active state
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { _ in isWindowActive = true }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { _ in isWindowActive = false }

                // Track movement for snapping + save position
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    guard !WinampWindow.isMovingProgrammatically else { return }
                    Self.saveWindowFrame(window)
                }

                // Always-on-top
                NotificationCenter.default.addObserver(
                    forName: .alwaysOnTopChanged,
                    object: nil,
                    queue: .main
                ) { notification in
                    if let alwaysOnTop = notification.object as? Bool {
                        window.level = alwaysOnTop ? .floating : .normal
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: PlaylistHostView, context: Context) {
        if let window = nsView.window {
            DispatchQueue.main.async {
                // Don't fight with live resize
                guard !context.coordinator.isResizing else { return }
                let height: CGFloat = isPlaylistShade
                    ? CGFloat(WinampSkin.playlistShadeHeight)
                    : playlistSize.height
                let size = NSSize(width: playlistSize.width * scale, height: height * scale)
                if window.frame.size != size {
                    if !WinampWindow.isSnapped {
                        // Not snapped: preserve top edge
                        let oldFrame = window.frame
                        let newOriginY = oldFrame.maxY - size.height
                        let newFrame = NSRect(x: oldFrame.minX, y: newOriginY, width: size.width, height: size.height)
                        window.setFrame(newFrame, display: true, animate: false)
                    }
                }
                // Always verify snap state when snapped (SwiftUI may have
                // already resized the window, or playlist was closed/reopened)
                if WinampWindow.isSnapped, let mainWindow = WinampWindow.current {
                    // Ensure child window relationship exists (only if window is visible)
                    if window.isVisible,
                       !(mainWindow.childWindows?.contains(window) ?? false) {
                        mainWindow.addChildWindow(window, ordered: .below)
                    }
                    let mainFrame = mainWindow.frame
                    let isBelow = WinampWindow.snapOffset.y < 0
                    let expectedY: CGFloat = isBelow
                        ? mainFrame.minY - size.height
                        : mainFrame.maxY
                    let expectedOrigin = NSPoint(x: mainFrame.minX, y: expectedY)
                    let currentFrame = window.frame
                    if abs(currentFrame.origin.x - expectedOrigin.x) > 0.5 ||
                       abs(currentFrame.origin.y - expectedOrigin.y) > 0.5 ||
                       currentFrame.size != size {
                        let newFrame = NSRect(origin: expectedOrigin, size: size)
                        WinampWindow.isMovingProgrammatically = true
                        window.setFrame(newFrame, display: true, animate: false)
                        WinampWindow.isMovingProgrammatically = false
                        WinampWindow.snapOffset = NSPoint(
                            x: expectedOrigin.x - mainFrame.origin.x,
                            y: expectedOrigin.y - mainFrame.origin.y
                        )
                    }
                }
                if isPlaylistShade {
                    window.minSize = NSSize(width: CGFloat(WinampSkin.playlistMinWidth) * scale, height: CGFloat(WinampSkin.playlistShadeHeight) * scale)
                } else {
                    window.minSize = NSSize(width: CGFloat(WinampSkin.playlistMinWidth) * scale, height: CGFloat(WinampSkin.playlistMinHeight) * scale)
                }
            }
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.styleMask = [.borderless, .resizable]
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = NSColor(white: 0, alpha: 0.005)
        window.hasShadow = false
        window.minSize = NSSize(width: CGFloat(WinampSkin.playlistMinWidth) * scale, height: CGFloat(WinampSkin.playlistMinHeight) * scale)

        let alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        window.level = alwaysOnTop ? .floating : .normal

        // Restore saved frame, or snap to main window bottom as default
        if let savedFrame = Self.loadWindowFrame(scale: scale) {
            // Restore logical size first (always the full non-shade size)
            let logicalSize = Self.loadLogicalSize() ?? CGSize(
                width: savedFrame.width / scale,
                height: max(CGFloat(WinampSkin.playlistMinHeight), savedFrame.height / scale)
            )
            DispatchQueue.main.async {
                self.playlistSize = logicalSize
            }
            // Set the window frame — use logical size for height (not saved frame which may be shade height)
            let height = self.isPlaylistShade
                ? CGFloat(WinampSkin.playlistShadeHeight) * scale
                : logicalSize.height * scale
            let plSize = NSSize(width: logicalSize.width * scale, height: height)

            // If already snapped, position relative to current main window
            if WinampWindow.isSnapped, let mainWindow = WinampWindow.current {
                let mainFrame = mainWindow.frame
                let isBelow = WinampWindow.snapOffset.y < 0
                let originY: CGFloat = isBelow
                    ? mainFrame.minY - plSize.height
                    : mainFrame.maxY
                let snappedFrame = NSRect(x: mainFrame.minX, y: originY, width: plSize.width, height: plSize.height)
                window.setFrame(snappedFrame, display: true)
                WinampWindow.snapOffset = NSPoint(
                    x: snappedFrame.origin.x - mainFrame.origin.x,
                    y: snappedFrame.origin.y - mainFrame.origin.y
                )
            } else {
                let restoredFrame = NSRect(
                    x: savedFrame.minX,
                    y: savedFrame.maxY - height,
                    width: plSize.width,
                    height: plSize.height
                )
                window.setFrame(restoredFrame, display: true)
                // Check if restored position is snapped to main
                checkSnapToMain(window)
            }
        } else if let mainWindow = WinampWindow.current {
            let mainFrame = mainWindow.frame
            let plWidth = playlistSize.width * scale
            let plHeight = playlistSize.height * scale
            let newOrigin = NSPoint(x: mainFrame.minX, y: mainFrame.minY - plHeight)
            window.setFrame(NSRect(x: newOrigin.x, y: newOrigin.y, width: plWidth, height: plHeight), display: true)
            WinampWindow.isSnapped = true
            WinampWindow.snapOffset = NSPoint(x: 0, y: -plHeight)
        }
        // Reveal window after positioning (hidden by PlaylistHostView.viewWillMove)
        window.alphaValue = 1
    }

    static func saveWindowFrame(_ window: NSWindow) {
        let frame = window.frame
        UserDefaults.standard.set(frame.origin.x, forKey: "playlistWindowX")
        UserDefaults.standard.set(frame.origin.y, forKey: "playlistWindowY")
        UserDefaults.standard.set(frame.width, forKey: "playlistWindowW")
        UserDefaults.standard.set(frame.height, forKey: "playlistWindowH")
    }

    static func saveLogicalSize(_ size: CGSize) {
        UserDefaults.standard.set(Double(size.width), forKey: "playlistLogicalW")
        UserDefaults.standard.set(Double(size.height), forKey: "playlistLogicalH")
    }

    static func loadLogicalSize() -> CGSize? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "playlistLogicalW") != nil else { return nil }
        let w = defaults.double(forKey: "playlistLogicalW")
        let h = defaults.double(forKey: "playlistLogicalH")
        guard w >= Double(WinampSkin.playlistMinWidth),
              h >= Double(WinampSkin.playlistMinHeight) else { return nil }
        return CGSize(width: w, height: h)
    }

    static func loadWindowFrame(scale: CGFloat) -> NSRect? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "playlistWindowX") != nil else { return nil }
        let x = defaults.double(forKey: "playlistWindowX")
        let y = defaults.double(forKey: "playlistWindowY")
        let w = defaults.double(forKey: "playlistWindowW")
        let h = defaults.double(forKey: "playlistWindowH")
        guard w > 0, h > 0 else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func checkSnapToMain(_ window: NSWindow) {
        guard let mainWindow = WinampWindow.current else { return }
        let mainFrame = mainWindow.frame
        let plFrame = window.frame
        let snapDistance: CGFloat = 25
        let leftAligned = abs(plFrame.minX - mainFrame.minX) < snapDistance

        let topNearBottom = abs(plFrame.maxY - mainFrame.minY) < snapDistance
        let bottomNearTop = abs(plFrame.minY - mainFrame.maxY) < snapDistance

        if topNearBottom && leftAligned {
            let snappedOrigin = NSPoint(x: mainFrame.minX, y: mainFrame.minY - plFrame.height)
            WinampWindow.isMovingProgrammatically = true
            window.setFrameOrigin(snappedOrigin)
            WinampWindow.isMovingProgrammatically = false
            WinampWindow.isSnapped = true
            WinampWindow.snapOffset = NSPoint(x: snappedOrigin.x - mainFrame.origin.x, y: snappedOrigin.y - mainFrame.origin.y)
        } else if bottomNearTop && leftAligned {
            let snappedOrigin = NSPoint(x: mainFrame.minX, y: mainFrame.maxY)
            WinampWindow.isMovingProgrammatically = true
            window.setFrameOrigin(snappedOrigin)
            WinampWindow.isMovingProgrammatically = false
            WinampWindow.isSnapped = true
            WinampWindow.snapOffset = NSPoint(x: snappedOrigin.x - mainFrame.origin.x, y: snappedOrigin.y - mainFrame.origin.y)
        }
    }

    class Coordinator: NSObject, NSWindowDelegate {
        var parent: PlaylistWindowAccessor
        weak var window: NSWindow?
        private var mouseUpMonitor: Any?
        private var dragMonitor: Any?
        private var wasSnappedAtDragStart: Bool = false
        private var hasLeftSnapZone: Bool = false
        var isResizing: Bool = false

        init(parent: PlaylistWindowAccessor) {
            self.parent = parent
        }

        func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
            false  // Prevent system double-click zoom so SwiftUI gesture fires
        }

        func windowWillMove(_ notification: Notification) {
            WinampWindow.isPlaylistDragging = true
            wasSnappedAtDragStart = WinampWindow.isSnapped
            hasLeftSnapZone = false
            WinampWindow.isSnapped = false
            // Monitor mouse movement for magnetic snap during drag
            if dragMonitor == nil {
                dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                    self?.checkSnapDuringDrag()
                    return event
                }
            }
            if mouseUpMonitor == nil {
                mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                    self?.handleMouseUp()
                    return event
                }
            }
        }

        private func isNearSnap(mainFrame: NSRect, plFrame: NSRect) -> Bool {
            let snapDistance: CGFloat = 25
            let leftAligned = abs(plFrame.minX - mainFrame.minX) < snapDistance
            let topNearBottom = abs(plFrame.maxY - mainFrame.minY) < snapDistance
            let bottomNearTop = abs(plFrame.minY - mainFrame.maxY) < snapDistance
            return leftAligned && (topNearBottom || bottomNearTop)
        }

        private func checkSnapDuringDrag() {
            guard !WinampWindow.isSnapped,
                  let window = window,
                  let mainWindow = WinampWindow.current else { return }
            let mainFrame = mainWindow.frame
            let plFrame = window.frame

            let nearSnap = isNearSnap(mainFrame: mainFrame, plFrame: plFrame)

            // If we started from a snapped position, don't re-snap until
            // we've first left the snap zone (prevents immediate re-snap on detach)
            if wasSnappedAtDragStart && !hasLeftSnapZone {
                if !nearSnap {
                    hasLeftSnapZone = true
                }
                return
            }

            let snapDistance: CGFloat = 25
            let leftAligned = abs(plFrame.minX - mainFrame.minX) < snapDistance
            let topNearBottom = abs(plFrame.maxY - mainFrame.minY) < snapDistance
            let bottomNearTop = abs(plFrame.minY - mainFrame.maxY) < snapDistance

            if let snappedOrigin = snapOrigin(
                mainFrame: mainFrame, plFrame: plFrame,
                topNearBottom: topNearBottom, bottomNearTop: bottomNearTop,
                leftAligned: leftAligned
            ) {
                // During playlist drag, continuously override position (magnetic effect)
                // but don't set isSnapped — that happens on mouseUp
                WinampWindow.isMovingProgrammatically = true
                window.setFrameOrigin(snappedOrigin)
                WinampWindow.isMovingProgrammatically = false
            }
        }

        private func handleMouseUp() {
            WinampWindow.isPlaylistDragging = false
            wasSnappedAtDragStart = false
            hasLeftSnapZone = false
            cleanupMonitors()
            // Final snap check on release — this is where we commit the snap
            guard !WinampWindow.isSnapped,
                  let window = window,
                  let mainWindow = WinampWindow.current else { return }
            let mainFrame = mainWindow.frame
            let plFrame = window.frame
            let snapDistance: CGFloat = 25
            let leftAligned = abs(plFrame.minX - mainFrame.minX) < snapDistance

            let topNearBottom = abs(plFrame.maxY - mainFrame.minY) < snapDistance
            let bottomNearTop = abs(plFrame.minY - mainFrame.maxY) < snapDistance

            if let snappedOrigin = snapOrigin(
                mainFrame: mainFrame, plFrame: plFrame,
                topNearBottom: topNearBottom, bottomNearTop: bottomNearTop,
                leftAligned: leftAligned
            ) {
                WinampWindow.isMovingProgrammatically = true
                window.setFrameOrigin(snappedOrigin)
                WinampWindow.isMovingProgrammatically = false
                WinampWindow.isSnapped = true
                WinampWindow.snapOffset = NSPoint(
                    x: snappedOrigin.x - mainFrame.origin.x,
                    y: snappedOrigin.y - mainFrame.origin.y
                )
                PlaylistWindowAccessor.saveWindowFrame(window)
            }
        }

        private func snapOrigin(
            mainFrame: NSRect, plFrame: NSRect,
            topNearBottom: Bool, bottomNearTop: Bool,
            leftAligned: Bool
        ) -> NSPoint? {
            if topNearBottom && leftAligned {
                return NSPoint(x: mainFrame.minX, y: mainFrame.minY - plFrame.height)
            } else if bottomNearTop && leftAligned {
                return NSPoint(x: mainFrame.minX, y: mainFrame.maxY)
            }
            return nil
        }

        private func cleanupMonitors() {
            if let monitor = mouseUpMonitor {
                NSEvent.removeMonitor(monitor)
                mouseUpMonitor = nil
            }
            if let monitor = dragMonitor {
                NSEvent.removeMonitor(monitor)
                dragMonitor = nil
            }
        }

        deinit {
            cleanupMonitors()
        }

        func windowWillStartLiveResize(_ notification: Notification) {
            isResizing = true
        }

        func windowDidEndLiveResize(_ notification: Notification) {
            isResizing = false
            // Update snap offset after resize
            if WinampWindow.isSnapped, let window = window, let mainWindow = WinampWindow.current {
                let mainFrame = mainWindow.frame
                let plFrame = window.frame
                WinampWindow.snapOffset = NSPoint(
                    x: plFrame.origin.x - mainFrame.origin.x,
                    y: plFrame.origin.y - mainFrame.origin.y
                )
            }
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            let scale = parent.scale
            let minW = CGFloat(WinampSkin.playlistMinWidth) * scale
            let incX = CGFloat(WinampSkin.playlistResizeIncrementX) * scale

            if parent.isPlaylistShade {
                // In shade mode: only allow horizontal resize, fixed height
                let shadeH = CGFloat(WinampSkin.playlistShadeHeight) * scale
                var w = max(minW, frameSize.width)
                w = minW + round((w - minW) / incX) * incX

                DispatchQueue.main.async {
                    self.parent.playlistSize.width = w / scale
                    if let window = self.window {
                        PlaylistWindowAccessor.saveWindowFrame(window)
                    }
                }

                return NSSize(width: w, height: shadeH)
            }

            let minH = CGFloat(WinampSkin.playlistMinHeight) * scale
            let incY = CGFloat(WinampSkin.playlistResizeIncrementY) * scale

            var w = max(minW, frameSize.width)
            var h = max(minH, frameSize.height)

            // Snap to grid increments
            w = minW + round((w - minW) / incX) * incX
            h = minH + round((h - minH) / incY) * incY

            // Update the logical size and save frame
            DispatchQueue.main.async {
                let newSize = CGSize(width: w / scale, height: h / scale)
                self.parent.playlistSize = newSize
                PlaylistWindowAccessor.saveLogicalSize(newSize)
                if let window = self.window {
                    PlaylistWindowAccessor.saveWindowFrame(window)
                }
            }

            return NSSize(width: w, height: h)
        }
    }
}
