import SwiftUI

/// The Undo toast: the change's message and an Undo button, at the bottom of the screen
/// for a few seconds.
struct UndoToastView: View {
    @ObservedObject var toasts: UndoToastCenter

    var body: some View {
        ZStack {
            if let change = toasts.current {
                HStack(spacing: 12) {
                    Text(change.message)
                        .font(.subheadline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Undo") { toasts.undo() }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("toast.undo")
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .frame(minHeight: 48)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(ObjectIdentifier(change))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toast")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toasts.current.map(ObjectIdentifier.init))
        .onChange(of: toasts.current.map(ObjectIdentifier.init)) { _, new in
            if let message = toasts.current?.message, new != nil {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }
}

extension View {
    /// Shows the Undo toast over this view's bottom edge.
    func undoToast(_ toasts: UndoToastCenter) -> some View {
        overlay(alignment: .bottom) { UndoToastView(toasts: toasts) }
    }
}
