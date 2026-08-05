import SwiftUI
import UIKit

/// Shared feedback for every SatChart button. The blue flash, slight enlargement,
/// and physical tap begin together so the response remains obvious even when the
/// action immediately presents or dismisses another view.
struct SatChartPressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .satChartPressFeedback(isPressed: configuration.isPressed)
    }
}

/// Textual navigation-bar actions must keep their intrinsic width. SwiftUI may
/// otherwise compress longer labels (for example, "Keep Photos Only") before it
/// gives up space reserved for the center title.
struct SatChartToolbarButtonLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .padding(.horizontal, 2)
    }
}

/// The shared two-step interaction for every destructive trash control.
/// The first tap provides an immediate red icon flash; only the separately
/// presented "Confirm Delete" button is allowed to run the destructive action.
struct SatChartDeleteConfirmationButton<Label: View>: View {
    let confirmationTitle: String
    let confirmationMessage: String?
    let onConfirm: () -> Void
    @ViewBuilder let label: (_ isFlashingRed: Bool) -> Label

    @State private var isFlashingRed = false
    @State private var isShowingConfirmation = false
    @State private var presentationWorkItem: DispatchWorkItem?
    @State private var resetWorkItem: DispatchWorkItem?

    init(
        confirmationTitle: String,
        confirmationMessage: String? = nil,
        onConfirm: @escaping () -> Void,
        @ViewBuilder label: @escaping (_ isFlashingRed: Bool) -> Label
    ) {
        self.confirmationTitle = confirmationTitle
        self.confirmationMessage = confirmationMessage
        self.onConfirm = onConfirm
        self.label = label
    }

    var body: some View {
        Button {
            beginConfirmation()
        } label: {
            label(isFlashingRed)
        }
        .accessibilityHint("Requires confirmation")
        .confirmationDialog(
            confirmationTitle,
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Confirm Delete", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let confirmationMessage, !confirmationMessage.isEmpty {
                Text(confirmationMessage)
            }
        }
        .onDisappear {
            presentationWorkItem?.cancel()
            resetWorkItem?.cancel()
        }
    }

    private func beginConfirmation() {
        presentationWorkItem?.cancel()
        resetWorkItem?.cancel()

        withAnimation(.easeOut(duration: 0.08)) {
            isFlashingRed = true
        }

        let presentationWorkItem = DispatchWorkItem {
            isShowingConfirmation = true
        }
        self.presentationWorkItem = presentationWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: presentationWorkItem)

        let resetWorkItem = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.10)) {
                isFlashingRed = false
            }
        }
        self.resetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: resetWorkItem)
    }
}

/// Keeps the red feedback scoped to the trash symbol instead of tinting the
/// button's text, border, or surrounding card.
struct SatChartDeleteIcon: View {
    var systemName: String = "trash"
    let isFlashingRed: Bool
    var defaultColor: Color = .primary

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(isFlashingRed ? Color.red : defaultColor)
            .animation(.easeOut(duration: 0.08), value: isFlashingRed)
    }
}

private struct SatChartPressFeedbackModifier: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 1.045 : 1)
            .brightness(isPressed ? 0.12 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.blue.opacity(isPressed ? 0.24 : 0))
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.blue.opacity(isPressed ? 0.72 : 0), radius: isPressed ? 9 : 0)
            .zIndex(isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.13), value: isPressed)
            .onChange(of: isPressed) { pressed in
                guard pressed else { return }
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.prepare()
                generator.impactOccurred(intensity: 0.86)
            }
    }
}

/// Adds SatChart feedback without replacing an existing native button style such
/// as `.bordered` or `.borderedProminent`.
private struct SatChartExistingButtonFeedbackModifier: ViewModifier {
    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        pressed = true
                    }
            )
            .satChartPressFeedback(isPressed: isPressed)
    }
}

extension View {
    func satChartPressFeedback(isPressed: Bool) -> some View {
        modifier(SatChartPressFeedbackModifier(isPressed: isPressed))
    }

    func satChartExistingButtonFeedback() -> some View {
        modifier(SatChartExistingButtonFeedbackModifier())
    }
}
