//
//  RoonImageCache.swift
//  Roonamp
//
//  Constructs image URLs pointing directly at Roon Core's HTTP image endpoint.
//

import Foundation

struct RoonImageCache {
    var coreIP: String?
    var corePort: Int?

    func imageURL(for key: String, width: Int = 600, height: Int = 600) -> String? {
        guard let ip = coreIP, let port = corePort else { return nil }
        return "http://\(ip):\(port)/api/image/\(key)?scale=fit&width=\(width)&height=\(height)&format=image/jpeg"
    }
}
