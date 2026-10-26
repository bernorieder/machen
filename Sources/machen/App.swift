import SwiftUI

@main
struct MachenApp: App {
    @StateObject private var auth: GoogleAuth
    @StateObject private var store: Store

    init() {
        let auth = GoogleAuth()
        _auth = StateObject(wrappedValue: auth)
        _store = StateObject(wrappedValue: Store(auth: auth))
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(auth)
                .environmentObject(store)
        } label: {
            MenuBarIcon.image(store.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Route: Equatable {
    case agenda
    case event(EventDraft)
    case task(TaskDraft)
    case settings
}

struct RootView: View {
    @EnvironmentObject private var auth: GoogleAuth
    @EnvironmentObject private var store: Store
    @ViewState private var route: Route = .agenda

    var body: some View {
        Group {
            if !auth.isSignedIn {
                SignInView()
            } else {
                switch route {
                case .agenda:
                    AgendaView(route: $route)
                case .event(let draft):
                    EventEditor(draft: draft) { route = .agenda }
                case .task(let draft):
                    TaskEditor(draft: draft, onClose: { route = .agenda }, onOpen: { route = .task($0) })
                        .id(draft.editorID)
                case .settings:
                    SettingsView { route = .agenda }
                }
            }
        }
        .frame(width: Layout.Popover.width, height: store.panelHeight.fittedPoints)
        .background(PanelTopAnchor(height: store.panelHeight.fittedPoints))
        .environment(\.rowDensity, store.density)
        .environment(\.textSizes, store.textSizes)
        .task { await store.refreshOnOpen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refreshOnOpen() }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            route = .agenda
            if signedIn {
                Task { await store.refresh() }
            } else {
                store.clear()
            }
        }
    }
}

/// Keeps the menu bar panel hanging from the menu bar at the chosen height. The panel window
/// doesn't reliably follow its content's height (SwiftUI then centres the content, leaving a gap
/// at the top), and when it does resize, AppKit keeps the bottom edge in place. So this sets the
/// window's frame itself: the chosen height, with the top edge under the menu bar.
struct PanelTopAnchor: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { AnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AnchorView)?.apply(height: height)
    }

    final class AnchorView: NSView {
        /// Top edge of the panel as macOS places it when it opens (right under the menu bar).
        private var top: CGFloat?
        private var height: CGFloat?
        private var observers: [NSObjectProtocol] = []

        func apply(height: CGFloat) {
            self.height = height
            // After SwiftUI's own layout pass, which may resize the window its own way
            DispatchQueue.main.async { [weak self] in self?.fitWindow() }
        }

        private func fitWindow() {
            guard let window, let height else { return }
            let frame = window.frame
            let top = top ?? frame.maxY
            guard frame.height != height || frame.maxY != top else { return }
            window.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                queue: .main) { [weak self] _ in
                self?.top = window.frame.maxY
                self?.fitWindow()
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                queue: .main) { [weak self] _ in
                self?.fitWindow()
            })
            if window.isKeyWindow { top = window.frame.maxY }
            fitWindow()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
