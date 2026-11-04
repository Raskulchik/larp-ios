import SwiftUI

/// Adds the native Liquid Glass treatment on iOS 26 and a matching material on older systems.
struct AdaptiveGlass: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(AdaptiveGlass(cornerRadius: cornerRadius))
    }
}
