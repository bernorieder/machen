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
            Image(systemName: store.menuBarIcon)
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
        .frame(width: 360, height: 540)
        .environment(\.rowDensity, store.density)
        .task { await store.refreshIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refreshIfStale() }
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
