//
//  PlaybackState.swift
//  Roonamp
//
//  Focused ObservableObject for playback display data.
//  Views that only need playback info observe this instead of RoonAPI,
//  avoiding unnecessary re-evaluation when unrelated properties change.
//

import Foundation
import Combine

@MainActor
class PlaybackState: ObservableObject {
    @Published var state: RoonZone.PlaybackState?
    @Published var nowPlaying: NowPlaying?
    @Published var seekPosition: Int = 0
    @Published var zoneId: String?
    @Published var displayName: String?
}
