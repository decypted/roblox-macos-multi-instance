import AppKit
import Foundation

// MARK: - Accounts

struct Account: Codable, Identifiable, Hashable {
    var id: Int64            // Roblox user ID
    var name: String
    var displayName: String
    var avatarURL: String?
    var lastLaunched: Date?

    var label: String { displayName == name ? name : "\(displayName) (@\(name))" }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RBX-Multi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("accounts.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Validates the cookie with Roblox, then stores it in the Keychain.
    @discardableResult
    func add(cookie raw: String) async throws -> Account {
        let cookie = Self.clean(raw)
        let user = try await RobloxAPI.currentUser(cookie: cookie)
        let avatar = await RobloxAPI.headshotURL(userId: user.id)
        Keychain.set(cookie, for: String(user.id))

        let account = Account(id: user.id, name: user.name, displayName: user.displayName, avatarURL: avatar,
                              lastLaunched: accounts.first(where: { $0.id == user.id })?.lastLaunched)
        if let i = accounts.firstIndex(where: { $0.id == user.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        save()
        return account
    }

    func remove(_ account: Account) {
        Keychain.delete(String(account.id))
        accounts.removeAll { $0.id == account.id }
        save()
    }

    func move(from: IndexSet, to: Int) {
        accounts.move(fromOffsets: from, toOffset: to)
        save()
    }

    func markLaunched(_ id: Int64) {
        if let i = accounts.firstIndex(where: { $0.id == id }) {
            accounts[i].lastLaunched = Date()
            save()
        }
    }

    func cookie(for account: Account) -> String? { Keychain.get(String(account.id)) }

    func account(id: Int64?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    static func clean(_ s: String) -> String {
        var c = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix(".ROBLOSECURITY=") { c.removeFirst(".ROBLOSECURITY=".count) }
        if c.hasSuffix(";") { c.removeLast() }
        return c
    }
}

// MARK: - Running instances

struct RobloxInstance: Identifiable, Hashable {
    let pid: pid_t
    let accountID: Int64?
    let started: Date
    var id: pid_t { pid }
}

@MainActor
final class InstanceManager: ObservableObject {
    static let robloxBundleID = "com.roblox.RobloxPlayer"

    @Published private(set) var instances: [RobloxInstance] = []
    @Published var lastError: String?
    @Published private(set) var launching: Set<Int64> = []

    // Follow-the-main-account state
    @Published private(set) var mainPresence: UserPresence?
    @Published private(set) var followStatus = ""

    private struct Tracked { let accountID: Int64?; let started: Date }
    private var tracked: [pid_t: Tracked] = [:]
    private var perfPIDs: Set<pid_t> = []
    private var restoreToken = 0
    private var timer: Timer?
    private var presenceTimer: Timer?
    private var polling = false
    private var followedGameId: String?
    private var pendingGameId: String?
    private var syncing = false
    let store: AccountStore

    init(store: AccountStore) {
        self.store = store
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMain() }
        }
        pollMain()
    }

    var robloxAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.robloxBundleID)
            ?? (FileManager.default.fileExists(atPath: "/Applications/Roblox.app") ? URL(fileURLWithPath: "/Applications/Roblox.app") : nil)
    }

    func instance(for accountID: Int64) -> RobloxInstance? {
        instances.first { $0.accountID == accountID }
    }

    func refresh() {
        var pids: [pid_t: Date] = [:]
        // Only regular apps: Roblox's menu bar helper (RobloxPlayer -launchToTray) runs as an
        // accessory app and has no game window.
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == Self.robloxBundleID && !app.isTerminated && app.activationPolicy == .regular {
            pids[app.processIdentifier] = app.launchDate ?? Date()
        }
        for (pid, t) in tracked where kill(pid, 0) == 0 {
            pids[pid] = pids[pid] ?? t.started
        }
        tracked = tracked.filter { kill($0.key, 0) == 0 }

        // Once every low-performance window has closed, put the user's settings back for good
        // (a closing Roblox client may save its lowered settings on the way out).
        let hadPerf = !perfPIDs.isEmpty
        perfPIDs = perfPIDs.filter { kill($0, 0) == 0 }
        if hadPerf && perfPIDs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { RobloxSettingsFile.restore(clear: true) }
        }

        let list = pids.map { pid, date in
            RobloxInstance(pid: pid, accountID: tracked[pid]?.accountID, started: tracked[pid]?.started ?? date)
        }.sorted { $0.started < $1.started }
        if list != instances { instances = list }
    }

    // MARK: Launching

    /// Launches each account in order, a few seconds apart so Roblox doesn't rate-limit the joins.
    func launch(_ accounts: [Account], placeInput: String, jobId: String) {
        let trimmed = placeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = LaunchTarget.parse(trimmed, jobId: jobId)
        if !trimmed.isEmpty && target == nil {
            lastError = "Couldn't find a place ID in \"\(trimmed)\". Use a number or a roblox.com/games/… link."
            return
        }
        Task { await launchAccounts(accounts, target: target) }
    }

    func launchAccounts(_ accounts: [Account], target: LaunchTarget?) async {
        for (i, account) in accounts.enumerated() {
            guard let cookie = store.cookie(for: account) else {
                lastError = "No saved login for \(account.name). Remove the account and add it again."
                continue
            }
            launching.insert(account.id)
            do {
                try await launchOne(account, cookie: cookie, target: target)
                store.markLaunched(account.id)
            } catch {
                lastError = "\(account.name): \(error.localizedDescription)"
            }
            launching.remove(account.id)
            if i < accounts.count - 1 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
        }
    }

    private func launchOne(_ account: Account, cookie: String, target: LaunchTarget?) async throws {
        let ticket = try await RobloxAPI.authTicket(cookie: cookie)
        let tracker = String(Int64.random(in: 100_000_000_000...999_999_999_999))
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        var parts = [
            "roblox-player:1",
            "launchmode:\(target == nil ? "app" : "play")",
            "gameinfo:\(ticket)",
            "launchtime:\(now)",
        ]
        if let target {
            parts.append("placelauncherurl:\(Self.encode(target.placeLauncherURL(browserTrackerId: tracker)))")
        }
        parts += ["browsertrackerid:\(tracker)", "robloxLocale:en_us", "gameLocale:en_us", "channel:", "LaunchExp:InApp"]

        try spawn(arguments: ["-protocolString", parts.joined(separator: "+")], accountID: account.id,
                  profile: Self.profileDirectory(for: account.id))
    }

    /// Opens Roblox normally (whatever account the Roblox app itself is signed in to).
    func launchPlain() {
        do { try spawn(arguments: [], accountID: nil, profile: nil) } catch { lastError = error.localizedDescription }
    }

    /// Each account gets its own home folder for Roblox. macOS keeps Roblox's login cookies
    /// in <home>/Library/HTTPStorages, so with a separate home every window keeps its own
    /// login. Without this, all windows share one cookie jar: when one window teleports it
    /// rejoins as whichever account logged in last, and Roblox kicks the duplicate
    /// ("same account launched experience from different device").
    static func profileDirectory(for accountID: Int64) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RBX-Multi/Profiles/\(accountID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs the RobloxPlayer binary directly. Going through LaunchServices (`open`) would be
    /// refused because Roblox's Info.plist sets LSMultipleInstancesProhibited.
    private func spawn(arguments: [String], accountID: Int64?, profile: URL?) throws {
        guard let app = robloxAppURL else {
            throw NSError(domain: "RBXMulti", code: 1, userInfo: [NSLocalizedDescriptionKey: "Roblox isn't installed. Install it from roblox.com first."])
        }
        let exe = app.appendingPathComponent("Contents/MacOS/RobloxPlayer").path
        let perf = PerfSettings.current
        if perf.enabled {
            RobloxSettingsFile.snapshotIfNeeded()
            RobloxSettingsFile.write(perf.values)
        }
        Self.detachSingletonSemaphore()
        var env = ProcessInfo.processInfo.environment
        if let profile {
            env["HOME"] = profile.path
            env["CFFIXED_USER_HOME"] = profile.path
        }
        let pid = try Self.spawnDetached(executable: exe, arguments: arguments, environment: env)
        tracked[pid] = Tracked(accountID: accountID, started: Date())
        if perf.enabled {
            perfPIDs.insert(pid)
            scheduleSettingsRestore()
        }

        // Reap the child when it exits so it doesn't linger as a zombie.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    /// Roblox reads its settings file during startup. 15 seconds after the most recent
    /// launch, write the user's own values back so their normal Roblox isn't left on low.
    private func scheduleSettingsRestore() {
        restoreToken += 1
        let token = restoreToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, token == self.restoreToken else { return }
            RobloxSettingsFile.restore(clear: false)
        }
    }

    /// Manual escape hatch: puts the user's saved volume/graphics back right now.
    func restoreRobloxSettings() -> Bool {
        RobloxSettingsFile.restore(clear: perfPIDs.isEmpty)
    }

    private typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// Starts Roblox in its own session and, crucially, disclaims responsibility for it.
    /// Without the disclaim, macOS privacy checks (TCC) treat this app as the "responsible"
    /// process; when Roblox asks for the microphone (voice chat), TCC looks for a microphone
    /// usage description in *our* Info.plist and kills Roblox. Disclaiming makes Roblox
    /// responsible for itself, exactly as if it had been opened from Finder or Terminal.
    private static func spawnDetached(executable: String, arguments: [String], environment: [String: String]) throws -> pid_t {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // RTLD_DEFAULT is (void *)-2 on Darwin.
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            let disclaim = unsafeBitCast(sym, to: DisclaimFn.self)
            _ = disclaim(&attr, 1)
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, &argv, &envp)
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't start Roblox (\(String(cString: strerror(rc))))."])
        }
        return pid
    }

    /// macOS equivalent of the Windows `ROBLOX_singletonEvent` trick.
    /// RobloxPlayer uses a named POSIX semaphore: a running client waits on it, and a newly
    /// started client posts to it, which makes the older client quit ("terminateWaiter").
    /// Unlinking the name before each launch leaves running clients holding an orphaned
    /// semaphore that nothing will post to, while the new client creates a fresh one.
    /// Harmless when the semaphore doesn't exist (Roblox's FFlagRemoveSingleInstanceSempahore
    /// currently disables the check for many users).
    static let singletonSemaphoreName = "/robloxPlayerStartedEvent"

    static func detachSingletonSemaphore() {
        _ = sem_unlink(singletonSemaphoreName)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Follow the main account

    var mainAccountID: Int64? {
        let v = UserDefaults.standard.object(forKey: "mainAccountID") as? NSNumber
        return v?.int64Value
    }

    var mainAccount: Account? { store.account(id: mainAccountID) }

    func setMain(_ account: Account?) {
        if let account {
            UserDefaults.standard.set(NSNumber(value: account.id), forKey: "mainAccountID")
        } else {
            UserDefaults.standard.removeObject(forKey: "mainAccountID")
        }
        mainPresence = nil
        followedGameId = nil
        pendingGameId = nil
        objectWillChange.send()
        pollMain()
    }

    var autoFollow: Bool { UserDefaults.standard.bool(forKey: "autoFollow") }

    /// Called when auto-follow is switched; the next reading becomes the new "home" server.
    func autoFollowChanged() {
        followedGameId = nil
        pendingGameId = nil
        followStatus = autoFollow ? "Auto-follow on. Alts will move when Main changes server." : ""
        pollMain()
    }

    /// Alts = every saved account except Main.
    var alts: [Account] { store.accounts.filter { $0.id != mainAccountID } }

    /// Checks where Main is every few seconds. With auto-follow on, a change of server
    /// (including teleports to another lobby or sub-place) moves the running alts there.
    func pollMain() {
        guard !polling, let main = mainAccount, let cookie = store.cookie(for: main) else {
            if mainAccount == nil { mainPresence = nil }
            return
        }
        polling = true
        Task {
            defer { polling = false }
            guard let p = try? await RobloxAPI.presence(cookie: cookie, userIds: [main.id]).first else { return }
            mainPresence = p

            guard autoFollow, p.isInGame, let gameId = p.gameId, let placeId = p.placeId else {
                pendingGameId = nil
                return
            }
            if followedGameId == nil {
                // First reading after turning auto-follow on: treat the current server as home.
                followedGameId = gameId
                return
            }
            guard gameId != followedGameId else { pendingGameId = nil; return }
            // Require the same new server on two polls in a row; presence can flicker mid-teleport.
            guard pendingGameId == gameId else { pendingGameId = gameId; return }
            pendingGameId = nil
            followedGameId = gameId
            await syncAlts(toPlace: placeId, gameId: gameId)
        }
    }

    /// Main moved: give the game a moment to teleport the party, then move any alt that's
    /// still somewhere else.
    private func syncAlts(toPlace placeId: Int64, gameId: String) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        let running = alts.filter { instance(for: $0.id) != nil }
        guard !running.isEmpty else { return }

        followStatus = "Main changed server. Waiting 20s in case the game brings the alts along…"
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        guard followedGameId == gameId else { return }   // Main moved again; the next sync handles it.

        var moved = 0
        for alt in running {
            guard let cookie = store.cookie(for: alt) else { continue }
            if let p = try? await RobloxAPI.presence(cookie: cookie, userIds: [alt.id]).first, p.gameId == gameId {
                continue  // already there
            }
            if let inst = instance(for: alt.id) {
                close(inst)
                await waitForExit(inst.pid, timeout: 8)
            }
            followStatus = "Moving \(alt.displayName) to Main's server…"
            await launchAccounts([alt], target: LaunchTarget(placeId: placeId, linkCode: nil, jobId: gameId))
            moved += 1
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
        followStatus = moved == 0 ? "All alts are with Main." : "Moved \(moved) alt\(moved == 1 ? "" : "s") to Main's server."
    }

    /// Launches the given alts (or every alt that isn't running) into Main's current server.
    func bringAltsToMain(_ selected: [Account]) {
        guard let main = mainAccount, let cookie = store.cookie(for: main) else {
            lastError = "Pick a Main account first (click the star next to it)."
            return
        }
        let targets = (selected.isEmpty ? alts.filter { instance(for: $0.id) == nil } : selected)
            .filter { $0.id != main.id }
        guard !targets.isEmpty else {
            lastError = "No alts to send. Select some accounts, or close an alt that's already running."
            return
        }
        Task {
            guard let p = try? await RobloxAPI.presence(cookie: cookie, userIds: [main.id]).first else {
                lastError = "Couldn't check where \(main.displayName) is. Try again in a moment."
                return
            }
            mainPresence = p
            guard p.isInGame else {
                lastError = "\(main.displayName) isn't in a game right now. Join one with Main first."
                return
            }
            let target: LaunchTarget
            if let gameId = p.gameId, let placeId = p.placeId {
                target = LaunchTarget(placeId: placeId, linkCode: nil, jobId: gameId)
                followedGameId = gameId
            } else {
                // Server ID hidden: let Roblox's "join friend" route find the server.
                target = LaunchTarget(placeId: p.placeId ?? 0, linkCode: nil, jobId: nil, followUserId: main.id)
            }
            followStatus = "Sending \(targets.count) alt\(targets.count == 1 ? "" : "s") to \(main.displayName)…"
            await launchAccounts(targets, target: target)
            followStatus = "Sent \(targets.count) alt\(targets.count == 1 ? "" : "s") to \(main.displayName)."
        }
    }

    private func waitForExit(_ pid: pid_t, timeout: TimeInterval) async {
        let end = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 && Date() < end {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        refresh()
    }

    // MARK: Window control

    func focus(_ inst: RobloxInstance) {
        guard let app = NSRunningApplication(processIdentifier: inst.pid) else { return }
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
    }

    func close(_ inst: RobloxInstance) {
        if let app = NSRunningApplication(processIdentifier: inst.pid), app.terminate() {
        } else {
            kill(inst.pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func closeAll() { instances.forEach(close) }
}

func formatUptime(_ since: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(since)))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
