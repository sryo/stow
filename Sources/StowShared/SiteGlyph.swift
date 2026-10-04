import Foundation

/// The letter tile a site shows when it has no favicon: one or two letters on a color
/// picked from the host. The rail, Tabline, list, mosaic and iPhone all draw it from here,
/// so a site looks the same everywhere.
public enum SiteGlyph {
    private static let tileColors = ["#5E6AD2", "#24292F", "#0A84FF", "#A259FF", "#1A73E8", "#5B3F8C",
                                     "#4A154B", "#2684FC", "#D93025", "#188038", "#C2410C", "#D99A00",
                                     "#FF6600", "#B31B1B", "#635BFF", "#0F8F86"]

    /// The lowercased host without a leading "www.", or "" when the string has no host.
    public static func host(of urlString: String) -> String {
        normalizedHost(URL(string: urlString)?.host ?? "")
    }

    /// Lowercases a bare host and drops a leading "www.".
    public static func normalizedHost(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The tile color for a host from `host(of:)`. djb2 keeps it stable across launches and devices.
    public static func tileRGB(for host: String) -> StowTheme.RGB {
        var hash: UInt64 = 5381
        for byte in host.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return StowTheme.RGB(hex: tileColors[Int(hash % UInt64(tileColors.count))])!
    }

    public static func tileColor(for host: String) -> PlatformColor {
        tileRGB(for: host).platformColor
    }

    /// The letters for one site on its own: the capitals of a camel-cased name (GitHub "GH"),
    /// else its first letter.
    public static func letters(title: String, host: String) -> String {
        let n = name(title: title, host: host)
        let caps = n.filter(\.isUppercase)
        if caps.count >= 2 { return String(caps.prefix(2)) }
        return n.first.map { String($0).uppercased() } ?? "•"
    }

    /// Kept for callers that ask for a single letter; same as `letters(title:host:)`.
    public static func letter(title: String, host: String) -> String {
        letters(title: title, host: host)
    }

    /// Letters for sites shown side by side: as `letters(title:host:)`, except that two sites
    /// sharing a first letter get two (Linear "Li" next to LinkedIn "Li", Figma "F" stays).
    public static func assignLetters(_ links: [Link]) -> [UUID: String] {
        let names = links.map { name(title: $0.title, host: host(of: $0.url)) }
        var firsts: [String: Int] = [:]
        for n in names { firsts[String(n.prefix(1)).uppercased(), default: 0] += 1 }
        var result: [UUID: String] = [:]
        for (link, n) in zip(links, names) {
            if n.filter(\.isUppercase).count < 2, firsts[String(n.prefix(1)).uppercased(), default: 0] > 1 {
                result[link.id] = String(n.prefix(1)).uppercased() + String(n.dropFirst().prefix(1)).lowercased()
            } else {
                result[link.id] = letters(title: link.title, host: host(of: link.url))
            }
        }
        return result
    }

    /// The title's first word when it names the site, else the host's first label.
    private static func name(title: String, host: String) -> String {
        let word = title.split(separator: " ").first.map(String.init) ?? ""
        let trimmed = word.drop { !($0.isLetter || $0.isNumber) }
        if !trimmed.isEmpty { return String(trimmed) }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}
