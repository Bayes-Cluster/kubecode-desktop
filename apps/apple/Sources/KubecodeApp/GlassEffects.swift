import SwiftUI

extension View {
    @ViewBuilder
    func kubecodeComposerGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                self
                    .glassEffect(.regular.interactive(), in: shape)
                    .overlay {
                        shape
                            .stroke(Color.primary.opacity(0.11), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.065), radius: 10, y: 3)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.065), radius: 10, y: 3)
        }
    }

    @ViewBuilder
    func kubecodeControlGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.clear.interactive(), in: shape)
        } else {
            self.background(Color.primary.opacity(0.055), in: shape)
        }
    }
}
