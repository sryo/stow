import AppKit

enum WorkspaceColorId: Codable, Equatable, Hashable {
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

    var name: String {
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

    var color: NSColor {
        switch self {
        case .ember: return NSColor(calibratedRed: 1.00, green: 0.635, blue: 0.635, alpha: 1.0)
        case .ruby: return NSColor(calibratedRed: 1.00, green: 0.722, blue: 0.416, alpha: 1.0)
        case .coral: return NSColor(calibratedRed: 1.00, green: 0.941, blue: 0.522, alpha: 1.0)
        case .tangerine: return NSColor(calibratedRed: 0.847, green: 0.976, blue: 0.600, alpha: 1.0)
        case .moss: return NSColor(calibratedRed: 0.369, green: 0.914, blue: 0.710, alpha: 1.0)
        case .ocean: return NSColor(calibratedRed: 0.325, green: 0.918, blue: 0.992, alpha: 1.0)
        case .indigo: return NSColor(calibratedRed: 0.639, green: 0.702, blue: 1.00, alpha: 1.0)
        case .graphite: return NSColor(calibratedRed: 0.855, green: 0.698, blue: 1.00, alpha: 1.0)
        case .settingsBackground: return NSColor(calibratedRed: 0.898, green: 0.906, blue: 0.922, alpha: 1.0)
        case .custom(let hex): return NSColor(hex: hex) ?? WorkspaceColorId.ember.color
        }
    }

    var backgroundColor: NSColor {
        if self == .settingsBackground {
            return color
        }
        return color.withAlphaComponent(0.92)
    }

    var textColor: NSColor {
        NSColor.white
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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
    static var allCases: [WorkspaceColorId] {
        [.ember, .ruby, .coral, .tangerine, .moss, .ocean, .indigo, .graphite]
    }

    static func defaultColor() -> WorkspaceColorId { .ember }

    static func randomColor() -> WorkspaceColorId {
        WorkspaceColorId.allCases.randomElement() ?? .defaultColor()
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    var hexString: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
