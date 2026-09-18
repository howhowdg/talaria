import SwiftUI

/// Fixed Mac typography; iOS continues to follow Dynamic Type.
enum TalariaTypography {
    static var largeTitle: Font {
        #if os(macOS)
        .system(size: 25, weight: .regular)
        #else
        .largeTitle
        #endif
    }
    static var title: Font {
        #if os(macOS)
        .system(size: 23, weight: .regular)
        #else
        .title
        #endif
    }
    static var title2: Font {
        #if os(macOS)
        .system(size: 19, weight: .regular)
        #else
        .title2
        #endif
    }
    static var title3: Font {
        #if os(macOS)
        .system(size: 15, weight: .regular)
        #else
        .title3
        #endif
    }
    static var headline: Font {
        #if os(macOS)
        .system(size: 12.5, weight: .semibold)
        #else
        .headline
        #endif
    }
    static var body: Font {
        #if os(macOS)
        .system(size: 12.5, weight: .regular)
        #else
        .body
        #endif
    }
    static var callout: Font {
        #if os(macOS)
        .system(size: 11, weight: .regular)
        #else
        .callout
        #endif
    }
    static var caption: Font {
        #if os(macOS)
        .system(size: 10.5, weight: .regular)
        #else
        .caption
        #endif
    }
    static var caption2: Font {
        #if os(macOS)
        .system(size: 10, weight: .regular)
        #else
        .caption2
        #endif
    }
    static var subheadline: Font {
        #if os(macOS)
        .system(size: 11.5, weight: .regular)
        #else
        .subheadline
        #endif
    }
    static var footnote: Font {
        #if os(macOS)
        .system(size: 10, weight: .regular)
        #else
        .footnote
        #endif
    }
}
