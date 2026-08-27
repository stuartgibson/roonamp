//
//  RoonampApp.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import SwiftUI

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared reference set once the SwiftUI scene's skinManager is available.
    nonisolated(unsafe) static var sharedSkinManager: WinampSkinManager?

    override init() {
        super.init()
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register our own handler for open-document Apple Events BEFORE SwiftUI
        // installs its handler. This prevents SwiftUI from spawning a new window.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WinampWindow.current?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        for i in 1...directObject.numberOfItems {
            guard let urlString = directObject.atIndex(i)?.stringValue,
                  let url = URL(string: urlString),
                  url.pathExtension.lowercased() == "wsz" else { continue }
            try? AppDelegate.sharedSkinManager?.importSkin(from: url)
            return
        }
    }
}
#endif

@main
struct RoonampApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    @StateObject private var roonAPI = RoonAPI(
        appInfo: RoonAppInfo(
            extensionId: "com.yourcompany.roonamp",
            displayName: "Roonamp",
            displayVersion: "1.0.0",
            publisher: "Your Name",
            email: "your.email@example.com"
        )
    )
    @StateObject private var skinManager = WinampSkinManager()

    @State private var showAlbumArt = false
    @AppStorage("windowScale") private var windowScale: Double = 2.0
    @AppStorage(MenuBarPrefs.enabledKey) private var menuBarEnabled: Bool = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            Group {
                if let skin = skinManager.currentSkin {
                    WinampMainBridge(skin: skin)
                        .environmentObject(roonAPI)
                        .environmentObject(roonAPI.playback)
                        .environmentObject(skinManager)
                } else {
                    ContentView(showAlbumArt: $showAlbumArt)
                        .environmentObject(roonAPI)
                        .environmentObject(roonAPI.playback)
                        .environmentObject(skinManager)
                }
            }
            .onAppear {
                AppDelegate.sharedSkinManager = skinManager
                MenuBarController.shared.configure(roonAPI: roonAPI)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Show Main Window") {
                    WinampWindow.current?.makeKeyAndOrderFront(nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Show Album Art") {
                    roonAPI.isAlbumArtVisible = true
                    openWindow(id: "album-art", value: true)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Show Playlist") {
                    roonAPI.isPlaylistVisible = true
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
                }
                .keyboardShortcut("3", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Always on Top", isOn: $roonAPI.alwaysOnTop)
                    .keyboardShortcut("t", modifiers: .command)

                Toggle("Show in Menu Bar", isOn: $menuBarEnabled)

                Button("Cycle Size (1x / 1.5x / 2x)") {
                    switch windowScale {
                    case 1.0: windowScale = 1.5
                    case 1.5: windowScale = 2.0
                    default: windowScale = 1.0
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }

        WindowGroup("Album Art", id: "album-art", for: Bool.self) { $isShowing in
            AlbumArtView()
                .environmentObject(roonAPI.playback)
                .onAppear {
                    showAlbumArt = true
                    roonAPI.isAlbumArtVisible = true
                }
                .onDisappear {
                    showAlbumArt = false
                    roonAPI.isAlbumArtVisible = false
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 400)

        WindowGroup("Playlist", id: "playlist", for: Bool.self) { $isShowing in
            if let skin = skinManager.currentSkin {
                WinampPlaylistView(skin: skin)
                    .environmentObject(roonAPI)
                    .environmentObject(roonAPI.playback)
                    .environmentObject(skinManager)
                    .onDisappear {
                        roonAPI.isPlaylistVisible = false
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(roonAPI)
                .environmentObject(skinManager)
        }
        #endif
    }
}
