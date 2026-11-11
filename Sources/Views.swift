import SwiftUI
import WebKit

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var manager: InstanceManager
    @AppStorage("placeInput") private var placeInput = ""
    @AppStorage("jobId") private var jobId = ""
    @State private var selection = Set<Int64>()
    @State private var showLogin = false
    @State private var showPaste = false
    @State private var info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetBar
            HSplitView {
                accountsPanel.frame(minWidth: 380)
                instancesPanel.frame(minWidth: 320)
            }
        }
        .padding(14)
        .frame(minWidth: 780, minHeight: 460)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Log In with Roblox…") { showLogin = true }
                    Button("Paste .ROBLOSECURITY Cookie…") { showPaste = true }
                } label: { Label("Add Account", systemImage: "person.badge.plus") }

                Button {
                    manager.launch(selectedAccounts, placeInput: placeInput, jobId: jobId)
                } label: { Label("Launch Selected", systemImage: "play.fill") }
                .disabled(selection.isEmpty)
                .help("Launch every selected account, 4 seconds apart")

                Button { manager.launchPlain() } label: { Label("Open Roblox", systemImage: "plus.rectangle.on.rectangle") }
                    .help("Open another Roblox window without choosing an account")
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet { cookie in
                showLogin = false
                add(cookie)
            } onCancel: { showLogin = false }
        }
        .sheet(isPresented: $showPaste) {
            PasteCookieSheet { cookie in
                showPaste = false
                add(cookie)
            } onCancel: { showPaste = false }
        }
        .alert("Something went wrong", isPresented: Binding(get: { manager.lastError != nil }, set: { if !$0 { manager.lastError = nil } })) {
            Button("OK") {}
        } message: { Text(manager.lastError ?? "") }
        .alert("Done", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK") {}
        } message: { Text(info ?? "") }
    }

    private var selectedAccounts: [Account] { store.accounts.filter { selection.contains($0.id) } }

    private func add(_ cookie: String) {
        Task {
            do {
                let a = try await store.add(cookie: cookie)
                info = "Added \(a.label)."
            } catch {
                manager.lastError = error.localizedDescription
            }
        }
    }

    // MARK: Target

    private var targetBar: some View {
        let parsed = LaunchTarget.parse(placeInput, jobId: jobId)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Place ID, game link, or private server link (blank = Roblox home)", text: $placeInput)
                    .textFieldStyle(.roundedBorder)
                TextField("Job ID (optional)", text: $jobId)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            Group {
                if placeInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Accounts will open on the Roblox home screen.")
                } else if let parsed {
                    Text("Accounts will join \(parsed.summary).")
                } else {
                    Text("Couldn't find a place ID in that text.").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            PerformanceRow()
                .padding(.top, 4)
            FollowBar(selected: selectedAccounts)
                .padding(.top, 2)
            AfkBar()
        }
    }

    // MARK: Accounts

    private var accountsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Accounts").font(.headline)
                Text("\(store.accounts.count)").foregroundStyle(.secondary)
                Spacer()
                if !store.accounts.isEmpty {
                    Button(selection.count == store.accounts.count ? "Select None" : "Select All") {
                        selection = selection.count == store.accounts.count ? [] : Set(store.accounts.map(\.id))
                    }
                    .buttonStyle(.link)
                }
            }
            if store.accounts.isEmpty {
                emptyState(icon: "person.2", title: "No accounts yet",
                           detail: "Use Add Account in the toolbar to log in. Logins are stored in your Keychain.")
            } else {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        AccountRow(account: account)
                            .tag(account.id)
                            .contextMenu {
                                Button("Launch") { launch([account]) }
                                if let inst = manager.instance(for: account.id) {
                                    Button("Bring to Front") { manager.focus(inst) }
                                    Button("Close Instance") { manager.close(inst) }
                                }
                                Divider()
                                Button("Copy Username") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(account.name, forType: .string)
                                }
                                Button("Open Profile") {
                                    NSWorkspace.shared.open(URL(string: "https://www.roblox.com/users/\(account.id)/profile")!)
                                }
                                Divider()
                                Button("Remove Account", role: .destructive) {
                                    selection.remove(account.id)
                                    store.remove(account)
                                }
                            }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(.trailing, 8)
    }

    private func launch(_ accounts: [Account]) {
        manager.launch(accounts, placeInput: placeInput, jobId: jobId)
    }

    // MARK: Instances

    private var instancesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Running Instances").font(.headline)
                Text("\(manager.instances.count)").foregroundStyle(.secondary)
                Spacer()
                if !manager.instances.isEmpty {
                    Button("Close All", role: .destructive) { manager.closeAll() }
                        .buttonStyle(.link)
                }
            }
            if manager.instances.isEmpty {
                emptyState(icon: "rectangle.stack", title: "Nothing running",
                           detail: "Roblox windows you open here or elsewhere show up in this list.")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    List(manager.instances) { inst in
                        InstanceRow(instance: inst, account: store.account(id: inst.accountID), now: ctx.date)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
        .padding(.leading, 8)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Follow Main

struct FollowBar: View {
    @EnvironmentObject var manager: InstanceManager
    @AppStorage("autoFollow") private var autoFollow = false
    let selected: [Account]

    var body: some View {
        HStack(spacing: 10) {
            if let main = manager.mainAccount {
                Avatar(url: main.avatarURL, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        Text("Main: \(main.displayName)").fontWeight(.medium)
                    }
                    Text(manager.followStatus.isEmpty ? (manager.mainPresence?.summary ?? "Checking…") : manager.followStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Auto-follow", isOn: $autoFollow)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: autoFollow) { _ in manager.autoFollowChanged() }
                    .help("When Main moves to another server or lobby, move running alts there too")
                let altSel = selected.filter { $0.id != main.id }
                Button(altSel.isEmpty ? "Bring Alts to Main" : "Send \(altSel.count) to Main") {
                    manager.bringAltsToMain(altSel)
                }
                .help("Launch alts into the server Main is in now. With nothing selected, sends every alt that isn't running.")
            } else {
                Image(systemName: "star").foregroundStyle(.secondary)
                Text("Click the star next to an account to make it Main. Alts can then join and follow Main's server.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Anti-AFK

struct AfkBar: View {
    @EnvironmentObject var afk: AfkController
    @EnvironmentObject var manager: InstanceManager
    @AppStorage("afkInterval") private var interval = 540
    @AppStorage("afkAction") private var action = 0
    @AppStorage("afkWaitIdle") private var waitIdle = true
    @AppStorage("afkReturnFocus") private var returnFocus = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: afk.isRunning ? "figure.walk.circle.fill" : "figure.walk.circle")
                .font(.title3)
                .foregroundStyle(afk.isRunning ? Color.green : Color.secondary)
            Toggle("Anti-AFK", isOn: Binding(get: { afk.isRunning }, set: { $0 ? afk.start() : afk.stop() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Keeps every open Roblox window from being kicked for idling")

            Picker("Every", selection: $interval) {
                ForEach(AfkController.intervals, id: \.1) { Text($0.0).tag($0.1) }
            }
            .frame(width: 120)
            .controlSize(.small)
            .onChange(of: interval) { _ in afk.reschedule() }

            Picker("Action", selection: $action) {
                ForEach(AfkAction.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .frame(width: 170)
            .controlSize(.small)

            Menu {
                Toggle("Wait until I stop typing", isOn: $waitIdle)
                Toggle("Return to the app I was using", isOn: $returnFocus)
            } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Anti-AFK options")

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(afk.statusLine(now: ctx.date))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()
            if !AfkController.hasAccessibility {
                Button("Grant Accessibility…") { AfkController.requestAccessibility() }
                    .controlSize(.small)
                    .help("macOS requires Accessibility permission to press keys in Roblox")
            }
            Button("Run Now") { afk.runNow() }
                .controlSize(.small)
                .disabled(afk.busy || manager.instances.isEmpty)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Performance

struct PerformanceRow: View {
    @EnvironmentObject var manager: InstanceManager
    @AppStorage("perfEnabled") private var enabled = true
    @AppStorage("perfVolume") private var volume = 0
    @AppStorage("perfGraphics") private var graphics = 1
    @AppStorage("perfCap60") private var cap60 = false
    @State private var restored = false

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Low-performance launch", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Start windows opened from this app with the volume and graphics below. Your normal Roblox settings are put back afterwards.")

            Group {
                Picker("Volume", selection: $volume) {
                    ForEach(0...10, id: \.self) { Text(String($0)).tag($0) }
                }
                .frame(width: 110)
                Picker("Graphics", selection: $graphics) {
                    ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                }
                .frame(width: 120)
                Toggle("Cap at 60 FPS", isOn: $cap60)
            }
            .disabled(!enabled)
            .controlSize(.small)

            Spacer()
            Button(restored ? "Restored" : "Restore My Roblox Settings") {
                restored = manager.restoreRobloxSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { restored = false }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(!RobloxSettingsFile.hasSnapshot)
            .help("Put your own volume and graphics back right now")
        }
    }
}

// MARK: - Rows

struct Avatar: View {
    let url: String?
    var size: CGFloat = 32
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { img in
            img.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct AccountRow: View {
    @EnvironmentObject var manager: InstanceManager
    @EnvironmentObject var store: AccountStore
    @AppStorage("placeInput") private var placeInput = ""
    @AppStorage("jobId") private var jobId = ""
    let account: Account

    var body: some View {
        let active = manager.instance(for: account.id)
        let isMain = manager.mainAccountID == account.id
        HStack(spacing: 10) {
            Button {
                manager.setMain(isMain ? nil : account)
            } label: {
                Image(systemName: isMain ? "star.fill" : "star")
                    .foregroundStyle(isMain ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isMain ? "Main account (click to unset)" : "Make this the Main account")
            Avatar(url: account.avatarURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).fontWeight(.medium)
                Text("@\(account.name)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if manager.launching.contains(account.id) {
                ProgressView().controlSize(.small)
            } else if let active {
                Label("Active · PID \(active.pid)", systemImage: "circle.fill")
                    .labelStyle(StatusLabelStyle(color: .green))
                Button("Focus") { manager.focus(active) }.controlSize(.small)
            } else {
                Button("Launch") {
                    manager.launch([account], placeInput: placeInput, jobId: jobId)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

struct InstanceRow: View {
    @EnvironmentObject var manager: InstanceManager
    let instance: RobloxInstance
    let account: Account?
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            if let account {
                Avatar(url: account.avatarURL, size: 26)
            } else {
                Image(systemName: "questionmark.circle").font(.system(size: 22)).foregroundStyle(.tertiary).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(account?.displayName ?? "Unknown account").fontWeight(.medium)
                Text("PID \(instance.pid) · up \(formatUptime(instance.started, now: now))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Button("Focus") { manager.focus(instance) }.controlSize(.small)
            Button("Close") { manager.close(instance) }.controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title.font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add account sheets

struct LoginSheet: View {
    let onCookie: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log in to Roblox").font(.headline)
                Spacer()
                Text("This window closes on its own after you log in.").font(.caption).foregroundStyle(.secondary)
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            RobloxLoginWebView(onCookie: onCookie)
        }
        .frame(width: 520, height: 700)
    }
}

/// Embedded roblox.com login page. Each sheet uses a fresh, private cookie jar so logging
/// in to one account never signs another one out.
struct RobloxLoginWebView: NSViewRepresentable {
    let onCookie: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookie: onCookie) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = RobloxAPI.userAgent
        web.navigationDelegate = context.coordinator
        context.coordinator.cookieStore = config.websiteDataStore.httpCookieStore
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.startPolling()
        web.load(URLRequest(url: URL(string: "https://www.roblox.com/login")!))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// WebKit's cookie-change callback is unreliable for non-persistent stores, so the
    /// login cookie is also checked after every page load and once a second.
    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate {
        let onCookie: (String) -> Void
        weak var cookieStore: WKHTTPCookieStore?
        private var done = false
        private var timer: Timer?

        init(onCookie: @escaping (String) -> Void) { self.onCookie = onCookie }

        func startPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func check() {
            guard !done, let store = cookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.done,
                      let c = cookies.first(where: { $0.name == ".ROBLOSECURITY" && !$0.value.isEmpty }) else { return }
                self.done = true
                self.stop()
                DispatchQueue.main.async { self.onCookie(c.value) }
            }
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { check() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }
    }
}

struct PasteCookieSheet: View {
    let onAdd: (String) -> Void
    let onCancel: () -> Void
    @State private var cookie = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Account with Cookie").font(.headline)
            Text("Paste the value of the .ROBLOSECURITY cookie. It's checked with Roblox and saved in your Keychain.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("_|WARNING:-DO-NOT-SHARE-THIS…", text: $cookie)
                .textFieldStyle(.roundedBorder)
            Label("Anyone with this cookie can use your account. Never paste it into apps or sites you don't trust.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(cookie) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cookie.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var manager: InstanceManager
    @EnvironmentObject var afk: AfkController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("placeInput") private var placeInput = ""
    @AppStorage("jobId") private var jobId = ""
    @AppStorage("autoFollow") private var autoFollow = false
    @AppStorage("perfEnabled") private var perfEnabled = true
    @AppStorage("perfVolume") private var perfVolume = 0
    @AppStorage("perfGraphics") private var perfGraphics = 1

    var body: some View {
        Text(manager.instances.isEmpty ? "No Roblox instances running"
             : "\(manager.instances.count) Roblox instance\(manager.instances.count == 1 ? "" : "s") running")

        ForEach(manager.instances) { inst in
            let name = store.account(id: inst.accountID)?.displayName ?? "Unknown account"
            Menu("● \(name) — up \(formatUptime(inst.started))") {
                Button("Bring to Front") { manager.focus(inst) }
                Button("Close") { manager.close(inst) }
            }
        }

        Divider()

        Menu("Launch Account") {
            if store.accounts.isEmpty {
                Text("No accounts added")
            }
            ForEach(store.accounts) { account in
                let active = manager.instance(for: account.id) != nil
                Button(active ? "\(account.label) (active)" : account.label) {
                    manager.launch([account], placeInput: placeInput, jobId: jobId)
                }
            }
            if store.accounts.count > 1 {
                Divider()
                Button("Launch All Inactive") {
                    let idle = store.accounts.filter { manager.instance(for: $0.id) == nil }
                    manager.launch(idle, placeInput: placeInput, jobId: jobId)
                }
            }
        }
        Button("Open Another Roblox Window") { manager.launchPlain() }
        if !manager.instances.isEmpty {
            Button("Close All Instances") { manager.closeAll() }
        }

        Divider()
        if let main = manager.mainAccount {
            Text("Main: \(main.displayName) — \(manager.mainPresence?.summary ?? "checking…")")
            Button("Bring Alts to Main") { manager.bringAltsToMain([]) }
            Toggle("Auto-Follow Main", isOn: $autoFollow)
                .onChange(of: autoFollow) { _ in manager.autoFollowChanged() }
        } else {
            Text("No Main account set")
        }

        Divider()
        Toggle("Anti-AFK (All Windows)", isOn: Binding(get: { afk.isRunning }, set: { $0 ? afk.start() : afk.stop() }))
        Text(afk.statusLine(now: Date()))
        Button("Run Anti-AFK Now") { afk.runNow() }
            .disabled(afk.busy)
        if !AfkController.hasAccessibility {
            Button("Grant Accessibility Permission…") { AfkController.requestAccessibility() }
        }

        Divider()
        Toggle("Low-Performance Launch (Vol \(perfVolume), Graphics \(perfGraphics))", isOn: $perfEnabled)
        if RobloxSettingsFile.hasSnapshot {
            Button("Restore My Roblox Settings") { _ = manager.restoreRobloxSettings() }
        }

        Divider()
        Button("Show Window…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Quit RBX Multi-Instance") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
