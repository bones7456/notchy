import SwiftUI
import SwiftTerm

private class ClickThroughContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct TerminalSessionView: NSViewRepresentable {
    let sessionId: UUID
    let workingDirectory: String
    var launchAgent: Bool = true
    var generation: Int = 0

    class Coordinator {
        var currentSessionId: UUID?
        var currentGeneration: Int = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = ClickThroughContainerView(frame: .zero)
        container.wantsLayer = true
        attachTerminal(to: container, context: context)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.currentSessionId != sessionId || context.coordinator.currentGeneration != generation {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            attachTerminal(to: nsView, context: context)
        }
    }

    private func attachTerminal(to container: NSView, context: Context) {
        context.coordinator.currentSessionId = sessionId
        context.coordinator.currentGeneration = generation
        let terminal = TerminalManager.shared.terminal(for: sessionId, workingDirectory: workingDirectory, launchAgent: launchAgent)

        // Remove from previous superview if it was in a different container
        terminal.removeFromSuperview()

        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Give terminal keyboard focus
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}
