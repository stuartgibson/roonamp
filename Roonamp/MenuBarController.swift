//
//  MenuBarController.swift
//  Roonamp
//
//  Optional menu bar item showing the currently playing Roon track.
//  The item never grows past the user's configured maximum width — longer
//  text scrolls horizontally (with a pause at the start of each loop).
//

import AppKit
import Combine

// MARK: - Preferences

enum MenuBarPrefs {
    static let enabledKey = "menuBarEnabled"
    static let maxWidthKey = "menuBarMaxWidth"
    static let showTrackKey = "menuBarShowTrack"
    static let showArtistKey = "menuBarShowArtist"
    static let showAlbumKey = "menuBarShowAlbum"

    static let defaultMaxWidth: Double = 180
    static let minMaxWidth: Double = 80
    static let maxMaxWidth: Double = 500

    static let defaultShowTrack = true
    static let defaultShowArtist = true
    static let defaultShowAlbum = false

    /// Separator between the enabled parts of the menu bar title.
    static let partSeparator = " \u{2013} "

    /// Widest a now-playing row in the dropdown may draw, in points.
    static let menuInfoMaxWidth: CGFloat = 280

    /// Reads a Bool that defaults to `fallback` when it has never been written.
    static func bool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}

// MARK: - Scrolling text view

/// Shows a music-note glyph plus the now-playing text, clipped to the view's
/// width. When the text is wider than the available region it scrolls, looping
/// with a gap and pausing briefly each time it returns to the start.
///
/// The text is pre-rendered into a layer and scrolled by CoreAnimation rather
/// than redrawn per frame. A status item repaints through an offscreen
/// `renderInContext:` pass over its whole view tree, so dirtying this view at a
/// frame rate cost ~30% CPU no matter how cheap the drawing itself was. Nothing
/// here marks the view as needing display during a scroll.
final class MenuBarScrollingTextView: NSView {

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            measureText()
            updateWidth()
            rebuildContent()
        }
    }

    /// Maximum total width of the status item, in points.
    var maxWidth: CGFloat = CGFloat(MenuBarPrefs.defaultMaxWidth) {
        didSet {
            guard maxWidth != oldValue else { return }
            updateWidth()
            rebuildContent()
        }
    }

    /// Called whenever the desired status item width changes.
    var onWidthChange: ((CGFloat) -> Void)?

    /// Re-measures and pushes the current width to the status item. Needed once
    /// the view is installed, since the initial (empty) state changes nothing.
    func refreshLayout() {
        measureText()
        updateWidth()
        rebuildContent()
    }

    // Layout metrics
    private let iconSize: CGFloat = 14
    private let iconGap: CGFloat = 4
    private let leadingInset: CGFloat = 5
    private let trailingInset: CGFloat = 5
    /// Blank space between the end of the text and the start of the next loop.
    private let loopGap: CGFloat = 28

    // Scroll animation
    private let scrollSpeed: CGFloat = 24       // points per second
    private let startPause: CFTimeInterval = 1.5
    private static let scrollAnimationKey = "menuBarScroll"

    private var textWidth: CGFloat = 0
    private lazy var font: NSFont = .menuBarFont(ofSize: 13)

    // Symbol lookup and text layout are expensive enough to be worth keeping
    // across rebuilds; both depend only on the text and the appearance.
    private var cachedIcon: CGImage?
    private var cachedIconColor: NSColor?
    private var cachedAttributed: NSAttributedString?
    private var cachedAttributedText: String?
    private var cachedTextHeight: CGFloat = 0

    // Layers: the icon is static, the text scrolls inside a clipping layer.
    private let iconLayer = CALayer()
    private let textClipLayer = CALayer()
    private let textLayer = CALayer()

    /// Guards against reinstalling an identical animation on every layout pass,
    /// which would restart the scroll from the beginning each time.
    private var appliedContentKey: String?

    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for l in [iconLayer, textClipLayer, textLayer] {
            l.actions = ["contents": NSNull(), "position": NSNull(),
                         "bounds": NSNull(), "hidden": NSNull()]
        }
        iconLayer.contentsGravity = .resizeAspect
        textClipLayer.masksToBounds = true
        textLayer.contentsGravity = .resize
        textClipLayer.addSublayer(textLayer)
        layer?.addSublayer(iconLayer)
        layer?.addSublayer(textClipLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    /// Clicks must reach the status item button underneath so its menu opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopScrolling()
        } else {
            applyContentsScale()
            updateWidth()
            rebuildContent()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
        // The rendered image is resolution-dependent, so it has to be redone.
        appliedContentKey = nil
        rebuildContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // labelColor resolves differently under the new appearance, so both the
        // tinted icon and the rendered text are stale.
        cachedIcon = nil
        cachedIconColor = nil
        cachedAttributed = nil
        cachedAttributedText = nil
        appliedContentKey = nil
        rebuildContent()
    }

    private func applyContentsScale() {
        let s = window?.backingScaleFactor ?? 2
        iconLayer.contentsScale = s
        textLayer.contentsScale = s
        layer?.contentsScale = s
    }

    // MARK: Measurement

    private var textRegionWidth: CGFloat {
        max(0, desiredWidth - leadingInset - iconSize - iconGap - trailingInset)
    }

    private var contentWidth: CGFloat {
        if text.isEmpty {
            return leadingInset + iconSize + trailingInset
        }
        return leadingInset + iconSize + iconGap + textWidth + trailingInset
    }

    private var desiredWidth: CGFloat {
        min(contentWidth, max(maxWidth, leadingInset + iconSize + trailingInset))
    }

    private var isScrolling: Bool {
        !text.isEmpty && textWidth > textRegionWidth + 0.5
    }

    private func measureText() {
        guard !text.isEmpty else {
            textWidth = 0
            return
        }
        let size = (text as NSString).size(withAttributes: [.font: font])
        textWidth = ceil(size.width)
    }

    private func updateWidth() {
        onWidthChange?(ceil(desiredWidth))
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let iconY = ((bounds.height - iconSize) / 2).rounded()
        iconLayer.frame = CGRect(x: leadingInset, y: iconY, width: iconSize, height: iconSize)

        let originX = leadingInset + iconSize + iconGap
        textClipLayer.frame = CGRect(x: originX, y: 0,
                                     width: max(0, bounds.width - originX - trailingInset),
                                     height: bounds.height)
        // The clip width decides whether the text needs to scroll at all.
        rebuildContent()
    }

    // MARK: Content

    /// Renders the icon and text into their layers and installs (or clears) the
    /// scroll animation. Cheap to call repeatedly — it no-ops unless something
    /// that affects the rendered output actually changed.
    private func rebuildContent() {
        let color = NSColor.labelColor
        iconLayer.contents = icon(color: color)

        let clipWidth = textClipLayer.bounds.width
        let scrolling = isScrolling
        let key = "\(text)|\(scrolling)|\(clipWidth)|\(textLayer.contentsScale)"
        guard key != appliedContentKey else { return }
        appliedContentKey = key

        stopScrolling()

        guard !text.isEmpty, let attributed = attributedText(color: color) else {
            textLayer.contents = nil
            return
        }

        // A scrolling marquee draws the string twice, a gap apart, so that when
        // the first copy has travelled a full loop the second sits exactly where
        // it started and the wrap is invisible.
        let loopWidth = textWidth + loopGap
        let imageWidth = scrolling ? loopWidth + textWidth : textWidth
        let imageHeight = cachedTextHeight

        textLayer.contents = renderText(attributed,
                                        width: imageWidth,
                                        height: imageHeight,
                                        secondCopyAt: scrolling ? loopWidth : nil)
        let y = ((textClipLayer.bounds.height - imageHeight) / 2).rounded()
        textLayer.frame = CGRect(x: 0, y: y, width: imageWidth, height: imageHeight)

        guard scrolling else { return }
        startScrolling(loopWidth: loopWidth)
    }

    /// Composites the text (twice, when looping) into a single image so the
    /// scroll is a layer move rather than a redraw.
    private func renderText(_ attributed: NSAttributedString,
                            width: CGFloat,
                            height: CGFloat,
                            secondCopyAt: CGFloat?) -> CGImage? {
        let scale = textLayer.contentsScale
        let pxW = max(1, Int((width * scale).rounded(.up)))
        let pxH = max(1, Int((height * scale).rounded(.up)))
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.colorSpace,
                                  bitmapInfo: bitmapInfo) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // labelColor inside the attributed string was already resolved, but text
        // rendering still reads the current appearance for things like smoothing.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            attributed.draw(at: .zero)
            if let secondCopyAt {
                attributed.draw(at: CGPoint(x: secondCopyAt, y: 0))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: Animation

    /// One infinite keyframe animation: hold at the start for `startPause`, then
    /// travel one loop width at `scrollSpeed`. CoreAnimation runs this on the
    /// render server, so the app does no work per frame.
    private func startScrolling(loopWidth: CGFloat) {
        guard loopWidth > 0, scrollSpeed > 0 else { return }
        let travel = CFTimeInterval(loopWidth / scrollSpeed)
        let total = startPause + travel
        let base = textLayer.position.x

        let anim = CAKeyframeAnimation(keyPath: "position.x")
        anim.values = [base, base, base - loopWidth]
        anim.keyTimes = [0, NSNumber(value: startPause / total), 1]
        anim.duration = total
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        textLayer.add(anim, forKey: Self.scrollAnimationKey)
    }

    private func stopScrolling() {
        textLayer.removeAnimation(forKey: Self.scrollAnimationKey)
    }

    // MARK: Cached pieces

    private func icon(color: NSColor) -> CGImage? {
        if let cachedIcon, cachedIconColor == color { return cachedIcon }
        guard let base = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Roonamp") else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let tinted = base.withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        let cg = tinted.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        cachedIcon = cg
        cachedIconColor = color
        return cg
    }

    private func attributedText(color: NSColor) -> NSAttributedString? {
        if let cachedAttributed, cachedAttributedText == text { return cachedAttributed }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        cachedAttributed = attributed
        cachedAttributedText = text
        cachedTextHeight = ceil(attributed.size().height)
        return attributed
    }
}

// MARK: - Controller

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private let textView = MenuBarScrollingTextView()
    private weak var roonAPI: RoonAPI?
    private var playback: PlaybackState?
    private var cancellables = Set<AnyCancellable>()
    private var defaultsObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    /// Called once the SwiftUI scene has its RoonAPI instance.
    func configure(roonAPI: RoonAPI) {
        guard self.roonAPI == nil else { return }
        self.roonAPI = roonAPI
        self.playback = roonAPI.playback

        roonAPI.playback.$nowPlaying
            .combineLatest(roonAPI.playback.$state)
            .sink { [weak self] _, _ in
                self?.refreshText()
            }
            .store(in: &cancellables)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MenuBarController.shared.applyPreferences()
            }
        }

        applyPreferences()
    }

    // MARK: Preferences

    private func applyPreferences() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: MenuBarPrefs.enabledKey)
        let stored = defaults.object(forKey: MenuBarPrefs.maxWidthKey) as? Double
            ?? MenuBarPrefs.defaultMaxWidth
        let width = min(max(stored, MenuBarPrefs.minMaxWidth), MenuBarPrefs.maxMaxWidth)

        textView.maxWidth = CGFloat(width)

        if enabled {
            installStatusItem()
            refreshText()
        } else {
            removeStatusItem()
        }
    }

    // MARK: Status item

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        textView.onWidthChange = { [weak item] width in
            item?.length = width
        }

        if let button = item.button {
            button.title = ""
            button.image = nil
            textView.frame = button.bounds
            textView.autoresizingMask = [.width, .height]
            button.addSubview(textView)
        }

        let menu = NSMenu()
        menu.delegate = self
        // We set `isEnabled` on every item ourselves; automatic validation would
        // override those flags (it enables anything whose target responds to the
        // action, which re-enables Play/Prev/Next with no zone connected).
        menu.autoenablesItems = false
        item.menu = menu

        statusItem = item
        refreshText()
        textView.refreshLayout()
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        textView.onWidthChange = nil
        textView.removeFromSuperview()
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    // MARK: Content

    private func refreshText() {
        guard statusItem != nil else { return }
        guard let np = playback?.nowPlaying else {
            textView.text = ""
            return
        }
        var parts: [String] = []
        if MenuBarPrefs.bool(MenuBarPrefs.showArtistKey, default: MenuBarPrefs.defaultShowArtist) {
            parts.append(np.artist)
        }
        if MenuBarPrefs.bool(MenuBarPrefs.showAlbumKey, default: MenuBarPrefs.defaultShowAlbum) {
            parts.append(np.album)
        }
        if MenuBarPrefs.bool(MenuBarPrefs.showTrackKey, default: MenuBarPrefs.defaultShowTrack) {
            parts.append(np.title)
        }

        // Empty fields are dropped so a missing album never leaves a dangling
        // separator. With every part switched off the item is icon-only.
        textView.text = parts
            .filter { !$0.isEmpty }
            .joined(separator: MenuBarPrefs.partSeparator)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let np = playback?.nowPlaying {
            menu.addItem(infoItem(np.title, copyable: true))
            if !np.artist.isEmpty {
                menu.addItem(infoItem(np.artist, copyable: true))
            }
            if !np.album.isEmpty {
                menu.addItem(infoItem(np.album, copyable: true))
            }
        } else {
            menu.addItem(infoItem("Nothing Playing"))
        }

        if let zone = playback?.displayName {
            menu.addItem(infoItem("Output: \(zone)"))
        }

        menu.addItem(.separator())

        let isPlaying = playback?.state == .playing
        add(to: menu, title: isPlaying ? "Pause" : "Play",
            action: #selector(togglePlayPause), enabled: playback?.zoneId != nil)
        add(to: menu, title: "Previous",
            action: #selector(previousTrack), enabled: playback?.zoneId != nil)
        add(to: menu, title: "Next",
            action: #selector(nextTrack), enabled: playback?.zoneId != nil)

        menu.addItem(.separator())
        add(to: menu, title: "Show Main Window", action: #selector(showMainWindow), enabled: true)
        add(to: menu, title: "Settings…", action: #selector(showSettings), enabled: true)

        menu.addItem(.separator())
        add(to: menu, title: "Quit Roonamp", action: #selector(quit), enabled: true)
    }

    /// A now-playing row. When `copyable`, clicking it puts the full untruncated
    /// text on the pasteboard; otherwise the row is inert (zone name, placeholder).
    private func infoItem(_ title: String, copyable: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: copyable ? #selector(copyInfo(_:)) : nil,
                              keyEquivalent: "")
        // `ofSize: 0` is the standard menu font size, matching the action items.
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        // An explicit colour is what keeps an inert row from rendering in the
        // washed-out disabled grey. Copyable rows omit it so AppKit can swap in
        // white when the row is highlighted.
        if !copyable { attrs[.foregroundColor] = NSColor.labelColor }

        // Menu items size to fit their title, so an unbounded string (classical
        // recordings can list half a dozen performers) drags every row in the
        // dropdown out with it. Clip to a fixed width and keep the full text on
        // the tooltip.
        let shown = Self.truncate(title, attributes: attrs, maxWidth: MenuBarPrefs.menuInfoMaxWidth)
        item.attributedTitle = NSAttributedString(string: shown, attributes: attrs)

        if copyable {
            item.target = self
            item.representedObject = title
            item.isEnabled = true
            item.toolTip = "Copy \u{201C}\(title)\u{201D}"
        } else {
            item.isEnabled = false
            if shown != title { item.toolTip = title }
        }
        return item
    }

    /// Trims `text` until it fits `maxWidth`, appending an ellipsis. Measures the
    /// rendered string rather than counting characters so proportional fonts and
    /// wide scripts land in the right place.
    private static func truncate(_ text: String,
                                 attributes: [NSAttributedString.Key: Any],
                                 maxWidth: CGFloat) -> String {
        func width(_ s: String) -> CGFloat {
            NSAttributedString(string: s, attributes: attributes).size().width
        }
        guard width(text) > maxWidth else { return text }

        let chars = Array(text)
        // Largest prefix whose text-plus-ellipsis still fits.
        var low = 0, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            if width(String(chars[0..<mid]) + "\u{2026}") <= maxWidth {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let kept = String(chars[0..<low])
            .trimmingCharacters(in: .whitespaces)
            // A cut that lands right after a separator reads as a typo.
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;-/&"))
            .trimmingCharacters(in: .whitespaces)
        return kept + "\u{2026}"
    }

    private func add(to menu: NSMenu, title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func togglePlayPause() {
        guard let api = roonAPI, let zoneId = playback?.zoneId else { return }
        Task { await api.playPause(zoneId: zoneId) }
    }

    @objc private func nextTrack() {
        guard let api = roonAPI, let zoneId = playback?.zoneId else { return }
        Task { await api.next(zoneId: zoneId) }
    }

    @objc private func previousTrack() {
        guard let api = roonAPI, let zoneId = playback?.zoneId else { return }
        Task { await api.previous(zoneId: zoneId) }
    }

    @objc private func copyInfo(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        WinampWindow.current?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Routed through the SwiftUI scene's `openSettings` action rather than
        // `NSApp.sendAction(showSettingsWindow:)` — the selector lookup walks the
        // responder chain and finds no target while the menu is still tracking
        // (and immediately after `activate`, before a key window exists).
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
