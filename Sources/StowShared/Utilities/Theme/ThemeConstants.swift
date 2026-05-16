import Foundation
import QuartzCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Centralized design system constants for Stow.
///
/// `ThemeConstants` provides a single source of truth for all design values used throughout
/// the application. This ensures consistency and makes it easy to update the visual design
/// from a single location.
///
/// ## Structure
/// Constants are organized into nested structs by category:
/// - **Colors**: Brand colors and semantic color values
/// - **Opacity**: Standard opacity levels for layering and states
/// - **Fonts**: Typography with consistent sizing and weights
/// - **Spacing**: Standard spacing values for layout consistency
/// - **CornerRadius**: Rounding values for UI elements
/// - **Sizing**: Standard sizes for icons, buttons, and rows
/// - **Animation**: Timing values for smooth transitions
///
/// ## Design Philosophy
/// - Use semantic names that describe purpose, not specific values
/// - Provide a progression of values (e.g., tiny -> small -> medium -> large)
/// - Avoid magic numbers scattered throughout the codebase
/// - Make global design changes from a single file
public struct ThemeConstants {

    // MARK: - Colors

    /// Standard color palette for the application.
    public struct Colors {
        /// Primary dark color used for text, icons, and UI elements.
        /// Hex: #141414 | RGB: (20, 20, 20)
        public static let darkGray = PlatformColor(red: 0.078, green: 0.078, blue: 0.078, alpha: 1.0)

        /// Pure white used for light text and icons on dark backgrounds.
        public static let white = PlatformColor.white

        /// Light gray background used in settings and preferences views.
        /// Hex: #E5E7EB | RGB: (229, 231, 235)
        public static let settingsBackground = PlatformColor(red: 0.898, green: 0.906, blue: 0.922, alpha: 1.0)
    }

    // MARK: - Opacity

    /// Standard opacity levels for layering, hover states, and visual hierarchy.
    public struct Opacity {
        /// Fully opaque (1.0) - No transparency
        public static let full: CGFloat = 1.0

        /// High opacity (0.8) - Primary content with slight transparency
        public static let high: CGFloat = 0.8

        /// Medium opacity (0.6) - Secondary content
        public static let medium: CGFloat = 0.6

        /// Low opacity (0.4) - Tertiary content or disabled states
        public static let low: CGFloat = 0.4

        /// Subtle opacity (0.15) - Selected or focused backgrounds
        public static let subtle: CGFloat = 0.15

        /// Extra subtle opacity (0.10) - Very light backgrounds
        public static let extraSubtle: CGFloat = 0.10

        /// Minimal opacity (0.06) - Hover states with barely visible tint
        public static let minimal: CGFloat = 0.06
    }

    // MARK: - Typography

    /// Standard typography styles for text throughout the application.
    public struct Fonts {
        public static var bodyRegular: PlatformFont { .systemFont(ofSize: 14, weight: .regular) }
        public static var bodySemibold: PlatformFont { .systemFont(ofSize: 14, weight: .semibold) }
        public static var bodyMedium: PlatformFont { .systemFont(ofSize: 14, weight: .medium) }
        public static var bodyBold: PlatformFont { .systemFont(ofSize: 14, weight: .bold) }

        public static func systemFont(size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
            PlatformFont.systemFont(ofSize: size, weight: weight)
        }
    }

    // MARK: - Spacing

    /// Standard spacing values for consistent layout and padding.
    public struct Spacing {
        /// Tiny spacing (4pt) - Minimal gaps within compact components
        public static let tiny: CGFloat = 4

        /// Small spacing (6pt) - Tight spacing for related elements
        public static let small: CGFloat = 6

        /// Medium spacing (8pt) - Standard spacing within components
        public static let medium: CGFloat = 8

        /// Regular spacing (10pt) - Default spacing between elements
        public static let regular: CGFloat = 10

        /// Large spacing (14pt) - Comfortable spacing between groups
        public static let large: CGFloat = 14

        /// Extra large spacing (16pt) - Generous spacing for major sections
        public static let extraLarge: CGFloat = 16

        /// Huge spacing (20pt) - Maximum spacing for clear separation
        public static let huge: CGFloat = 20
    }

    // MARK: - Corner Radius

    /// Standard corner radius values for rounded UI elements.
    public struct CornerRadius {
        /// Small radius (6pt) - Subtle rounding for small elements
        public static let small: CGFloat = 6

        /// Medium radius (8pt) - Standard rounding for buttons and cards
        public static let medium: CGFloat = 8

        /// Large radius (12pt) - Prominent rounding for larger elements
        public static let large: CGFloat = 12

        /// Creates a perfectly round corner radius (half of the value).
        public static func round(_ value: CGFloat) -> CGFloat { value / 2 }
    }

    // MARK: - Sizing

    /// Standard sizing values for UI elements.
    public struct Sizing {
        /// Small icon size (14pt) - Compact icons for inline use
        public static let iconSmall: CGFloat = 14

        /// Medium icon size (18pt) - Standard icon size for most UI
        public static let iconMedium: CGFloat = 18

        /// Large icon size (22pt) - Prominent icons for primary actions
        public static let iconLarge: CGFloat = 22

        /// Extra large icon size (26pt) - Large icons for emphasis
        public static let iconExtraLarge: CGFloat = 26

        /// Standard button height (32pt)
        public static let buttonHeight: CGFloat = 32

        /// Standard row height (44pt) - For list and table rows
        public static let rowHeight: CGFloat = 44

        /// Height of overscroll shadow gradients (32pt)
        public static let scrollShadowHeight: CGFloat = 32

        /// Width of overscroll shadow gradients (32pt)
        public static let scrollShadowWidth: CGFloat = 32
    }

    // MARK: - Animation

    /// Standard animation timing values for smooth transitions.
    public struct Animation {
        /// Fast animation duration (0.15s) - Quick feedback for hover states
        public static let durationFast: TimeInterval = 0.15

        /// Normal animation duration (0.2s) - Standard transitions
        public static let durationNormal: TimeInterval = 0.2

        /// Slow animation duration (0.3s) - Deliberate, noticeable animations
        public static let durationSlow: TimeInterval = 0.3

        /// Standard easing function for smooth, natural motion (ease-in-ease-out).
        public static var timingFunction: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
    }

    // MARK: - Paging

    /// Constants for swipe page navigation (trackpad on macOS, gesture on iOS).
    public struct Paging {
        /// Movement threshold (in points) before locking direction as horizontal or vertical.
        public static let directionLockThreshold: CGFloat = 5.0

        /// Fraction of page width required to commit to a page change (0.15 = 15%).
        public static let pageChangeThreshold: CGFloat = 0.15

        /// Duration of the snap-to-page animation in seconds.
        public static let snapDuration: TimeInterval = 0.3

        /// If vertical delta exceeds horizontal delta by this ratio during horizontal tracking,
        /// the gesture is cancelled and snaps back.
        public static let crossAxisCancelRatio: CGFloat = 2.5

        /// Fraction of page width required to commit to the add-new page (45%).
        /// Higher than pageChangeThreshold to require more deliberate swipe.
        public static let addNewPageThreshold: CGFloat = 0.45
    }
}
