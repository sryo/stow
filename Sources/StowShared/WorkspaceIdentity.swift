import Foundation

/// Picks a color for a new workspace that is as far as possible, in hue, from the
/// workspaces that already exist. The choice is stored as a custom color, so existing
/// workspaces never shift when another is added or removed.
public enum WorkspaceColorAllocator {
    /// Lightness and chroma shared by every allocated color (OKLCH), so all of them
    /// carry the same ink and only hue tells them apart.
    static let lightness = 0.86
    static let chroma = 0.12

    public static func next(existing: [WorkspaceColorId], name: String = "") -> WorkspaceColorId {
        let hues = existing.compactMap { color -> Double? in
            guard color != .settingsBackground else { return nil }
            let lch = OKLCH(rgb: StowTheme.RGB(color.color))
            return lch.c > 0.03 ? lch.h : nil
        }
        // With nothing to avoid, start from a hue seeded by the name.
        var bestHue = Double(stableHash(name) % 360)
        if !hues.isEmpty {
            var bestDistance = -1.0
            for step in 0..<180 {
                let h = Double(step) * 2
                let d = hues.map { circularDistance(h, $0) }.min() ?? 360
                if d > bestDistance + 0.001 { bestDistance = d; bestHue = h }
            }
        }
        return .custom(OKLCH(l: lightness, c: chroma, h: bestHue).inGamutRGB().hex)
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    static func circularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// OKLCH ⇄ sRGB, enough for allocating hues.
struct OKLCH {
    var l: Double, c: Double, h: Double

    init(l: Double, c: Double, h: Double) { self.l = l; self.c = c; self.h = h }

    init(rgb: StowTheme.RGB) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(rgb.r), g = lin(rgb.g), b = lin(rgb.b)
        let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        l = L; c = sqrt(A * A + B * B)
        let deg = atan2(B, A) * 180 / .pi
        h = deg < 0 ? deg + 360 : deg
    }

    /// Converts to sRGB, lowering chroma until the color fits the gamut.
    func inGamutRGB() -> StowTheme.RGB {
        var chroma = c
        for _ in 0..<40 {
            if let rgb = toRGB(chroma: chroma) { return rgb }
            chroma *= 0.92
        }
        return toRGB(chroma: 0) ?? StowTheme.RGB(l, l, l)
    }

    private func toRGB(chroma: Double) -> StowTheme.RGB? {
        let A = chroma * cos(h * .pi / 180), B = chroma * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * A + 0.2158037573 * B
        let m_ = l - 0.1055613458 * A - 0.0638541728 * B
        let s_ = l - 0.0894841775 * A - 1.2914855480 * B
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let b = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func gamma(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let out = [r, g, b].map(gamma)
        guard out.allSatisfy({ $0 >= -0.0001 && $0 <= 1.0001 }) else { return nil }
        return StowTheme.RGB(out[0], out[1], out[2])
    }
}

extension AppModel {
    /// Creates a workspace with an automatically allocated, distinct color.
    @discardableResult
    public func createWorkspace(name: String) -> UUID {
        createWorkspace(name: name, colorId: WorkspaceColorAllocator.next(existing: workspaces.map(\.colorId), name: name))
    }
}

/// The sites that best represent a workspace, for its favicon icon: one per host,
/// skipping generic hosts (Google, YouTube, mail) when enough specific ones exist.
public enum WorkspaceIconSites {
    static let generic: Set<String> = [
        "google.com", "docs.google.com", "drive.google.com", "mail.google.com", "youtube.com",
        "gmail.com", "calendar.google.com", "github.com", "x.com", "twitter.com",
    ]

    public static func pick(from nodes: [Node], limit: Int = 4) -> [Link] {
        var specific: [Link] = [], common: [Link] = []
        var seen = Set<String>()
        for link in nodes.flattenLinks() where !link.isArchived {
            guard link.faviconPath != nil, let host = link.displayDomain, seen.insert(host).inserted else { continue }
            if generic.contains(host) { common.append(link) } else { specific.append(link) }
        }
        return Array((specific + common).prefix(limit))
    }
}
