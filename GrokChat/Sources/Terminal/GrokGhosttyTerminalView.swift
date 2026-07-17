import SwiftUI

struct GrokGhosttyTerminalView: NSViewRepresentable {
    let sessionId: UUID
    let executable: String
    let arguments: [String]
    let workingDirectory: String?
    let isActive: Bool
    let isVisibleInUI: Bool

    func makeNSView(context: Context) -> GrokGhosttyTerminalNSView {
        let view = GrokGhosttyTerminalNSView(
            sessionId: sessionId,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
        context.coordinator.hostedView = view
        view.setVisibleInUI(isVisibleInUI)
        return view
    }

    func updateNSView(_ nsView: GrokGhosttyTerminalNSView, context: Context) {
        nsView.setVisibleInUI(isVisibleInUI)
        if isActive && isVisibleInUI {
            DispatchQueue.main.async {
                nsView.focusTerminal()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var hostedView: GrokGhosttyTerminalNSView?
    }
}
