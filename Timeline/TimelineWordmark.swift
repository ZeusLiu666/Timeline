import SwiftUI

struct TimelineWordmark: View {
    var body: some View {
        GeometryReader { geometry in
            // Snell Roundhand ships with both macOS and iOS. Keep its native
            // spacing and allow the italic overhang to breathe inside the frame.
            Text("timeline")
                .font(.custom("SnellRoundhand", size: geometry.size.height * 0.92))
                .lineLimit(1)
                .fixedSize()
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
