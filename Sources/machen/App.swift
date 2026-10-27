import SwiftUI

@main
struct MachenApp: App {
    @StateObject private var accounts: Accounts
    @StateObject private var store: Store

    init() {
        let accounts = Accounts()
        _accounts = StateObject(wrappedValue: accounts)
        _store = StateObject(wrappedValue: Store(accounts: accounts))
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(accounts)
                .environmentObject(accounts.googleAuth)
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
    case newTaskList(accountID: String)
    case settings
}

struct RootView: View {
    @EnvironmentObject private var accounts: Accounts
    @EnvironmentObject private var store: Store
    @ViewState private var route: Route = .agenda
    /// Counts openings of the panel, so its height is fitted to the screen it opened on.
    @ViewState private var openings = 0

    var body: some View {
        Group {
            if !accounts.hasActiveAccount {
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
                case .newTaskList(let accountID):
                    TaskListEditor(accountID: accountID, onClose: { route = .agenda },
                                   onCreated: { route = .task(TaskDraft(listID: $0.id, day: store.day)) })
                case .settings:
                    SettingsView { route = .agenda }
                }
            }
        }
        .frame(width: Layout.Popover.width, height: fittedHeight)
        .background(PanelTopAnchor(height: fittedHeight) {
            openings += 1
            Task { await store.refreshOnOpen() }
        })
        .environment(\.rowDensity, store.density)
        .environment(\.textSizes, store.textSizes)
        // Loading and clearing data when accounts come and go is the store's job
        .onChange(of: accounts.hasActiveAccount) { _, _ in route = .agenda }
    }

    private var fittedHeight: CGFloat {
        _ = openings  // recomputed on every opening, when NSScreen.main is the panel's screen
        return store.panelHeight.fittedPoints
    }
}

/// Keeps the menu bar panel hanging from the menu bar at the chosen height. The panel window
/// doesn't reliably follow its content's height (SwiftUI then centres the content, leaving a gap
/// at the top), and when it does resize, AppKit keeps the bottom edge in place. So this sets the
/// window's frame itself: the chosen height, with the top edge under the menu bar.
struct PanelTopAnchor: NSViewRepresentable {
    let height: CGFloat
    /// Called each time the panel opens.
    let onOpen: () -> Void

    func makeNSView(context: Context) -> NSView { AnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? AnchorView else { return }
        view.onOpen = onOpen
        view.apply(height: height)
    }

    final class AnchorView: NSView {
        var onOpen: (() -> Void)?
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
            guard let window, var height else { return }
            let frame = window.frame
            let top = top ?? frame.maxY
            // Never past the bottom of the screen the panel is on
            if let screen = window.screen?.visibleFrame { height = min(height, top - screen.minY) }
            guard frame.height != height || frame.maxY != top else { return }
            window.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
        }

        private func opened(_ window: NSWindow) {
            top = window.frame.maxY
            fitWindow()
            // Not in the middle of a view update (this can run while the panel is being set up)
            DispatchQueue.main.async { [weak self] in self?.onOpen?() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                queue: .main) { [weak self, weak window] _ in
                guard let window else { return }
                self?.opened(window)
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                queue: .main) { [weak self] _ in
                self?.fitWindow()
            })
            if window.isKeyWindow { opened(window) } else { fitWindow() }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
