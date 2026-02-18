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
    @Published var zoneId: String?
    @Published var displayName: String?

    /// Seek position updated at high frequency — NOT @Published to avoid
    /// re-evaluating views that don't need it (AlbumArtView, ContentView).
    /// Views that display seek position subscribe via `seekPositionPublisher`.
    var seekPosition: Int = 0 {
        didSet {
            if seekPosition != oldValue {
                seekPositionSubject.send(seekPosition)
            }
        }
    }
    let seekPositionSubject = PassthroughSubject<Int, Never>()

    /// Throttled to 1 Hz — views interpolate between ticks so higher
    /// frequency just wastes SwiftUI update cycles.
    lazy var seekPositionPublisher: AnyPublisher<Int, Never> = {
        seekPositionSubject
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
    }()
}
