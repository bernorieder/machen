import AppKit

/// A connected account that machen syncs with. The store talks to accounts only through this,
/// so other kinds can be added beside Google.
@MainActor
protocol Account: AnyObject {
    /// Unique and stable; calendars, task lists and their settings are tied to it.
    var id: String { get }
    /// Shown in Settings and next to calendars and lists, for example an address.
    var name: String { get }
    /// False when the account needs to be signed in again; syncing skips it meanwhile.
    var isActive: Bool { get }

    func fetchCalendars() async throws -> [CalendarInfo]
    /// Events of `calendars` (all of this account) between `start` and `end`, in any order.
    func fetchEvents(in calendars: [CalendarInfo], from start: Date, to end: Date) async throws -> [CalendarEvent]
    func fetchTaskLists() async throws -> [TaskListInfo]
    /// Open tasks of `lists` (all of this account), in any order.
    func fetchTasks(in lists: [TaskListInfo]) async throws -> [TaskItem]

    /// Saves a new or edited event in `calendar`. An existing event lives in `home`, and moves
    /// to `calendar` when that differs. With `.allEvents`, an occurrence's series is edited.
    func save(_ draft: EventDraft, in calendar: CalendarInfo, home: CalendarInfo, scope: EditScope) async throws
    /// Deletes an event of `calendar`, or with `.allEvents` the series an occurrence belongs to.
    func deleteEvent(_ draft: EventDraft, in calendar: CalendarInfo, scope: EditScope) async throws
    func save(_ draft: TaskDraft, in list: TaskListInfo) async throws
    func setCompleted(_ completed: Bool, taskIDs: [String], in list: TaskListInfo) async throws
    func deleteTask(_ taskID: String, in list: TaskListInfo) async throws
}

/// A connected account as Settings and the store see it.
struct AccountState: Identifiable, Equatable {
    let id: String
    let name: String
    let isActive: Bool

    /// The part of an address before the "@", to tell apart lists with the same title.
    var shortName: String { name.split(separator: "@").first.map(String.init) ?? name }
}

/// Calendars or task lists of one account, for pickers that group them by account.
struct AccountGroup<Item: Identifiable>: Identifiable {
    let id: String
    let name: String
    let items: [Item]
}

enum AccountError: LocalizedError {
    case notConnected, missing, otherAccount

    var errorDescription: String? {
        switch self {
        case .notConnected: "This account is no longer connected to machen."
        case .missing: "This calendar or task list is no longer available."
        case .otherAccount: "An event can't be moved to a calendar of another account."
        }
    }
}

/// An error from one of several accounts, named so it's clear which account has the problem.
struct AccountFailure: LocalizedError {
    let account: String
    let underlying: Error

    var errorDescription: String? { "\(account): \(underlying.localizedDescription)" }
}

/// The accounts machen is connected to, kept in the Keychain. Only Google accounts so far.
@MainActor
final class Accounts: ObservableObject {
    let googleAuth: GoogleAuth
    /// What Settings shows and the store reacts to; changes when an account is added, removed,
    /// signed out or signed in again.
    @Published private(set) var states: [AccountState] = []
    private var google: [GoogleAccount] = []
    /// Set when this launch turned machen 1.x's single sign-in into an account, so the store can
    /// move that version's settings over to it.
    private(set) var legacyAccountID: String?

    /// The Keychain item (service `local.machen`) holding every Google account and its tokens.
    private static let keychainItem = "google-accounts"
    /// Where machen 1.x kept the tokens of its single Google account.
    private static let legacyKeychainItem = "tokens"

    private struct Stored: Codable {
        let id: String
        let email: String
        let tokens: TokenSet?
    }

    init() {
        googleAuth = GoogleAuth()
        #if !SCREENSHOTS
        // The screenshot tool isn't signed as machen, so reading the keychain would prompt.
        google = loadGoogleAccounts()
        #endif
        google.forEach(watch)
        publish()
    }

    var all: [any Account] { google }
    var active: [any Account] { google.filter(\.isActive) }
    var hasActiveAccount: Bool { states.contains(where: \.isActive) }

    func account(_ id: String) -> (any Account)? { google.first { $0.id == id } }
    func state(_ id: String) -> AccountState? { states.first { $0.id == id } }

    /// Signs in to a Google account in the browser and connects it. For an account that's
    /// connected already (`renewing`, or whichever account the user picks), the sign-in is renewed.
    func signInToGoogle(renewing accountID: String? = nil) async throws {
        let hint = google.first { $0.id == accountID }?.email
        let tokens = try await googleAuth.signIn(hint: hint)
        let email = try await GoogleAccount.email(for: tokens)
        if let known = google.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            known.tokens = tokens
        } else {
            let account = GoogleAccount(id: newAccountID(), email: email, tokens: tokens, auth: googleAuth)
            watch(account)
            google.append(account)
            save()
            publish()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Disconnects an account: machen's access to it is revoked at Google and its tokens dropped.
    func remove(_ id: String) {
        guard let index = google.firstIndex(where: { $0.id == id }) else { return }
        let account = google.remove(at: index)
        if let token = account.tokens?.refreshToken { googleAuth.revoke(token) }
        // Requests still under way fail rather than use it (it's no longer saved, see `changed`)
        account.tokens = nil
        save()
        publish()
    }

    private func watch(_ account: GoogleAccount) {
        account.onChange = { [weak self] in self?.changed($0) }
    }

    /// An account's tokens or address changed: a refresh, an expired session, or its first sync.
    private func changed(_ account: GoogleAccount) {
        guard google.contains(where: { $0 === account }) else { return }
        save()
        publish()
    }

    private func publish() {
        let new = google.map { AccountState(id: $0.id, name: $0.name, isActive: $0.isActive) }
        if new != states { states = new }
    }

    private func newAccountID() -> String {
        var id: String
        repeat {
            id = "google-" + String(format: "%08x", UInt32.random(in: .min ... .max))
        } while google.contains { $0.id == id }
        return id
    }

    /// Updates the one Keychain item in place, which never asks for permission (see `Keychain.set`).
    private func save() {
        #if !SCREENSHOTS
        let stored = google.map { Stored(id: $0.id, email: $0.email, tokens: $0.tokens) }
        if let data = try? JSONEncoder().encode(stored) { Keychain.set(data, for: Self.keychainItem) }
        #endif
    }

    private func loadGoogleAccounts() -> [GoogleAccount] {
        if let data = Keychain.get(Self.keychainItem), let stored = try? JSONDecoder().decode([Stored].self, from: data) {
            return stored.map { GoogleAccount(id: $0.id, email: $0.email, tokens: $0.tokens, auth: googleAuth) }
        }
        // machen 1.x: one Google account, whose address it didn't keep. The first sync fills it in.
        guard let data = Keychain.get(Self.legacyKeychainItem),
              let tokens = try? JSONDecoder().decode(TokenSet.self, from: data) else { return [] }
        let account = GoogleAccount(id: newAccountID(), email: "", tokens: tokens, auth: googleAuth)
        google = [account]
        save()
        Keychain.clear(Self.legacyKeychainItem)
        legacyAccountID = account.id
        return google
    }
}

#if SCREENSHOTS
extension Accounts {
    /// Sample accounts for the README screenshots; their tokens are never used.
    func loadSample(_ accounts: [(id: String, email: String)]) {
        let tokens = TokenSet(accessToken: "", refreshToken: "", expiry: .distantFuture)
        google = accounts.map { GoogleAccount(id: $0.id, email: $0.email, tokens: tokens, auth: googleAuth) }
        publish()
    }
}
#endif
