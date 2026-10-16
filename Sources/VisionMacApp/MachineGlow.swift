import AppKit
import SwiftUI

// MARK: - "Machine in use by Vision AI"
//
// While the agent is driving this Mac — moving the mouse, typing, bringing apps
// forward — the edges of the whole screen glow and a small label says who is
// at the controls. The glow is a floating, click-through panel covering the
// screen: it can never take input itself, and ⌘. (stop the agent) is the way
// to end it, as the control prompt already says.

/// Owns the overlay panel and follows the transport's `machineInUse` flag.
@MainActor
final class MachineGlowController {
    static let shared = MachineGlowController()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// Show the glow while `active`; remove it (with a small linger) once not.
    func setActive(_ active: Bool) {
        if active {
            hideTask?.cancel()
            hideTask = nil
            if panel == nil { show() }
        } else if panel != nil, hideTask == nil {
            // Linger a moment: control tools run in bursts, and a flickering
            // border is worse than a slightly-long one.
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: MachineGlowView())
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        hideTask = nil
    }
}

/// The glow itself: an animated border inset around the screen edges and the
/// label bottom-center. Drawn with almost no layer cost (a stroked gradient
/// and one text), refreshed by its own timeline so the shimmer moves.
struct MachineGlowView: View {
    @State private var shimmer: Bool = false

    private static let text = "machine in use by Vision AI"

    var body: some View {
        ZStack {
            // The border: a rounded-rect stroke hugging the screen edges,
            // gradient-shifting so it reads as alive without being loud.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.85),
                                 Color(red: 0.15, green: 0.75, blue: 0.95).opacity(0.55),
                                 Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.85)],
                        startPoint: shimmer ? .topLeading : .bottomTrailing,
                        endPoint: shimmer ? .bottomTrailing : .topLeading),
                    lineWidth: 5)
                .padding(6)
                .shadow(color: Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.65), radius: 10)

            Label(Self.text, systemImage: "visionpro")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.72), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(red: 0.20, green: 0.95, blue: 0.55).opacity(0.6), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }
}
