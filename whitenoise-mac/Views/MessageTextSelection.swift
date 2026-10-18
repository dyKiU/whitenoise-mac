import SwiftUI

/// Keep only the hovered Mac bubble backed by a text-selection view.
struct MessageTextSelection: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}
