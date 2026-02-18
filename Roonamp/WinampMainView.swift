//
//  WinampMainView.swift
//  Roonamp
//
//  NSView subclass that renders the Winamp main window using CALayers.
//  Replaces the SwiftUI view tree for the normal (non-windowshade) mode.
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Sprite Cache

/// Pre-extracted CGImage sprites from skin bitmaps, built once per skin load.
struct SpriteCache {
    // Main background
    let mainBg: CGImage?

    // Titlebar: active and inactive backgrounds
    let titlebarActive: CGImage?
    let titlebarInactive: CGImage?

    // Titlebar buttons: [normal, pressed] for options/minimize/shade/close
    let titleBtnOptions: (normal: CGImage?, pressed: CGImage?)
    let titleBtnMinimize: (normal: CGImage?, pressed: CGImage?)
    let titleBtnShade: (normal: CGImage?, pressed: CGImage?)
    let titleBtnClose: (normal: CGImage?, pressed: CGImage?)

    // Clutterbar background + active overlays for A, I, D
    let clutterBg: CGImage?
    let clutterA: CGImage?
    let clutterI: CGImage?
    let clutterD: CGImage?

    // Play/pause indicator: playing, paused, stopped
    let playIndicator: CGImage?
    let pauseIndicator: CGImage?

    // Work LEDs: green bright/dim, red bright/dim
    let greenLEDBright: CGImage?
    let greenLEDDim: CGImage?
    let redLEDBright: CGImage?
    let redLEDDim: CGImage?

    // Number digits [0-9, blank, minus] from numbers.bmp
    let digits: [CGImage?]  // 12 entries
    let minusDash: CGImage? // 5x1 dash for minus sign

    // Text characters from text.bmp (5x6 each)
    let textChars: [Character: CGImage]

    // Mono/stereo composites
    let monoActive: CGImage?
    let monoInactive: CGImage?
    let stereoActive: CGImage?
    let stereoInactive: CGImage?

    // Position bar
    let posBarBg: CGImage?
    let posThumbNormal: CGImage?
    let posThumbPressed: CGImage?

    // Volume backgrounds (28 frames) and thumbs
    let volumeFrames: [CGImage?]
    let volumeThumbNormal: CGImage?
    let volumeThumbPressed: CGImage?

    // Balance backgrounds (28 frames, cropped) and thumbs
    let balanceFrames: [CGImage?]
    let balanceThumbNormal: CGImage?
    let balanceThumbPressed: CGImage?

    // Transport buttons: [normal, pressed] for prev/play/pause/stop/next/eject
    let transportButtons: [(normal: CGImage?, pressed: CGImage?)]

    // Toggle buttons: shuffle [off, offPressed, on, onPressed]
    let shuffleStates: [CGImage?]  // 4 states
    let repeatStates: [CGImage?]   // 4 states
    let eqStates: [CGImage?]       // 2 states (off, on)
    let plStates: [CGImage?]       // 2 states (off, on)

    static func build(from skin: WinampSkin) -> SpriteCache {
        let mainCG = skin.mainWindowBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let titleCG = skin.titleBarBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let cbuttonsCG = skin.playPauseBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let posbarCG = skin.positionBarBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let volumeCG = skin.volumeBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let balanceCG = skin.balanceBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let playpausCG = skin.playpausBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let textCG = skin.textBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let numbersCG = skin.numbersBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let monosterCG = skin.monosterBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let shufrepCG = skin.shuffleRepeatBitmap?.cgImage(forProposedRect: nil, context: nil, hints: nil)

        // Copy sprite into an independent buffer so the source bitmap's
        // backing store can be freed after SpriteCache is built.
        func crop(_ img: CGImage?, _ r: CGRect) -> CGImage? {
            guard let img = img, let cropped = img.cropping(to: r) else { return nil }
            let w = cropped.width
            let h = cropped.height
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }

        // Titlebar backgrounds
        let titlebarActive = crop(titleCG, CGRect(x: 27, y: 0, width: 275, height: 14))
        let titlebarInactive = crop(titleCG, CGRect(x: 27, y: 15, width: 275, height: 14))

        // Titlebar buttons (9x9 each from titlebar.bmp)
        let titleBtnOptions = (
            normal: crop(titleCG, CGRect(x: 0, y: 0, width: 9, height: 9)),
            pressed: crop(titleCG, CGRect(x: 0, y: 9, width: 9, height: 9))
        )
        let titleBtnMinimize = (
            normal: crop(titleCG, CGRect(x: 9, y: 0, width: 9, height: 9)),
            pressed: crop(titleCG, CGRect(x: 9, y: 9, width: 9, height: 9))
        )
        let titleBtnShade = (
            normal: crop(titleCG, CGRect(x: 0, y: 18, width: 9, height: 9)),
            pressed: crop(titleCG, CGRect(x: 9, y: 18, width: 9, height: 9))
        )
        let titleBtnClose = (
            normal: crop(titleCG, CGRect(x: 18, y: 0, width: 9, height: 9)),
            pressed: crop(titleCG, CGRect(x: 18, y: 9, width: 9, height: 9))
        )

        // Clutterbar
        let clutterBg = crop(titleCG, CGRect(x: 304, y: 0, width: 8, height: 43))
        let clutterA = crop(titleCG, CGRect(x: 312, y: 55, width: 8, height: 7))
        let clutterI = crop(titleCG, CGRect(x: 320, y: 62, width: 8, height: 7))
        let clutterD = crop(titleCG, CGRect(x: 328, y: 69, width: 8, height: 8))

        // Play/pause indicators from playpaus.bmp
        let playIndicator = crop(playpausCG, CGRect(x: 0, y: 0, width: 9, height: 9))
        let pauseIndicator = crop(playpausCG, CGRect(x: 9, y: 0, width: 9, height: 9))

        // Work LEDs from playpaus.bmp
        let greenLEDBright = crop(playpausCG, CGRect(x: 36, y: 0, width: 3, height: 3))
        let greenLEDDim = crop(playpausCG, CGRect(x: 39, y: 0, width: 3, height: 3))
        let redLEDBright = crop(playpausCG, CGRect(x: 36, y: 6, width: 3, height: 3))
        let redLEDDim = crop(playpausCG, CGRect(x: 39, y: 6, width: 3, height: 3))

        // Number digits (9x13 each) from numbers.bmp
        var digits: [CGImage?] = []
        for i in 0..<12 {
            digits.append(crop(numbersCG, CGRect(x: CGFloat(i) * 9, y: 0, width: 9, height: 13)))
        }
        let minusDash = crop(numbersCG, CGRect(x: 20, y: 6, width: 5, height: 1))

        // Text characters (5x6 each) from text.bmp
        var textChars: [Character: CGImage] = [:]
        let row0 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@   "
        let row1 = "0123456789 .:()-\'!_+\\/[]^&%,=$#"
        let row2 = "  ?*                            "
        let charMaps = [row0, row1, row2]
        for (rowIdx, charMap) in charMaps.enumerated() {
            for (colIdx, ch) in charMap.enumerated() {
                if ch == " " { continue }
                if textChars[ch] != nil { continue }
                if let img = crop(textCG, CGRect(x: CGFloat(colIdx) * 5, y: CGFloat(rowIdx) * 6, width: 5, height: 6)) {
                    textChars[ch] = img
                }
            }
        }

        // Mono/stereo from monoster.bmp (58x24)
        let stereoActive = crop(monosterCG, CGRect(x: 0, y: 0, width: 29, height: 12))
        let stereoInactive = crop(monosterCG, CGRect(x: 0, y: 12, width: 29, height: 12))
        let monoActive = crop(monosterCG, CGRect(x: 29, y: 0, width: 29, height: 12))
        let monoInactive = crop(monosterCG, CGRect(x: 29, y: 12, width: 29, height: 12))

        // Position bar from posbar.bmp
        let posBarBg = crop(posbarCG, CGRect(x: 0, y: 0, width: 248, height: 10))
        let posThumbNormal = crop(posbarCG, CGRect(x: 248, y: 0, width: 29, height: 10))
        let posThumbPressed = crop(posbarCG, CGRect(x: 278, y: 0, width: 29, height: 10))

        // Volume frames (28 frames, each 68x13, starting at y=0, frame height 15)
        var volumeFrames: [CGImage?] = []
        for i in 0..<28 {
            volumeFrames.append(crop(volumeCG, CGRect(x: 0, y: CGFloat(i) * 15, width: 68, height: 13)))
        }
        // Volume thumbs at y = 28*15 + 2 = 422
        let volThumbY: CGFloat = 28 * 15 + 2
        let volumeThumbNormal = crop(volumeCG, CGRect(x: 15, y: volThumbY, width: 14, height: 11))
        let volumeThumbPressed = crop(volumeCG, CGRect(x: 0, y: volThumbY, width: 14, height: 11))

        // Balance frames (28 frames from balance.bmp, cropped to 38px width starting at x=9)
        var balanceFrames: [CGImage?] = []
        if let balCG = balanceCG {
            for i in 0..<28 {
                let full = crop(balCG, CGRect(x: 9, y: CGFloat(i) * 15, width: 38, height: 13))
                balanceFrames.append(full)
            }
        }
        // Balance thumbs - same as volume thumbs from volume.bmp
        let balanceThumbNormal = volumeThumbNormal
        let balanceThumbPressed = volumeThumbPressed

        // Transport buttons from cbuttons.bmp (136x36)
        let bitmapOffsets: [CGFloat] = [0, 23, 46, 69, 92, 114]
        let buttonWidths: [CGFloat] = [23, 23, 23, 23, 22, 22]
        let buttonHeights: [CGFloat] = [18, 18, 18, 18, 18, 16]
        var transportButtons: [(normal: CGImage?, pressed: CGImage?)] = []
        for i in 0..<6 {
            let w = buttonWidths[i]
            let h = buttonHeights[i]
            let x = bitmapOffsets[i]
            transportButtons.append((
                normal: crop(cbuttonsCG, CGRect(x: x, y: 0, width: w, height: h)),
                pressed: crop(cbuttonsCG, CGRect(x: x, y: h, width: w, height: h))
            ))
        }

        // Shuffle toggle (4 rows of 47x15 at x=28)
        var shuffleStates: [CGImage?] = []
        for i in 0..<4 {
            shuffleStates.append(crop(shufrepCG, CGRect(x: 28, y: CGFloat(i) * 15, width: 47, height: 15)))
        }

        // Repeat toggle (4 rows of 28x15 at x=0)
        var repeatStates: [CGImage?] = []
        for i in 0..<4 {
            repeatStates.append(crop(shufrepCG, CGRect(x: 0, y: CGFloat(i) * 15, width: 28, height: 15)))
        }

        // EQ toggle (2 rows of 23x12 at x=0, y=61) - topBorder=1
        var eqStates: [CGImage?] = []
        eqStates.append(crop(shufrepCG, CGRect(x: 0, y: 61, width: 23, height: 12)))  // off
        eqStates.append(crop(shufrepCG, CGRect(x: 0, y: 73, width: 23, height: 12)))  // on

        // PL toggle (2 rows of 23x12 at x=23, y=61) - topBorder=1
        var plStates: [CGImage?] = []
        plStates.append(crop(shufrepCG, CGRect(x: 23, y: 61, width: 23, height: 12)))  // off
        plStates.append(crop(shufrepCG, CGRect(x: 23, y: 73, width: 23, height: 12)))  // on

        // Copy mainBg into independent buffer too
        let mainBg = mainCG.flatMap { m in crop(m, CGRect(x: 0, y: 0, width: m.width, height: m.height)) }

        return SpriteCache(
            mainBg: mainBg,
            titlebarActive: titlebarActive,
            titlebarInactive: titlebarInactive,
            titleBtnOptions: titleBtnOptions,
            titleBtnMinimize: titleBtnMinimize,
            titleBtnShade: titleBtnShade,
            titleBtnClose: titleBtnClose,
            clutterBg: clutterBg,
            clutterA: clutterA,
            clutterI: clutterI,
            clutterD: clutterD,
            playIndicator: playIndicator,
            pauseIndicator: pauseIndicator,
            greenLEDBright: greenLEDBright,
            greenLEDDim: greenLEDDim,
            redLEDBright: redLEDBright,
            redLEDDim: redLEDDim,
            digits: digits,
            minusDash: minusDash,
            textChars: textChars,
            monoActive: monoActive,
            monoInactive: monoInactive,
            stereoActive: stereoActive,
            stereoInactive: stereoInactive,
            posBarBg: posBarBg,
            posThumbNormal: posThumbNormal,
            posThumbPressed: posThumbPressed,
            volumeFrames: volumeFrames,
            volumeThumbNormal: volumeThumbNormal,
            volumeThumbPressed: volumeThumbPressed,
            balanceFrames: balanceFrames,
            balanceThumbNormal: balanceThumbNormal,
            balanceThumbPressed: balanceThumbPressed,
            transportButtons: transportButtons,
            shuffleStates: shuffleStates,
            repeatStates: repeatStates,
            eqStates: eqStates,
            plStates: plStates
        )
    }
}

// MARK: - Hit Region

struct HitRegion {
    let rect: CGRect  // in unscaled Winamp coordinates
    let onPress: ((CGPoint) -> Void)?
    let onDrag: ((CGPoint) -> Void)?
    let onRelease: ((CGPoint) -> Void)?
    let visualFeedback: ((Bool) -> Void)?  // pressed state
}

// MARK: - WinampMainView

final class WinampMainView: NSView {

    // Dimensions
    private let winWidth: CGFloat = 275
    private let winHeight: CGFloat = 116

    // Scale
    var scale: CGFloat = 2.0 {
        didSet {
            guard scale != oldValue else { return }
            updateScale()
        }
    }

    // Skin & sprite cache
    var sprites: SpriteCache? {
        didSet { rebuildAllLayers() }
    }

    // State cache (to avoid redundant updates)
    private var cachedState: RoonZone.PlaybackState?
    private var cachedSeekPosition: Int = 0
    private var cachedLength: Int?
    private var cachedTitle: String = ""
    private var cachedArtist: String = ""
    var displayKbps: String = ""
    var displayKHz: String = ""
    private var cachedChannels: Int = 2
    private var cachedShuffle: Bool = false
    private var cachedLoop: LoopMode = .disabled
    private var cachedVolumeProgress: Double = 0.75
    private var cachedIsPlaylistVisible: Bool = false
    private var cachedIsAlbumArtVisible: Bool = false
    private var cachedAlwaysOnTop: Bool = false
    private var cachedIsWindowActive: Bool = true

    // Timer state
    private var comboTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkVisible: Bool = true
    private var lastUpdateTime: Date = Date()
    private var currentSeekPosition: Int = 0
    private var localSeekPosition: Int?  // non-nil after local seek, cleared on server confirm

    // Title scroll state
    private var scrollOffset: CGFloat = 0
    private var scrollDirection: CGFloat = 1.0
    private var renderedTitleWidth: CGFloat = 0

    // Time display
    var showRemaining: Bool = false

    // Drag state
    private var isDraggingPos: Bool = false
    private var dragPosProgress: Double = 0
    private var dragPosStartProgress: Double = 0
    private var pendingSeekProgress: Double?

    private var isDraggingVolume: Bool = false
    private var dragVolumeProgress: Double = 0
    private var dragVolumeStartProgress: Double = 0
    private var isDraggingBalance: Bool = false
    private var dragBalanceProgress: Double = 0.5

    // Pressed button tracking
    private var pressedRegionIndex: Int?
    private var hitRegions: [HitRegion] = []

    // External callbacks (set by bridge)
    var onPrevious: (() -> Void)?
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onNext: (() -> Void)?
    var onEject: (() -> Void)?
    var onSeek: ((Int) -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    var onShuffleToggle: (() -> Void)?
    var onLoopCycle: (() -> Void)?
    var onPlaylistToggle: (() -> Void)?
    var onOptions: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onShade: (() -> Void)?
    var onClose: (() -> Void)?
    var onAlwaysOnTopToggle: (() -> Void)?
    var onAlbumArtToggle: (() -> Void)?
    var onCycleScale: (() -> Void)?
    var onTimeDisplayTap: (() -> Void)?
    var onVisualizerTap: (() -> Void)?

    // Visualizer mode (for cycling on tap)
    var visualizerMode: VisualizerMode = .spectrum

    // MARK: - Layers

    private let rootLayer = CALayer()
    private let contentLayer = CALayer()  // provides unscaled coordinate mapping
    private let backgroundLayer = CALayer()
    private let titlebarLayer = CALayer()

    // Title bar buttons
    private let optionsButtonLayer = CALayer()
    private let minimizeButtonLayer = CALayer()
    private let shadeButtonLayer = CALayer()
    private let closeButtonLayer = CALayer()

    // Clutterbar
    private let clutterbarLayer = CALayer()

    // Indicators
    private let playPausIndicatorLayer = CALayer()
    private let greenLEDLayer = CALayer()
    private let redLEDLayer = CALayer()

    // Time display
    private let timeDisplayLayer = CALayer()

    // Title text
    private let titleTextClipLayer = CALayer()
    private let titleTextLayer = CALayer()

    // Info displays
    private let kbpsLayer = CALayer()
    private let kHzLayer = CALayer()

    // Mono/stereo
    private let monoLayer = CALayer()
    private let stereoLayer = CALayer()

    // Position bar
    private let posBarBgLayer = CALayer()
    private let posThumbLayer = CALayer()

    // Volume
    private let volumeBgLayer = CALayer()
    private let volumeThumbLayer = CALayer()

    // Balance
    private let balanceBgLayer = CALayer()
    private let balanceThumbLayer = CALayer()

    // Transport buttons
    private var transportButtonLayers: [CALayer] = []

    // Toggle buttons
    private let shuffleLayer = CALayer()
    private let repeatLayer = CALayer()
    private let eqLayer = CALayer()
    private let plLayer = CALayer()

    // Visualizer (embedded NSView)
    private var visualizerView: VisualizerLayerView?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
        layer = rootLayer
        rootLayer.masksToBounds = true

        // Content layer provides unscaled coordinate mapping via transform
        // anchorPoint (0,0) + position (0,0) = top-left origin, transform scales up
        contentLayer.anchorPoint = CGPoint(x: 0, y: 0)
        contentLayer.position = CGPoint(x: 0, y: 0)
        contentLayer.bounds = CGRect(origin: .zero, size: CGSize(width: winWidth, height: winHeight))
        contentLayer.masksToBounds = true
        contentLayer.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        rootLayer.addSublayer(contentLayer)

        // Configure all layers with nearest-neighbor filtering
        let allLayers: [CALayer] = [
            backgroundLayer, titlebarLayer,
            optionsButtonLayer, minimizeButtonLayer, shadeButtonLayer, closeButtonLayer,
            clutterbarLayer,
            playPausIndicatorLayer, greenLEDLayer, redLEDLayer,
            timeDisplayLayer,
            titleTextClipLayer,
            kbpsLayer, kHzLayer,
            monoLayer, stereoLayer,
            posBarBgLayer, posThumbLayer,
            volumeBgLayer, volumeThumbLayer,
            balanceBgLayer, balanceThumbLayer,
            shuffleLayer, repeatLayer, eqLayer, plLayer
        ]

        for l in allLayers {
            l.magnificationFilter = .nearest
            l.minificationFilter = .nearest
            l.contentsGravity = .resize
            l.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
                         "opacity": NSNull(), "hidden": NSNull()]
        }

        titleTextLayer.magnificationFilter = .nearest
        titleTextLayer.minificationFilter = .nearest
        titleTextLayer.contentsGravity = .resize
        titleTextLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]

        // Create transport button layers
        for _ in 0..<6 {
            let l = CALayer()
            l.magnificationFilter = .nearest
            l.minificationFilter = .nearest
            l.contentsGravity = .resize
            l.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
            transportButtonLayers.append(l)
        }

        // Title text clipping
        titleTextClipLayer.masksToBounds = true
        titleTextClipLayer.addSublayer(titleTextLayer)

        // Build layer tree — all sublayers go on contentLayer (unscaled coordinates)
        contentLayer.addSublayer(backgroundLayer)
        contentLayer.addSublayer(titlebarLayer)
        contentLayer.addSublayer(optionsButtonLayer)
        contentLayer.addSublayer(minimizeButtonLayer)
        contentLayer.addSublayer(shadeButtonLayer)
        contentLayer.addSublayer(closeButtonLayer)
        contentLayer.addSublayer(clutterbarLayer)
        contentLayer.addSublayer(playPausIndicatorLayer)
        contentLayer.addSublayer(greenLEDLayer)
        contentLayer.addSublayer(redLEDLayer)
        contentLayer.addSublayer(timeDisplayLayer)
        contentLayer.addSublayer(titleTextClipLayer)
        contentLayer.addSublayer(kbpsLayer)
        contentLayer.addSublayer(kHzLayer)
        contentLayer.addSublayer(monoLayer)
        contentLayer.addSublayer(stereoLayer)
        contentLayer.addSublayer(posBarBgLayer)
        contentLayer.addSublayer(posThumbLayer)
        contentLayer.addSublayer(volumeBgLayer)
        contentLayer.addSublayer(volumeThumbLayer)
        contentLayer.addSublayer(balanceBgLayer)
        contentLayer.addSublayer(balanceThumbLayer)
        for tl in transportButtonLayers {
            contentLayer.addSublayer(tl)
        }
        contentLayer.addSublayer(shuffleLayer)
        contentLayer.addSublayer(repeatLayer)
        contentLayer.addSublayer(eqLayer)
        contentLayer.addSublayer(plLayer)

        // Set up visualizer view
        let visView = VisualizerLayerView(frame: .zero)
        visualizerView = visView
        addSubview(visView)
    }

    // MARK: - Layout & Scale

    override func layout() {
        super.layout()
        syncContentLayer()
    }

    private func syncContentLayer() {
        let s = bounds.width / winWidth
        guard s > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()

        // Update visualizer view frame (subview uses scaled coordinates)
        let visR = WinampSkin.visualizerRegion
        visualizerView?.frame = NSRect(
            x: CGFloat(visR.x) * s,
            y: CGFloat(visR.y) * s,
            width: CGFloat(visR.width) * s,
            height: CGFloat(visR.height) * s
        )
    }

    private func updateScale() {
        syncContentLayer()
    }

    // MARK: - Rebuild All Layers

    func rebuildAllLayers() {
        guard let sp = sprites else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Ensure contentLayer transform is synced
        let s = scale
        contentLayer.transform = CATransform3DMakeScale(s, s, 1)

        // Background
        backgroundLayer.frame = CGRect(x: 0, y: 0, width: winWidth, height: winHeight)
        backgroundLayer.contents = sp.mainBg

        // Titlebar
        let tbR = WinampSkin.titleBarRegion
        titlebarLayer.frame = CGRect(x: CGFloat(tbR.x), y: CGFloat(tbR.y),
                                      width: CGFloat(tbR.width), height: CGFloat(tbR.height))
        titlebarLayer.contents = cachedIsWindowActive ? sp.titlebarActive : sp.titlebarInactive

        // Titlebar buttons
        setupButtonLayer(optionsButtonLayer, WinampSkin.titleBarOptionsButton, sp.titleBtnOptions.normal)
        setupButtonLayer(minimizeButtonLayer, WinampSkin.titleBarMinimizeButton, sp.titleBtnMinimize.normal)
        setupButtonLayer(shadeButtonLayer, WinampSkin.titleBarShadeButton, sp.titleBtnShade.normal)
        setupButtonLayer(closeButtonLayer, WinampSkin.titleBarCloseButton, sp.titleBtnClose.normal)

        // Clutterbar
        updateClutterbar()

        // Play/pause indicator
        let ppR = WinampSkin.playPausIndicatorRegion
        playPausIndicatorLayer.frame = CGRect(x: CGFloat(ppR.x), y: CGFloat(ppR.y),
                                               width: CGFloat(ppR.width), height: CGFloat(ppR.height))

        // LEDs
        let gR = WinampSkin.workGreenRegion
        greenLEDLayer.frame = CGRect(x: CGFloat(gR.x), y: CGFloat(gR.y),
                                      width: CGFloat(gR.width), height: CGFloat(gR.height))
        let rR = WinampSkin.workRedRegion
        redLEDLayer.frame = CGRect(x: CGFloat(rR.x), y: CGFloat(rR.y),
                                    width: CGFloat(rR.width), height: CGFloat(rR.height))

        // Time display - positioned to match existing layout
        let tR = WinampSkin.timeRegion
        // Time display: rendered image includes minus space + digits
        // Layout: minus(9)+gap(4) + M1(9)+3 + M2(9)+9 + S1(9)+3 + S2(9) = 13+12+18+12+9 = 64
        let timeWidth: CGFloat = 64
        let charWidth: CGFloat = 9
        let baseOffset = CGFloat(tR.x) + 9 - 12 - (charWidth + 4)
        timeDisplayLayer.frame = CGRect(x: baseOffset, y: CGFloat(tR.y),
                                         width: timeWidth, height: 13)

        // Title text clip area
        let titleR = WinampSkin.titleRegion
        titleTextClipLayer.frame = CGRect(x: CGFloat(titleR.x), y: CGFloat(titleR.y),
                                           width: CGFloat(titleR.width), height: CGFloat(titleR.height))
        titleTextLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(titleR.width), height: 6)

        // Info displays
        let kbpsR = WinampSkin.kbpsRegion
        kbpsLayer.frame = CGRect(x: CGFloat(kbpsR.x), y: CGFloat(kbpsR.y),
                                  width: CGFloat(kbpsR.width), height: CGFloat(kbpsR.height))
        let kHzR = WinampSkin.kHzRegion
        kHzLayer.frame = CGRect(x: CGFloat(kHzR.x), y: CGFloat(kHzR.y),
                                 width: CGFloat(kHzR.width), height: CGFloat(kHzR.height))

        // Mono/stereo
        let msR = WinampSkin.monoStereoRegion
        monoLayer.frame = CGRect(x: CGFloat(msR.x), y: CGFloat(msR.y), width: 29, height: 12)
        stereoLayer.frame = CGRect(x: CGFloat(msR.x) + 29, y: CGFloat(msR.y), width: 29, height: 12)

        // Position bar
        let posR = WinampSkin.positionBarRegion
        posBarBgLayer.frame = CGRect(x: CGFloat(posR.x), y: CGFloat(posR.y),
                                      width: CGFloat(posR.width), height: CGFloat(posR.height))
        posBarBgLayer.contents = sp.posBarBg
        posThumbLayer.frame = CGRect(x: CGFloat(posR.x), y: CGFloat(posR.y), width: 29, height: 10)
        posThumbLayer.contents = sp.posThumbNormal

        // Volume
        let volR = WinampSkin.volumeBarRegion
        volumeBgLayer.frame = CGRect(x: CGFloat(volR.x), y: CGFloat(volR.y) - 1,
                                      width: CGFloat(volR.width), height: CGFloat(volR.height))
        volumeThumbLayer.frame = CGRect(x: CGFloat(volR.x), y: CGFloat(volR.y) - 1, width: 14, height: 11)
        volumeThumbLayer.contents = sp.volumeThumbNormal

        // Balance
        let balR = WinampSkin.balanceBarRegion
        balanceBgLayer.frame = CGRect(x: CGFloat(balR.x), y: CGFloat(balR.y) - 1,
                                       width: CGFloat(balR.width), height: CGFloat(balR.height))
        balanceThumbLayer.frame = CGRect(x: CGFloat(balR.x), y: CGFloat(balR.y) - 1, width: 14, height: 11)
        balanceThumbLayer.contents = sp.balanceThumbNormal

        // Transport buttons
        let transportRegions: [WinampSkin.ButtonRegion] = [
            WinampSkin.previousButton, WinampSkin.playButton, WinampSkin.pauseButton,
            WinampSkin.stopButton, WinampSkin.nextButton, WinampSkin.ejectButton
        ]
        for (i, region) in transportRegions.enumerated() {
            setupButtonLayer(transportButtonLayers[i], region,
                           sp.transportButtons[i].normal)
        }

        // Toggle buttons
        let shufR = WinampSkin.shuffleButton
        shuffleLayer.frame = CGRect(x: CGFloat(shufR.x), y: CGFloat(shufR.y),
                                     width: CGFloat(shufR.width), height: CGFloat(shufR.height))
        let repR = WinampSkin.repeatButton
        repeatLayer.frame = CGRect(x: CGFloat(repR.x), y: CGFloat(repR.y),
                                    width: CGFloat(repR.width), height: CGFloat(repR.height))
        let eqR = WinampSkin.eqButton
        eqLayer.frame = CGRect(x: CGFloat(eqR.x), y: CGFloat(eqR.y),
                                width: CGFloat(eqR.width), height: CGFloat(eqR.height))
        let plR = WinampSkin.plButton
        plLayer.frame = CGRect(x: CGFloat(plR.x), y: CGFloat(plR.y),
                                width: CGFloat(plR.width), height: CGFloat(plR.height))

        // Visualizer
        let visR = WinampSkin.visualizerRegion
        visualizerView?.frame = NSRect(
            x: CGFloat(visR.x) * scale,
            y: CGFloat(visR.y) * scale,
            width: CGFloat(visR.width) * scale,
            height: CGFloat(visR.height) * scale
        )

        CATransaction.commit()

        // Update dynamic content
        updateVolume()
        updateBalance()
        updateToggleButtons()
        updatePlayState()
        updateTimeDisplay()
        updateTitleText()
        updateInfoDisplays()
        updateMonoStereo()
        updatePositionThumb()
        buildHitRegions()
    }

    private func setupButtonLayer(_ layer: CALayer, _ region: WinampSkin.ButtonRegion, _ content: CGImage?) {
        layer.frame = CGRect(x: CGFloat(region.x), y: CGFloat(region.y),
                             width: CGFloat(region.width), height: CGFloat(region.height))
        layer.contents = content
    }

    // MARK: - Clutterbar

    private func updateClutterbar() {
        guard let sp = sprites else { return }
        let r = WinampSkin.clutterBarRegion

        // Composite clutterbar onto a CGImage
        let w = r.width
        let h = r.height
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: bitmapInfo.rawValue) else { return }

        // Draw background
        if let bg = sp.clutterBg {
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Draw active overlays (coordinates are in flipped space, but CGContext is bottom-up)
        // clutterbar is 8x43, overlays at specific y offsets
        // A at yOffset=11, height=7
        if cachedAlwaysOnTop, let img = sp.clutterA {
            ctx.draw(img, in: CGRect(x: 0, y: CGFloat(h) - 11 - 7, width: 8, height: 7))
        }
        // I at yOffset=18, height=7
        if cachedIsAlbumArtVisible, let img = sp.clutterI {
            ctx.draw(img, in: CGRect(x: 0, y: CGFloat(h) - 18 - 7, width: 8, height: 7))
        }
        // D at yOffset=25, height=8
        let isScaled = scale > 1.0
        if isScaled, let img = sp.clutterD {
            ctx.draw(img, in: CGRect(x: 0, y: CGFloat(h) - 25 - 8, width: 8, height: 8))
        }

        clutterbarLayer.frame = CGRect(x: CGFloat(r.x), y: CGFloat(r.y),
                                        width: CGFloat(w), height: CGFloat(h))
        clutterbarLayer.contents = ctx.makeImage()
    }

    // MARK: - Play State Update

    func updateZone(_ zone: RoonZone?) {
        guard let zone = zone else {
            // No zone - hide dynamic elements
            playPausIndicatorLayer.isHidden = true
            greenLEDLayer.isHidden = true
            redLEDLayer.isHidden = true
            titleTextLayer.contents = nil
            timeDisplayLayer.isHidden = true
            monoLayer.isHidden = true
            stereoLayer.isHidden = true
            cachedState = nil
            cachedTitle = ""
            cachedArtist = ""
            stopTimers()
            return
        }

        let stateChanged = zone.state != cachedState
        let np = zone.nowPlaying

        // Update seek position from server
        if let newPos = np?.seekPosition {
            cachedSeekPosition = newPos
            if let localSeek = localSeekPosition {
                if abs(newPos - localSeek) <= 3 {
                    localSeekPosition = nil
                    currentSeekPosition = newPos
                    lastUpdateTime = Date()
                }
            } else {
                currentSeekPosition = newPos
                lastUpdateTime = Date()
            }
        }

        // Play state
        if stateChanged {
            cachedState = zone.state
            updatePlayState()
            // Update visualizer playing state
            visualizerView?.isPlaying = zone.state == .playing
            visualizerView?.updateAnimation()
            if zone.state == .playing {
                lastUpdateTime = Date()
                startTimers()
            } else {
                stopTimers()
                if zone.state == .paused {
                    startBlinkTimer()
                }
            }
        }

        // Title
        let newTitle = np?.title ?? ""
        let newArtist = np?.artist ?? ""
        if newTitle != cachedTitle || newArtist != cachedArtist {
            cachedTitle = newTitle
            cachedArtist = newArtist
            scrollOffset = 0
            scrollDirection = 1.0
            updateTitleText()
        }

        // Length
        let newLength = np?.length
        if newLength != cachedLength {
            cachedLength = newLength
        }

        // Mono/stereo
        let newChannels = np?.channels ?? 2
        if newChannels != cachedChannels {
            cachedChannels = newChannels
            updateMonoStereo()
        }

        // Volume
        if let vol = zone.volume {
            let range = vol.max - vol.min
            let newProgress = range > 0 ? (vol.value - vol.min) / range : 0
            if abs(newProgress - cachedVolumeProgress) > 0.001 {
                cachedVolumeProgress = newProgress
                updateVolume()
            }
        }

        // Shuffle/repeat
        let newShuffle = zone.settings?.shuffle ?? false
        let newLoop = zone.settings?.loop ?? .disabled
        if newShuffle != cachedShuffle || newLoop != cachedLoop {
            cachedShuffle = newShuffle
            cachedLoop = newLoop
            updateToggleButtons()
        }

        // Position
        updatePositionThumb()
        updateTimeDisplay()
    }

    func updatePlaylistVisible(_ visible: Bool) {
        guard visible != cachedIsPlaylistVisible else { return }
        cachedIsPlaylistVisible = visible
        updateToggleButtons()
    }

    func updateAlbumArtVisible(_ visible: Bool) {
        guard visible != cachedIsAlbumArtVisible else { return }
        cachedIsAlbumArtVisible = visible
        updateClutterbar()
    }

    func updateSeekPosition(_ newPos: Int) {
        cachedSeekPosition = newPos
        if let localSeek = localSeekPosition {
            if abs(newPos - localSeek) <= 3 {
                localSeekPosition = nil
                currentSeekPosition = newPos
                lastUpdateTime = Date()
            }
        } else {
            currentSeekPosition = newPos
            lastUpdateTime = Date()
        }
    }

    func updateAlwaysOnTop(_ onTop: Bool) {
        guard onTop != cachedAlwaysOnTop else { return }
        cachedAlwaysOnTop = onTop
        updateClutterbar()
    }

    func updateWindowActive(_ active: Bool) {
        guard active != cachedIsWindowActive else { return }
        cachedIsWindowActive = active
        guard let sp = sprites else { return }
        titlebarLayer.contents = active ? sp.titlebarActive : sp.titlebarInactive
    }

    // MARK: - Update Methods

    private func updatePlayState() {
        guard let sp = sprites else { return }
        let state = cachedState

        let isPlayingOrPaused = state == .playing || state == .paused
        playPausIndicatorLayer.isHidden = !isPlayingOrPaused
        greenLEDLayer.isHidden = state != .playing
        redLEDLayer.isHidden = state != .playing

        if isPlayingOrPaused {
            playPausIndicatorLayer.contents = state == .playing ? sp.playIndicator : sp.pauseIndicator
        }

        if state == .playing {
            greenLEDLayer.contents = sp.greenLEDBright
            redLEDLayer.contents = sp.redLEDDim
        }

        timeDisplayLayer.isHidden = state != .playing && state != .paused
        blinkVisible = true
        timeDisplayLayer.opacity = 1
    }

    private func updateTimeDisplay() {
        guard let sp = sprites else { return }

        let seekPos = cachedState == .playing ? currentSeekPosition : (cachedSeekPosition)
        let timeImage = renderTimeImage(seekPos, sprites: sp)
        timeDisplayLayer.contents = timeImage
    }

    private func renderTimeImage(_ seconds: Int, sprites sp: SpriteCache) -> CGImage? {
        // Calculate time to display
        let timeToShow: Int
        let isNegative: Bool
        if showRemaining, let length = cachedLength {
            timeToShow = max(0, length - seconds)
            isNegative = true
        } else {
            timeToShow = seconds
            isNegative = false
        }

        let minutes = timeToShow / 60
        let secs = timeToShow % 60
        let m1 = minutes / 10, m2 = minutes % 10
        let s1 = secs / 10, s2 = secs % 10

        let charWidth: CGFloat = 9
        let charHeight: CGFloat = 13
        // Layout: minus(9)+gap(4) + M1(9)+3 + M2(9)+9 + S1(9)+3 + S2(9) = 64
        let totalWidth: CGFloat = 64

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: Int(totalWidth), height: Int(charHeight),
                                   bitsPerComponent: 8, bytesPerRow: Int(totalWidth) * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: bitmapInfo.rawValue) else { return nil }

        // Clear to transparent
        ctx.clear(CGRect(x: 0, y: 0, width: totalWidth, height: charHeight))

        let minusSpace: CGFloat = charWidth + 4  // 13

        // Draw minus sign
        if isNegative, let dash = sp.minusDash {
            // Draw 5x1 dash centered in 9x13 space
            ctx.draw(dash, in: CGRect(x: 3, y: 6, width: 5, height: 1))
        }

        // Draw digits
        var xOffset = minusSpace
        let digitIndices = [m1, m2, s1, s2]
        let spacing: [CGFloat] = [3, 9, 3, 0]  // after each digit

        for (i, digit) in digitIndices.enumerated() {
            if digit < sp.digits.count, let img = sp.digits[digit] {
                ctx.draw(img, in: CGRect(x: xOffset, y: 0, width: charWidth, height: charHeight))
            }
            xOffset += charWidth + spacing[i]
        }

        return ctx.makeImage()
    }

    private func updateTitleText() {
        guard let sp = sprites else { return }
        guard !cachedTitle.isEmpty || !cachedArtist.isEmpty else {
            titleTextLayer.contents = nil
            renderedTitleWidth = 0
            return
        }

        let text = "\(cachedArtist) - \(cachedTitle)"
        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6
        let spacing: CGFloat = 1

        let upperText = text.uppercased()
        let totalWidth = CGFloat(upperText.count) * (charWidth + spacing)
        renderedTitleWidth = totalWidth

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: max(1, Int(totalWidth)), height: Int(charHeight),
                                   bitsPerComponent: 8, bytesPerRow: max(1, Int(totalWidth)) * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: bitmapInfo.rawValue) else { return }

        ctx.clear(CGRect(x: 0, y: 0, width: totalWidth, height: charHeight))

        var xOff: CGFloat = 0
        for ch in upperText {
            if let img = sp.textChars[ch] {
                ctx.draw(img, in: CGRect(x: xOff, y: 0, width: charWidth, height: charHeight))
            }
            xOff += charWidth + spacing
        }

        titleTextLayer.contents = ctx.makeImage()
        titleTextLayer.frame = CGRect(
            x: -scrollOffset,
            y: 0,
            width: totalWidth,
            height: charHeight
        )
    }

    func updateInfoDisplays() {
        guard let sp = sprites else { return }
        let kbpsText = displayKbps
        let kHzText = displayKHz

        let kbpsR = WinampSkin.kbpsRegion
        let kHzR = WinampSkin.kHzRegion
        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6

        if let img = renderSmallText(kbpsText, sprites: sp) {
            let textWidth = CGFloat(kbpsText.count) * charWidth
            // Right-align within the region
            kbpsLayer.frame = CGRect(
                x: CGFloat(kbpsR.x) + CGFloat(kbpsR.width) - textWidth,
                y: CGFloat(kbpsR.y),
                width: textWidth, height: charHeight)
            kbpsLayer.contents = img
        } else {
            kbpsLayer.contents = nil
        }

        if let img = renderSmallText(kHzText, sprites: sp) {
            let textWidth = CGFloat(kHzText.count) * charWidth
            kHzLayer.frame = CGRect(
                x: CGFloat(kHzR.x) + CGFloat(kHzR.width) - textWidth,
                y: CGFloat(kHzR.y),
                width: textWidth, height: charHeight)
            kHzLayer.contents = img
        } else {
            kHzLayer.contents = nil
        }
    }

    private func renderSmallText(_ text: String, sprites sp: SpriteCache) -> CGImage? {
        let charWidth: CGFloat = 5
        let charHeight: CGFloat = 6
        let upperText = text.uppercased()
        let totalWidth = CGFloat(upperText.count) * charWidth
        guard totalWidth > 0 else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: nil, width: Int(totalWidth), height: Int(charHeight),
                                   bitsPerComponent: 8, bytesPerRow: Int(totalWidth) * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: bitmapInfo.rawValue) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: totalWidth, height: charHeight))

        var xOff: CGFloat = 0
        for ch in upperText {
            if let img = sp.textChars[ch] {
                ctx.draw(img, in: CGRect(x: xOff, y: 0, width: charWidth, height: charHeight))
            }
            xOff += charWidth
        }

        return ctx.makeImage()
    }

    private func updateMonoStereo() {
        guard let sp = sprites else { return }
        let isStereo = cachedChannels >= 2
        monoLayer.isHidden = false
        stereoLayer.isHidden = false
        monoLayer.contents = isStereo ? sp.monoInactive : sp.monoActive
        stereoLayer.contents = isStereo ? sp.stereoActive : sp.stereoInactive
    }

    private func updatePositionThumb() {
        guard sprites != nil else { return }
        guard let length = cachedLength, length > 0 else {
            posThumbLayer.isHidden = true
            return
        }
        posThumbLayer.isHidden = false

        let seekPos = cachedState == .playing ? currentSeekPosition : cachedSeekPosition

        let progress: Double
        if isDraggingPos {
            progress = dragPosProgress
        } else if let pending = pendingSeekProgress {
            let liveProgress = min(1.0, max(0.0, Double(seekPos) / Double(length)))
            if abs(liveProgress - pending) > 0.01 {
                pendingSeekProgress = nil
                progress = liveProgress
            } else {
                progress = pending
            }
        } else {
            progress = min(1.0, max(0.0, Double(seekPos) / Double(length)))
        }

        let posR = WinampSkin.positionBarRegion
        let maxOffset = CGFloat(posR.width) - 29
        let thumbX = CGFloat(posR.x) + progress * maxOffset
        posThumbLayer.frame.origin.x = thumbX
    }

    private func updateVolume() {
        guard let sp = sprites else { return }
        let progress = isDraggingVolume ? dragVolumeProgress : cachedVolumeProgress
        let frameIndex = min(27, Int(progress * 27))
        if frameIndex < sp.volumeFrames.count {
            volumeBgLayer.contents = sp.volumeFrames[frameIndex]
        }

        let volR = WinampSkin.volumeBarRegion
        let maxOffset = CGFloat(volR.width) - 14
        let thumbX = CGFloat(volR.x) + progress * maxOffset
        volumeThumbLayer.frame.origin.x = thumbX
    }

    private func updateBalance() {
        guard let sp = sprites else { return }
        let progress = dragBalanceProgress
        // Balance frames: 0 = center, 27 = full left or right
        let deviation = abs(progress - 0.5) * 2  // 0 at center, 1 at extremes
        let frameIndex = min(27, Int(deviation * 27))
        if frameIndex < sp.balanceFrames.count {
            balanceBgLayer.contents = sp.balanceFrames[frameIndex]
        }
        let balR = WinampSkin.balanceBarRegion
        let maxOffset = CGFloat(balR.width) - 14
        balanceThumbLayer.frame.origin.x = CGFloat(balR.x) + progress * maxOffset
    }

    private func updateToggleButtons() {
        guard let sp = sprites else { return }

        // Shuffle: off=0, offPressed=1, on=2, onPressed=3
        let shuffleIdx = cachedShuffle ? 2 : 0
        if shuffleIdx < sp.shuffleStates.count {
            shuffleLayer.contents = sp.shuffleStates[shuffleIdx]
        }

        // Repeat
        let loopOn = cachedLoop != .disabled
        let repeatIdx = loopOn ? 2 : 0
        if repeatIdx < sp.repeatStates.count {
            repeatLayer.contents = sp.repeatStates[repeatIdx]
        }

        // EQ (always off)
        if !sp.eqStates.isEmpty {
            eqLayer.contents = sp.eqStates[0]
        }

        // PL
        let plIdx = cachedIsPlaylistVisible ? 1 : 0
        if plIdx < sp.plStates.count {
            plLayer.contents = sp.plStates[plIdx]
        }
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        comboTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.comboTick()
        }
        blinkVisible = true
        timeDisplayLayer.opacity = 1
    }

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkVisible.toggle()
            self.timeDisplayLayer.opacity = self.blinkVisible ? 1 : 0
        }
    }

    private func stopTimers() {
        comboTimer?.invalidate()
        comboTimer = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    private func comboTick() {
        // Interpolate seek position
        if cachedState == .playing {
            let elapsed = Date().timeIntervalSince(lastUpdateTime)
            if let localBase = localSeekPosition {
                currentSeekPosition = localBase + Int(elapsed)
            } else {
                let basePosition = cachedSeekPosition
                currentSeekPosition = basePosition + Int(elapsed)
            }
        }

        // Update time display
        updateTimeDisplay()

        // Update position thumb
        updatePositionThumb()

        // Scroll title text
        let regionWidth = CGFloat(WinampSkin.titleRegion.width)
        if renderedTitleWidth > regionWidth {
            let step: CGFloat = 6.0
            let rawMaxScroll = renderedTitleWidth - regionWidth + 10
            let maxScroll = ceil(rawMaxScroll / step) * step
            scrollOffset += scrollDirection * step
            if scrollOffset >= maxScroll {
                scrollDirection = -1.0
                scrollOffset = maxScroll
            } else if scrollOffset <= 0 {
                scrollDirection = 1.0
                scrollOffset = 0
            }
            titleTextLayer.frame.origin.x = -scrollOffset
        }
    }

    // MARK: - Mouse Handling

    private func buildHitRegions() {
        hitRegions.removeAll()

        // Transport buttons
        let transportRegions: [(WinampSkin.ButtonRegion, Int)] = [
            (WinampSkin.previousButton, 0),
            (WinampSkin.playButton, 1),
            (WinampSkin.pauseButton, 2),
            (WinampSkin.stopButton, 3),
            (WinampSkin.nextButton, 4),
            (WinampSkin.ejectButton, 5)
        ]
        let transportActions: [() -> Void] = [
            { [weak self] in self?.onPrevious?() },
            { [weak self] in self?.onPlay?() },
            { [weak self] in self?.onPause?() },
            { [weak self] in self?.onStop?() },
            { [weak self] in self?.onNext?() },
            { [weak self] in self?.onEject?() }
        ]

        for (region, idx) in transportRegions {
            let r = CGRect(x: CGFloat(region.x), y: CGFloat(region.y),
                          width: CGFloat(region.width), height: CGFloat(region.height))
            let layerIdx = idx
            hitRegions.append(HitRegion(
                rect: r,
                onPress: nil,
                onDrag: nil,
                onRelease: { pt in
                    if r.contains(pt) {
                        transportActions[layerIdx]()
                    }
                },
                visualFeedback: { [weak self] pressed in
                    guard let self = self, let sp = self.sprites else { return }
                    self.transportButtonLayers[layerIdx].contents = pressed
                        ? sp.transportButtons[layerIdx].pressed
                        : sp.transportButtons[layerIdx].normal
                }
            ))
        }

        // Titlebar buttons
        addTitlebarHitRegion(WinampSkin.titleBarOptionsButton, optionsButtonLayer,
                             { [weak self] in self?.sprites?.titleBtnOptions },
                             { [weak self] in self?.onOptions?() })
        addTitlebarHitRegion(WinampSkin.titleBarMinimizeButton, minimizeButtonLayer,
                             { [weak self] in self?.sprites?.titleBtnMinimize },
                             { [weak self] in self?.onMinimize?() })
        addTitlebarHitRegion(WinampSkin.titleBarShadeButton, shadeButtonLayer,
                             { [weak self] in self?.sprites?.titleBtnShade },
                             { [weak self] in self?.onShade?() })
        addTitlebarHitRegion(WinampSkin.titleBarCloseButton, closeButtonLayer,
                             { [weak self] in self?.sprites?.titleBtnClose },
                             { [weak self] in self?.onClose?() })

        // Toggle buttons
        addToggleHitRegion(WinampSkin.shuffleButton, shuffleLayer, { [weak self] in self?.onShuffleToggle?() })
        addToggleHitRegion(WinampSkin.repeatButton, repeatLayer, { [weak self] in self?.onLoopCycle?() })
        addToggleHitRegion(WinampSkin.eqButton, eqLayer, { /* decorative */ })
        addToggleHitRegion(WinampSkin.plButton, plLayer, { [weak self] in self?.onPlaylistToggle?() })

        // Position bar drag region
        let posR = WinampSkin.positionBarRegion
        let posRect = CGRect(x: CGFloat(posR.x), y: CGFloat(posR.y),
                            width: CGFloat(posR.width), height: CGFloat(posR.height))
        hitRegions.append(HitRegion(
            rect: posRect,
            onPress: { [weak self] pt in self?.startPosDrag(at: pt) },
            onDrag: { [weak self] pt in self?.updatePosDrag(pt) },
            onRelease: { [weak self] _ in self?.endPosDrag() },
            visualFeedback: { [weak self] pressed in
                guard let self = self, let sp = self.sprites else { return }
                self.posThumbLayer.contents = pressed ? sp.posThumbPressed : sp.posThumbNormal
            }
        ))

        // Volume drag region
        let volR = WinampSkin.volumeBarRegion
        let volRect = CGRect(x: CGFloat(volR.x), y: CGFloat(volR.y) - 1,
                            width: CGFloat(volR.width), height: CGFloat(volR.height) + 2)
        hitRegions.append(HitRegion(
            rect: volRect,
            onPress: { [weak self] pt in self?.startVolumeDrag(at: pt) },
            onDrag: { [weak self] pt in self?.updateVolumeDrag(pt) },
            onRelease: { [weak self] _ in self?.endVolumeDrag() },
            visualFeedback: { [weak self] pressed in
                guard let self = self, let sp = self.sprites else { return }
                self.volumeThumbLayer.contents = pressed ? sp.volumeThumbPressed : sp.volumeThumbNormal
            }
        ))

        // Balance drag region (decorative — Roon has no balance control)
        let balR = WinampSkin.balanceBarRegion
        let balRect = CGRect(x: CGFloat(balR.x), y: CGFloat(balR.y) - 1,
                            width: CGFloat(balR.width), height: CGFloat(balR.height) + 2)
        hitRegions.append(HitRegion(
            rect: balRect,
            onPress: { [weak self] pt in self?.startBalanceDrag(at: pt) },
            onDrag: { [weak self] pt in self?.updateBalanceDrag(pt) },
            onRelease: { [weak self] _ in self?.endBalanceDrag() },
            visualFeedback: { [weak self] pressed in
                guard let self = self, let sp = self.sprites else { return }
                self.balanceThumbLayer.contents = pressed ? sp.balanceThumbPressed : sp.balanceThumbNormal
            }
        ))

        // Clutterbar hit region
        let clutterR = WinampSkin.clutterBarRegion
        let clutterRect = CGRect(x: CGFloat(clutterR.x + 3), y: CGFloat(clutterR.y),
                                 width: CGFloat(clutterR.width), height: CGFloat(clutterR.height))
        hitRegions.append(HitRegion(
            rect: clutterRect,
            onPress: nil,
            onDrag: nil,
            onRelease: { [weak self] pt in
                guard let self = self else { return }
                let localY = pt.y - CGFloat(clutterR.y)
                if localY >= 3 && localY < 11 { self.onOptions?() }
                else if localY >= 11 && localY < 18 { self.onAlwaysOnTopToggle?() }
                else if localY >= 18 && localY < 25 { self.onAlbumArtToggle?() }
                else if localY >= 25 && localY < 33 { self.onCycleScale?() }
                // V button (33-40) — no action
            },
            visualFeedback: nil
        ))

        // Visualizer tap region
        let visR = WinampSkin.visualizerRegion
        let visRect = CGRect(x: CGFloat(visR.x), y: CGFloat(visR.y),
                            width: CGFloat(visR.width), height: CGFloat(visR.height))
        hitRegions.append(HitRegion(
            rect: visRect,
            onPress: nil, onDrag: nil,
            onRelease: { [weak self] pt in
                if visRect.contains(pt) {
                    self?.onVisualizerTap?()
                }
            },
            visualFeedback: nil
        ))

        // Time display tap region
        let tR = WinampSkin.timeRegion
        let timeRect = CGRect(x: CGFloat(tR.x) - 20, y: CGFloat(tR.y),
                             width: CGFloat(tR.width) + 20, height: CGFloat(tR.height))
        hitRegions.append(HitRegion(
            rect: timeRect,
            onPress: nil, onDrag: nil,
            onRelease: { [weak self] pt in
                if timeRect.contains(pt) {
                    self?.onTimeDisplayTap?()
                }
            },
            visualFeedback: nil
        ))

        // Titlebar double-click for shade (handled separately in mouseDown)
    }

    private func addTitlebarHitRegion(_ region: WinampSkin.ButtonRegion, _ layer: CALayer,
                                       _ spriteGetter: @escaping () -> (normal: CGImage?, pressed: CGImage?)?,
                                       _ action: @escaping () -> Void) {
        let r = CGRect(x: CGFloat(region.x), y: CGFloat(region.y),
                      width: CGFloat(region.width), height: CGFloat(region.height))
        hitRegions.append(HitRegion(
            rect: r,
            onPress: nil,
            onDrag: nil,
            onRelease: { pt in
                if r.contains(pt) { action() }
            },
            visualFeedback: { pressed in
                guard let sp = spriteGetter() else { return }
                layer.contents = pressed ? sp.pressed : sp.normal
            }
        ))
    }

    private func addToggleHitRegion(_ region: WinampSkin.ButtonRegion, _ layer: CALayer,
                                     _ action: @escaping () -> Void) {
        let r = CGRect(x: CGFloat(region.x), y: CGFloat(region.y),
                      width: CGFloat(region.width), height: CGFloat(region.height))
        hitRegions.append(HitRegion(
            rect: r,
            onPress: nil, onDrag: nil,
            onRelease: { pt in
                if r.contains(pt) { action() }
            },
            visualFeedback: nil
        ))
    }

    // MARK: - Position Drag

    private func startPosDrag(at pt: CGPoint) {
        isDraggingPos = true
        updatePosDrag(pt)
    }

    private func updatePosDrag(_ pt: CGPoint) {
        let posR = WinampSkin.positionBarRegion
        let localX = pt.x - CGFloat(posR.x) - 14.5  // center of 29px thumb
        let maxX = CGFloat(posR.width) - 29
        let newProgress = max(0, min(1, localX / maxX))
        dragPosProgress = newProgress
        updatePositionThumb()
    }

    private func endPosDrag() {
        isDraggingPos = false
        pendingSeekProgress = dragPosProgress
        if let length = cachedLength, length > 0 {
            let newPosition = Int(dragPosProgress * Double(length))
            currentSeekPosition = newPosition
            localSeekPosition = newPosition
            lastUpdateTime = Date()
            onSeek?(newPosition)
        }
        updatePositionThumb()
    }

    private func currentPosProgress() -> Double {
        guard let length = cachedLength, length > 0 else { return 0 }
        let seekPos = cachedState == .playing ? currentSeekPosition : cachedSeekPosition
        return min(1.0, max(0.0, Double(seekPos) / Double(length)))
    }

    // MARK: - Volume Drag

    private func startVolumeDrag(at pt: CGPoint) {
        isDraggingVolume = true
        updateVolumeDrag(pt)
    }

    private func updateVolumeDrag(_ pt: CGPoint) {
        let volR = WinampSkin.volumeBarRegion
        let localX = pt.x - CGFloat(volR.x) - 7  // center of 14px thumb
        let maxX = CGFloat(volR.width) - 14
        let newProgress = max(0, min(1, localX / maxX))
        dragVolumeProgress = newProgress
        updateVolume()
    }

    private func endVolumeDrag() {
        isDraggingVolume = false
        onVolumeChange?(dragVolumeProgress)
    }

    private func startBalanceDrag(at pt: CGPoint) {
        isDraggingBalance = true
        updateBalanceDrag(pt)
    }

    private func updateBalanceDrag(_ pt: CGPoint) {
        let balR = WinampSkin.balanceBarRegion
        let localX = pt.x - CGFloat(balR.x) - 7  // center of 14px thumb
        let maxX = CGFloat(balR.width) - 14
        dragBalanceProgress = max(0, min(1, localX / maxX))
        updateBalance()
    }

    private func endBalanceDrag() {
        isDraggingBalance = false
    }

    // MARK: - NSView Mouse Events

    private var mouseDownPoint: CGPoint = .zero
    private var lastClickTime: CFTimeInterval = 0
    private var lastClickPoint: CGPoint = .zero

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let pt = convertToWinampCoords(event)
        mouseDownPoint = pt

        // Check for double-click on titlebar
        let now = CACurrentMediaTime()
        let tbR = WinampSkin.titleBarRegion
        let titlebarRect = CGRect(x: CGFloat(tbR.x), y: CGFloat(tbR.y),
                                   width: CGFloat(tbR.width), height: CGFloat(tbR.height))
        if titlebarRect.contains(pt) {
            if now - lastClickTime < 0.3 && abs(pt.x - lastClickPoint.x) < 5 && abs(pt.y - lastClickPoint.y) < 5 {
                // Double-click on titlebar — check it's not on a button
                let isOnButton = [WinampSkin.titleBarOptionsButton, WinampSkin.titleBarMinimizeButton,
                                  WinampSkin.titleBarShadeButton, WinampSkin.titleBarCloseButton].contains { region in
                    CGRect(x: CGFloat(region.x), y: CGFloat(region.y),
                          width: CGFloat(region.width), height: CGFloat(region.height)).contains(pt)
                }
                if !isOnButton {
                    onShade?()
                    lastClickTime = 0
                    return
                }
            }
            lastClickTime = now
            lastClickPoint = pt
        }

        // Hit test against regions
        for (index, region) in hitRegions.enumerated() {
            if region.rect.contains(pt) {
                pressedRegionIndex = index
                region.onPress?(pt)
                region.visualFeedback?(true)
                return
            }
        }

        // No hit region — initiate window drag
        pressedRegionIndex = nil
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = pressedRegionIndex else {
            super.mouseDragged(with: event)
            return
        }
        let pt = convertToWinampCoords(event)
        hitRegions[index].onDrag?(pt)
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = pressedRegionIndex else {
            super.mouseUp(with: event)
            return
        }
        let pt = convertToWinampCoords(event)
        hitRegions[index].visualFeedback?(false)
        hitRegions[index].onRelease?(pt)
        pressedRegionIndex = nil
    }

    private func convertToWinampCoords(_ event: NSEvent) -> CGPoint {
        let locationInView = convert(event.locationInWindow, from: nil)
        // isFlipped = true means y=0 is at top, matching Winamp coordinates
        let x = locationInView.x / scale
        let y = locationInView.y / scale
        return CGPoint(x: x, y: y)
    }

    // MARK: - Visualizer

    func updateVisualizer(colors: [Color], isPlaying: Bool, mode: VisualizerMode) {
        guard let visView = visualizerView else { return }
        let visR = WinampSkin.visualizerRegion

        // Check if colors changed
        var h = 0
        for c in colors {
            if let cg = NSColor(c).usingColorSpace(.sRGB) {
                h = h &* 31 &+ Int(cg.redComponent * 255) &+ Int(cg.greenComponent * 255) &* 17 &+ Int(cg.blueComponent * 255) &* 31
            }
        }
        if visView.colorHash != h {
            visView.colorHash = h
            visView.renderer = VisualizerRenderer(colors: colors, sourceWidth: visR.width,
                                                   sourceHeight: visR.height, barCount: 19, scale: scale)
        }
        visView.mode = mode
        visView.isPlaying = isPlaying
        visView.updateAnimation()
    }

    // MARK: - Cleanup

    func tearDown() {
        stopTimers()
        visualizerView?.stopRenderTimer()
    }

    deinit {
        stopTimers()
    }
}
