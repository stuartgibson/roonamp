//
//  WinampSkin.swift
//  Roonamp
//
//  Created by Stuart Gibson on 12/02/2026.
//

import Foundation
import SwiftUI

/// Playlist editor colors from pledit.txt
struct PlaylistColors: Equatable {
    let normal: Color       // Normal text color
    let current: Color      // Currently playing text color
    let normalBG: Color     // Normal background color
    let selectedBG: Color   // Selected item background color
    let font: String        // Font name

    static let `default` = PlaylistColors(
        normal: Color(red: 0/255, green: 255/255, blue: 0/255),
        current: Color(red: 255/255, green: 255/255, blue: 255/255),
        normalBG: Color(red: 0/255, green: 0/255, blue: 0/255),
        selectedBG: Color(red: 0/255, green: 0/255, blue: 198/255),
        font: "Arial"
    )
}

/// Represents a Winamp 2.x skin
struct WinampSkin {
    let name: String
    let sourceURL: URL?
    var mainWindowBitmap: NSImage?      // main.bmp
    let titleBarBitmap: NSImage?        // titlebar.bmp
    var playPauseBitmap: NSImage?       // cbuttons.bmp (control buttons)
    var positionBarBitmap: NSImage?     // posbar.bmp
    var volumeBitmap: NSImage?          // volume.bmp
    var playpausBitmap: NSImage?        // playpaus.bmp
    let textBitmap: NSImage?            // text.bmp
    var numbersBitmap: NSImage?         // numbers.bmp
    var monosterBitmap: NSImage?        // monoster.bmp
    var shuffleRepeatBitmap: NSImage?   // shufrep.bmp
    var balanceBitmap: NSImage?          // balance.bmp
    let visColors: [Color]               // viscolor.txt (24 colors)
    let normalRegion: [[CGPoint]]?       // region.txt [Normal] polygons
    let windowShadeRegion: [[CGPoint]]?  // region.txt [WindowShade] polygons
    let playlistBitmap: NSImage?         // pledit.bmp
    let playlistColors: PlaylistColors   // pledit.txt

    // Button coordinates based on Winamp 2.x standard layout
    // Main window is 275x116 pixels
    struct ButtonRegion {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    
    // Title bar area
    static let titleBarRegion = ButtonRegion(x: 0, y: 0, width: 275, height: 14)

    // Title bar buttons (all 9x9)
    static let titleBarOptionsButton = ButtonRegion(x: 6, y: 3, width: 9, height: 9)
    static let titleBarMinimizeButton = ButtonRegion(x: 244, y: 3, width: 9, height: 9)
    static let titleBarShadeButton = ButtonRegion(x: 254, y: 3, width: 9, height: 9)
    static let titleBarCloseButton = ButtonRegion(x: 264, y: 3, width: 9, height: 9)

    // Standard Winamp button positions
    static let previousButton = ButtonRegion(x: 16, y: 88, width: 23, height: 18)
    static let playButton = ButtonRegion(x: 39, y: 88, width: 23, height: 18)
    static let pauseButton = ButtonRegion(x: 62, y: 88, width: 23, height: 18)
    static let stopButton = ButtonRegion(x: 85, y: 88, width: 23, height: 18)
    static let nextButton = ButtonRegion(x: 108, y: 88, width: 22, height: 18)
    static let ejectButton = ButtonRegion(x: 136, y: 89, width: 22, height: 16)
    static let shuffleButton = ButtonRegion(x: 164, y: 89, width: 47, height: 15)
    static let repeatButton = ButtonRegion(x: 211, y: 89, width: 28, height: 15)
    
    // Title display area
    static let titleRegion = ButtonRegion(x: 111, y: 27, width: 153, height: 13)
    
    // Play/pause status indicator
    static let workGreenRegion = ButtonRegion(x: 24, y: 28, width: 3, height: 3)
    static let workRedRegion = ButtonRegion(x: 24, y: 34, width: 3, height: 3)
    static let playPausIndicatorRegion = ButtonRegion(x: 26, y: 28, width: 9, height: 9)

    // Time display area
    static let timeRegion = ButtonRegion(x: 51, y: 26, width: 59, height: 13)
    
    // Info display (bitrate and sample rate)
    static let kbpsRegion = ButtonRegion(x: 111, y: 43, width: 15, height: 6)
    static let kHzRegion = ButtonRegion(x: 156, y: 43, width: 10, height: 6)

    // Mono/Stereo indicator
    static let monoStereoRegion = ButtonRegion(x: 210, y: 41, width: 58, height: 12)

    // Position slider (seek bar)
    static let positionBarRegion = ButtonRegion(x: 16, y: 72, width: 248, height: 10)

    // Volume and balance sliders
    static let volumeBarRegion = ButtonRegion(x: 107, y: 58, width: 68, height: 13)
    static let balanceBarRegion = ButtonRegion(x: 177, y: 58, width: 38, height: 13)

    // Visualizer area
    static let visualizerRegion = ButtonRegion(x: 24, y: 43, width: 76, height: 16)

    // Clutterbar (O, A, I, D, V buttons)
    static let clutterBarRegion = ButtonRegion(x: 10, y: 22, width: 8, height: 43)

    // EQ and PL buttons
    static let eqButton = ButtonRegion(x: 219, y: 57, width: 23, height: 12)
    static let plButton = ButtonRegion(x: 242, y: 57, width: 23, height: 12)

    // MARK: - Windowshade Mode
    static let windowShadeHeight = 14

    // Windowshade transport buttons (within the 275x14 bar)
    static let wsPreviousButton = ButtonRegion(x: 169, y: 2, width: 7, height: 10)
    static let wsPlayButton = ButtonRegion(x: 176, y: 2, width: 10, height: 10)
    static let wsPauseButton = ButtonRegion(x: 186, y: 2, width: 9, height: 10)
    static let wsStopButton = ButtonRegion(x: 195, y: 2, width: 9, height: 10)
    static let wsNextButton = ButtonRegion(x: 204, y: 2, width: 10, height: 10)
    static let wsEjectButton = ButtonRegion(x: 215, y: 2, width: 10, height: 10)

    // Windowshade position bar
    static let wsPositionBarRegion = ButtonRegion(x: 226, y: 4, width: 17, height: 7)

    // Windowshade window control buttons
    static let wsMinimizeButton = ButtonRegion(x: 244, y: 3, width: 9, height: 9)
    static let wsUnshadeButton = ButtonRegion(x: 254, y: 3, width: 9, height: 9)
    static let wsCloseButton = ButtonRegion(x: 264, y: 3, width: 9, height: 9)

    // Windowshade visualizer area (first dark rectangle)
    static let wsVisualizerRegion = ButtonRegion(x: 78, y: 4, width: 40, height: 7)

    // Windowshade time display (second dark rectangle)
    static let wsTimeRegion = ButtonRegion(x: 139, y: 4, width: 19, height: 6)

    // MARK: - Playlist Window (PLEDIT.BMP layout)

    // Dimensions
    static let playlistTitleBarHeight = 20
    static let playlistBottomHeight = 38
    static let playlistLeftWidth = 12
    static let playlistRightWidth = 20
    static let playlistTrackRowHeight = 13
    static let playlistMinWidth = 275
    static let playlistMinHeight = 116
    static let playlistResizeIncrementX = 25
    static let playlistResizeIncrementY = 29

    // Titlebar sprites (y=0 active, y=21 inactive)
    static let plTitleBarLeftCorner = ButtonRegion(x: 0, y: 0, width: 25, height: 20)
    static let plTitleBarTitle = ButtonRegion(x: 26, y: 0, width: 100, height: 20)
    static let plTitleBarTile = ButtonRegion(x: 127, y: 0, width: 25, height: 20)
    static let plTitleBarRightCorner = ButtonRegion(x: 153, y: 0, width: 25, height: 20)

    // Left/right side tiles
    static let plLeftTile = ButtonRegion(x: 0, y: 42, width: 12, height: 29)
    static let plRightTile = ButtonRegion(x: 31, y: 42, width: 20, height: 29)

    // Bottom bar
    static let plBottomLeft = ButtonRegion(x: 0, y: 72, width: 125, height: 38)
    static let plBottomRight = ButtonRegion(x: 126, y: 72, width: 150, height: 38)
    static let plBottomTile = ButtonRegion(x: 179, y: 0, width: 25, height: 38)

    // Scrollbar handle
    static let plScrollHandleNormal = ButtonRegion(x: 52, y: 53, width: 8, height: 18)
    static let plScrollHandlePressed = ButtonRegion(x: 61, y: 53, width: 8, height: 18)

    // Close button in titlebar (top-right area of right corner sprite)
    static let plCloseButton = ButtonRegion(x: 167, y: 3, width: 9, height: 9)
    static let plCloseButtonPressed = ButtonRegion(x: 52, y: 42, width: 9, height: 9)

    // Shade button in titlebar (left of close button)
    static let plShadeButton = ButtonRegion(x: 158, y: 3, width: 9, height: 9)

    // MARK: - Playlist Windowshade Mode
    static let playlistShadeHeight = 14

    // Shade bar sprites (from PLEDIT.BMP)
    static let plShadeLeft = ButtonRegion(x: 72, y: 42, width: 25, height: 14)
    static let plShadeTile = ButtonRegion(x: 72, y: 57, width: 25, height: 14)
    static let plShadeRightActive = ButtonRegion(x: 99, y: 42, width: 50, height: 14)
    static let plShadeRightInactive = ButtonRegion(x: 99, y: 57, width: 50, height: 14)

    // Shade bar button pressed states
    static let plShadeClosePressed = ButtonRegion(x: 52, y: 42, width: 9, height: 9)
    static let plShadeCollapsePressed = ButtonRegion(x: 62, y: 42, width: 9, height: 9)
    static let plShadeExpandPressed = ButtonRegion(x: 150, y: 42, width: 9, height: 9)
}
