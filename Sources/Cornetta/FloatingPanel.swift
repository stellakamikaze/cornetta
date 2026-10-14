import AppKit
import SwiftUI

/// Pannello sempre in primo piano, su tutte le scrivanie e sopra le app a tutto schermo.
/// Non ruba il focus all'app di chiamata.
final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content, autosaveName: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting
        setContentSize(hosting.fittingSize)
        if !setFrameUsingName(autosaveName) {
            placeTopRight()
        }
        setFrameAutosaveName(autosaveName)
        // SwiftUI calcola la dimensione dopo: a ogni ridimensionamento il pannello resta dentro lo schermo.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            self?.keepOnScreen()
        }
    }

    override var canBecomeKey: Bool { true }

    /// In alto a destra, sotto la barra dei menu.
    func placeTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 16))
    }

    func show() {
        orderFrontRegardless()
        keepOnScreen()
        DispatchQueue.main.async { [weak self] in self?.keepOnScreen() }
    }

    /// Se il pannello sborda, lo sposta dentro l'area visibile senza cambiarne la dimensione.
    func keepOnScreen() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        if origin != frame.origin { setFrameOrigin(origin) }
    }
}

/// Sfondo comune dei pannelli: materiale di sistema con angoli arrotondati.
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .padding(1)
    }
}

extension View {
    func panelStyle() -> some View { modifier(PanelBackground()) }
}

/// Pulsante pieno a colori fissi: resta leggibile anche nei pannelli che non prendono il focus,
/// dove lo stile prominente di sistema diventa grigio.
struct FilledButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}
