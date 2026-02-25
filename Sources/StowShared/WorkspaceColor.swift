import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum WorkspaceColorId: Codable, Equatable, Hashable, Sendable {
    case ember
    case ruby
    case coral
    case tangerine
    case moss
    case ocean
    case indigo
    case graphite
    case settingsBackground
    case custom(String)

    public var name: String {
        switch self {
        case .ember: return "Blush"
        case .ruby: return "Apricot"
        case .coral: return "Butter"
        case .tangerine: return "Leaf"
        case .moss: return "Mint"
        case .ocean: return "Sky"
        case .indigo: return "Periwinkle"
        case .graphite: return "Lavender"
        case .settingsBackground: return "Settings"
        case .custom(let hex): return hex
        }
    }

    public var color: PlatformColor {
        switch self {
        case .ember: return PlatformColor(red: 1.00, green: 0.635, blue: 0.635, alpha: 1.0)
        case .ruby: return PlatformColor(red: 1.00, green: 0.722, blue: 0.416, alpha: 1.0)
        case .coral: return PlatformColor(red: 1.00, green: 0.941, blue: 0.522, alpha: 1.0)
        case .tangerine: return PlatformColor(red: 0.847, green: 0.976, blue: 0.600, alpha: 1.0)
        case .moss: return PlatformColor(red: 0.369, green: 0.914, blue: 0.710, alpha: 1.0)
        case .ocean: return PlatformColor(red: 0.325, green: 0.918, blue: 0.992, alpha: 1.0)
        case .indigo: return PlatformColor(red: 0.639, green: 0.702, blue: 1.00, alpha: 1.0)
        case .graphite: return PlatformColor(red: 0.855, green: 0.698, blue: 1.00, alpha: 1.0)
        case .settingsBackground: return PlatformColor(red: 0.898, green: 0.906, blue: 0.922, alpha: 1.0)
        case .custom(let hex): return PlatformColor(hex: hex) ?? WorkspaceColorId.ember.color
        }
    }

    public var backgroundColor: PlatformColor {
        if self == .settingsBackground {
            return color
        }
        return color.withAlphaComponent(0.92)
    }

    public var textColor: PlatformColor {
        PlatformColor.white
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "ember": self = .ember
        case "ruby": self = .ruby
        case "coral": self = .coral
        case "tangerine": self = .tangerine
        case "moss": self = .moss
        case "ocean": self = .ocean
        case "indigo": self = .indigo
        case "graphite": self = .graphite
        case "settingsBackground": self = .settingsBackground
        default:
            if value.hasPrefix("#") {
                self = .custom(value)
            } else {
                self = .ember
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ember: try container.encode("ember")
        case .ruby: try container.encode("ruby")
        case .coral: try container.encode("coral")
        case .tangerine: try container.encode("tangerine")
        case .moss: try container.encode("moss")
        case .ocean: try container.encode("ocean")
        case .indigo: try container.encode("indigo")
        case .graphite: try container.encode("graphite")
        case .settingsBackground: try container.encode("settingsBackground")
        case .custom(let hex): try container.encode(hex)
        }
    }
}

extension WorkspaceColorId {
    public static var allCases: [WorkspaceColorId] {
        [.ember, .ruby, .coral, .tangerine, .moss, .ocean, .indigo, .graphite]
    }

    public static func defaultColor() -> WorkspaceColorId { .ember }

    public static func randomColor() -> WorkspaceColorId {
        WorkspaceColorId.allCases.randomElement() ?? .defaultColor()
    }
}

extension PlatformColor {
    public convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }

    #if canImport(AppKit)
    public var hexString: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    #elseif canImport(UIKit)
    public var hexString: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    #endif
}

#if canImport(UIKit)
import UIKit

extension UIColor {
    /// Blends this color with another by the given fraction (0 = self, 1 = other).
    /// Mirrors NSColor.blended(withFraction:of:) for cross-platform parity.
    public func blended(withFraction fraction: CGFloat, of other: UIColor) -> UIColor? {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return nil }
        let f = max(0, min(1, fraction))
        return UIColor(
            red: r1 + (r2 - r1) * f,
            green: g1 + (g2 - g1) * f,
            blue: b1 + (b2 - b1) * f,
            alpha: a1 + (a2 - a1) * f
        )
    }
}
#endif
