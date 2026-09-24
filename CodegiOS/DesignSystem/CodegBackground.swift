import SwiftUI

/// App-wide backdrop: near-black with two soft, blurred color glows for depth.
/// Sits behind Liquid Glass surfaces so their translucency reads.
struct CodegBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    // The glows read boldly on near-black but turn muddy over a light backdrop,
    // so they're softened in light mode. The first glow follows the user accent.
    private var accentGlow: Double { colorScheme == .dark ? 0.16 : 0.10 }
    private var coolGlow: Double { colorScheme == .dark ? 0.14 : 0.07 }

    var body: some View {
        ZStack {
            Theme.bg
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(accentGlow))
                        .frame(width: w * 0.95)
                        .blur(radius: 130)
                        .offset(x: -w * 0.28, y: -h * 0.30)
                    Circle()
                        .fill(Color(red: 0.30, green: 0.42, blue: 0.95).opacity(coolGlow))
                        .frame(width: w * 0.95)
                        .blur(radius: 150)
                        .offset(x: w * 0.36, y: h * 0.44)
                }
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    CodegBackground()
}
