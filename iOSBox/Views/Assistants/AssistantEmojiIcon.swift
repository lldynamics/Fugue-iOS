import SwiftUI

/// A decorative avatar paired with an accessible assistant or conversation name.
struct AssistantEmojiIcon: View {
    let emoji: String
    let font: Font

    var body: some View {
        Canvas { context, size in
            context.draw(Text(verbatim: emoji).font(font), at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        .accessibilityHidden(true)
    }
}

struct PersonaAvatar: View {
    let identity: PersonaByline
    var size: CGFloat = 32

    var body: some View {
        AssistantEmojiIcon(emoji: identity.emoji, font: .system(size: size * 0.60))
            .frame(width: size, height: size)
            .background(Color(hex: identity.accentHex).opacity(0.16), in: Circle())
    }
}
