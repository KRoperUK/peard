import SwiftUI

/// A short, one-shot particle burst for a moment worth celebrating — a goal met,
/// a streak milestone (#421). Built on `Canvas` + `TimelineView` so there is no
/// third-party dependency and no view-tree churn: the particles are drawn, not
/// laid out.
///
/// Deliberately brief (about 1.2s) and self-stopping. Under Reduce Motion it
/// draws nothing at all — the caller shows its own gentle fallback (the goal
/// badge) instead — so this is purely the flourish, never the only signal.
struct CelebrationBurst: View {
    /// Flip to true to fire a burst; it plays once and leaves the view empty.
    let isActive: Bool
    var colors: [Color] = [.accentColor, .yellow, .pink, .mint, .orange]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?

    private let duration: TimeInterval = 1.2
    private let count = 28

    var body: some View {
        GeometryReader { geo in
            if !reduceMotion, let start {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    if elapsed <= duration {
                        Canvas { context, size in
                            draw(&context, size: size, elapsed: elapsed)
                        }
                    } else {
                        Color.clear.onAppear { self.start = nil }
                    }
                }
                .allowsHitTesting(false)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onChange(of: isActive) { _, active in
            if active, !reduceMotion { start = Date() }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let progress = elapsed / duration
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)
        for i in 0..<count {
            // A fixed pseudo-random spread, stable per particle index.
            let angle = Double(i) / Double(count) * 2 * .pi + Double(i % 5)
            let speed = 60.0 + Double((i * 37) % 70)
            let dx = cos(angle) * speed * elapsed * 2.2
            let dy = sin(angle) * speed * elapsed * 2.2 + 90 * elapsed * elapsed
            let point = CGPoint(x: origin.x + dx, y: origin.y + dy)
            let fade = 1 - progress
            let side = 4.0 + Double(i % 3)
            let rect = CGRect(x: point.x, y: point.y, width: side, height: side)
            let color = colors[i % colors.count].opacity(fade)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
        }
    }
}
