import SwiftUI
import ServiceManagement

struct SignInView: View {
    @EnvironmentObject private var auth: GoogleAuth
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                Text("machen").font(.title2.bold())
            }
            Text("Connect your Google account to see your upcoming events and open tasks.")
                .foregroundStyle(.secondary)
            if !auth.hasBundledClient {
                Text("This build has no Google client built in. You need an OAuth client of type “Desktop app” from Google Cloud Console, with the Google Calendar API and Google Tasks API enabled. The README walks through it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Client ID", text: $auth.clientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client secret", text: $auth.clientSecret)
                    .textFieldStyle(.roundedBorder)
            }

            if auth.isSigningIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.callout)
                    Spacer()
                    Button("Cancel") { auth.cancelSignIn() }
                }
            } else {
                Button("Sign in with Google") {
                    error = nil
                    Task {
                        do {
                            try await auth.signIn()
                        } catch is CancellationError {
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!auth.canSignIn)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer()
            HStack {
                if !auth.hasBundledClient {
                    Link("Open Google Cloud Console",
                         destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        .font(.caption)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var auth: GoogleAuth
    @EnvironmentObject private var store: Store
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var launchError: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            Form {
                Section("Display") {
                    Stepper(value: $store.eventDays, in: Store.eventDayRange) {
                        LabeledContent("Days of events", value: store.eventDays == 1 ? "1 day" : "\(store.eventDays) days")
                    }
                    Picker("Multi-day events", selection: $store.multiDayMode) {
                        ForEach(MultiDayMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Tasks", selection: $store.taskFilter) {
                        ForEach(TaskFilter.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Menu bar icon", selection: $store.menuBarIcon) {
                        ForEach(MenuBarIcon.choices, id: \.symbol) { choice in
                            Label { Text(choice.name) } icon: { MenuBarIcon.image(choice.symbol) }
                                .tag(choice.symbol)
                        }
                    }
                    Picker("Spacing", selection: $store.density) {
                        ForEach(RowDensity.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Calendars") {
                    ForEach(store.calendars) { cal in
                        Toggle(isOn: Binding(get: { store.isShown(cal) }, set: { store.setShown(cal, $0) })) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hex: cal.backgroundColor) ?? .accentColor)
                                    .frame(width: 8, height: 8)
                                Text(cal.name).lineLimit(1)
                            }
                        }
                    }
                }
                Section("Task lists") {
                    ForEach(store.taskLists) { list in
                        HStack(spacing: 8) {
                            Menu {
                                ForEach(ListPalette.colors, id: \.hex) { color in
                                    Button {
                                        store.setColor(color.hex, for: list)
                                    } label: {
                                        Label { Text(color.name) } icon: { Image(nsImage: ListPalette.swatch(color.hex)) }
                                    }
                                }
                            } label: {
                                Image(nsImage: ListPalette.swatch(store.colorHex(for: list)))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Choose color")
                            Toggle(list.title, isOn: Binding(get: { store.isShown(list) }, set: { store.setShown(list, $0) }))
                        }
                    }
                }
                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                    if let launchError {
                        Text(launchError).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Links") {
                    Link("Google Calendar", destination: URL(string: "https://calendar.google.com")!)
                    Link("Google Tasks", destination: URL(string: "https://tasks.google.com")!)
                    Link("machen on GitHub", destination: URL(string: "https://github.com/bernorieder/machen")!)
                }
                Section("Credits") {
                    Link("Fist icon: Font Awesome Free (CC BY 4.0)",
                         destination: URL(string: "https://fontawesome.com/license/free")!)
                }
                Section("Account") {
                    Button("Sign Out of Google") { auth.signOut() }
                    Button("Quit machen") { NSApp.terminate(nil) }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchError = nil
            } catch {
                launchError = error.localizedDescription
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
