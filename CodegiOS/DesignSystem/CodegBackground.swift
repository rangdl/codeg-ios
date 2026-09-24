import SwiftUI

/// App-wide backdrop: near-black with two soft, blurred color glows for depth.
/// Sits behind Liquid Glass surfaces so their translucency reads.
struct CodegBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    // The glows read boldly on near-black but turn muddy over a light backdrop,
    // so they're softened in light mode. The first glow follows the user accent.
    private var accentGlow: Double { colorScheme == .dark ? 0.16 : 0.10 }
    private var coolGlow: Double { colorScheme == .dark ? 0.14 : 0.07 }

    /// The second glow's colour, a fixed cool blue rather than an accent so the
    /// two read as depth instead of two accents.
    private let cool = Color(red: 0.30, green: 0.42, blue: 0.95)

    /// The glows are gradients, not blurred circles.
    ///
    /// They were `Circle().frame(width: w * 0.95).blur(radius: 130/150)` inside a
    /// `GeometryReader`. Two problems, both of which show up in the hang trace:
    /// a `GeometryReader` puts a geometry proxy into the layout graph for the
    /// whole screen (the frozen stack contains `SwiftUI _setThreadGeometryProxyData`),
    /// and a `blur` of 130-150 pt rasterises a full-screen offscreen pass that
    /// re-runs whenever that geometry changes — on *every* screen, since this is
    /// the backdrop behind all of them. A radial gradient fades out analytically:
    /// nothing to rasterise, nothing for geometry to invalidate, same look.
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(
                gradient: Gradient(colors: [Theme.accent.opacity(accentGlow), Theme.accent.opacity(0)]),
                center: UnitPoint(x: 0.22, y: 0.20),
                startRadius: 0,
                endRadius: 430
            )
            RadialGradient(
                gradient: Gradient(colors: [cool.opacity(coolGlow), cool.opacity(0)]),
                center: UnitPoint(x: 0.86, y: 0.94),
                startRadius: 0,
                endRadius: 470
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    CodegBackground()
}
