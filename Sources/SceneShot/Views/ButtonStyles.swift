import SwiftUI

/// Filled accent button with a clear press reaction (scale + dim). For primary actions.
struct PressableProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Light bordered button with a press reaction. Applied app-wide for tactile feedback.
struct PressableBorderedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                    .brightness(configuration.isPressed ? -0.06 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PressableProminentButtonStyle {
    static var pressableProminent: PressableProminentButtonStyle { .init() }
}
extension ButtonStyle where Self == PressableBorderedButtonStyle {
    static var pressableBordered: PressableBorderedButtonStyle { .init() }
}
