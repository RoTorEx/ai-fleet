import Darwin
import Foundation

struct CodexProcess: Identifiable, Equatable {
    let pid: Int32
    let uid: UInt32
    let terminal: String
    let started: String
    let executable: String
    var id: String { "\(pid):\(started):\(executable)" }
    var isBackground: Bool { terminal == "??" || terminal == "?" || terminal == "-" }
    var detectedProvider: String? = nil
    var providerID: String { detectedProvider ?? (name == "claude" || executable.contains("/.local/share/claude/versions/") ? "claude" : "codex") }
    var name: String { URL(fileURLWithPath: executable).lastPathComponent }
    var startedLabel: String {
        guard let seconds = TimeInterval(started) else { return started }
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .standard)
    }
    var kind: String {
        if name == "codex-code-mode-host" { return "Code Mode helper" }
        return "\(providerID.capitalized) " + (isBackground ? "detached" : "terminal")
    }
}

enum CodexProcessControl {
    static func startIdentity(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              info.pbi_uid == getuid() else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    enum Failure: LocalizedError {
        case inventory, changed, signal(Int32), stillRunning
        var errorDescription: String? {
            switch self {
            case .inventory: return "Could not read the process list. Refresh and try again."
            case .changed: return "This process has exited or changed identity. Refresh before trying again."
            case .signal(let code): return "macOS refused to stop this process (error \(code))."
            case .stillRunning: return "The process is still running. You can use Force Quit after reviewing it."
            }
        }
    }

    static func inventory() throws -> [CodexProcess] { try allInventory().filter { $0.providerID == "codex" } }

    static func allInventory() throws -> [CodexProcess] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0 else { throw Failure.inventory }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 256)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, capacity)
        guard size > 0 else { throw Failure.inventory }
        return pids.prefix(Int(size) / MemoryLayout<Int32>.size).compactMap { pid in
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let pathError = length > 0 ? 0 : errno
            let livePath = length > 0 ? String(cString: buffer) : nil
            let runtime = livePath.map { isRuntime(URL(fileURLWithPath: $0).lastPathComponent) } ?? false
            let launch = pathError == ENOENT || runtime ? launchInfo(pid) : nil
            guard let executable = executablePath(live: livePath, error: pathError, launch: launch?.executable),
                  let provider = provider(executable: executable, script: launch?.entry, processName: launch?.name) else { return nil }
            // A process may exit or be replaced during metadata collection.
            guard startIdentity(pid) == "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)" else { return nil }
            let timestamp = "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
            let noTerminal = info.e_tdev == UInt32.max
            return CodexProcess(pid: pid, uid: info.pbi_uid, terminal: noTerminal ? "??" : "tty:\(info.e_tdev)",
                                started: timestamp, executable: executable, detectedProvider: provider)
        }.sorted { $0.pid < $1.pid }
    }

    static func executablePath(live: String?, error: Int32, launch: String?) -> String? {
        if let live { return live }
        guard error == ENOENT, let launch, launch.hasPrefix("/") else { return nil }
        return launch
    }

    private static func isRuntime(_ name: String) -> Bool {
        ["node", "bun", "python", "python3"].contains(name) || name.hasPrefix("python3.")
    }

    static func provider(executable: String, script: String?, processName: String? = nil) -> String? {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if ["codex", "codex-code-mode-host"].contains(name) { return "codex" }
        if let native = ProviderCatalog.all.first(where: { $0.id != "codex" && $0.executableNames.contains(name) }) { return native.id }
        let versions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/claude/versions").path
        if URL(fileURLWithPath: executable).deletingLastPathComponent().path == versions { return "claude" }
        guard isRuntime(name) else { return nil }
        // Node CLIs may replace argv with a provider process title.
        if let processName, let native = ProviderCatalog.all.first(where: { $0.executableNames.contains(URL(fileURLWithPath: processName).lastPathComponent) }) {
            return native.id
        }
        guard let script, script.hasPrefix("/") else { return nil }
        if let native = ProviderCatalog.all.first(where: { $0.executableNames.contains(URL(fileURLWithPath: script).lastPathComponent) }) {
            return native.id
        }
        let packages = ["/@openai/codex/": "codex", "/@anthropic-ai/claude-code/": "claude",
                        "/@moonshot-ai/kimi-code/": "kimi", "/@qwen-code/qwen-code/": "qwen",
                        "/@google/gemini-cli/": "gemini", "/@vibe-kit/grok-cli/": "grok"]
        if let provider = packages.first(where: { script.contains($0.key) })?.value { return provider }
        let entry = URL(fileURLWithPath: script).resolvingSymlinksInPath().path
        for provider in ProviderCatalog.all {
            guard let native = ProviderCatalog.executableURL(for: provider) else { continue }
            if native.resolvingSymlinksInPath().path == entry { return provider.id }
        }
        return nil
    }

    // Keep only the kernel executable and first two argv fields. Never export prompts/environment.
    private static func launchInfo(_ pid: Int32) -> (executable: String, name: String?, entry: String?)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard sysctl(&mib, 3, nil, &count, nil, 0) == 0, count > 4, count <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctl(&mib, 3, &bytes, &count, nil, 0) == 0 else { return nil }
        return decodeLaunchInfo(Array(bytes.prefix(count)))
    }

    static func decodeLaunchInfo(_ bytes: [UInt8]) -> (executable: String, name: String?, entry: String?)? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard (1...4096).contains(argc) else { return nil }
        var offset = 4
        func field() -> String? {
            let start = offset
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return String(bytes: bytes[start..<offset], encoding: .utf8)
        }
        guard let executable = field(), executable.hasPrefix("/") else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        guard let name = field() else { return nil }
        let entry = argc > 1 ? field() : nil
        return (executable, name, entry)
    }

    /// Re-read ownership, executable and start time immediately before signaling a single PID.
    static func stop(_ process: CodexProcess, force: Bool,
                     read: () throws -> [CodexProcess] = inventory,
                     signal: (Int32, Int32) -> Int32 = { kill($0, $1) }) throws {
        guard process.pid > 1, process.pid != getpid(), process.uid == getuid(),
              try read().contains(process) else { throw Failure.changed }
        guard signal(process.pid, force ? SIGKILL : SIGTERM) == 0 else { throw Failure.signal(errno) }
    }
}

@MainActor
final class CodexProcessesService: ObservableObject {
    @Published private(set) var processes: [CodexProcess] = []
    @Published private(set) var refreshing = false
    @Published private(set) var stopping = Set<String>()
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var timer: Timer?
    private var scan: Task<Void, Never>?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate(); timer = nil
        scan?.cancel(); scan = nil
        refreshing = false
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        scan = Task {
            let result = await Task.detached(priority: .utility) { Result { try CodexProcessControl.allInventory() } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let processes): self.processes = processes; error = nil
            case .failure(let failure): error = failure.localizedDescription
            }
            refreshing = false
        }
    }

    func terminate(_ targets: [CodexProcess], force: Bool) {
        guard stopping.isEmpty, !targets.isEmpty else { return }
        stopping = Set(targets.map(\.id)); error = nil; notice = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Int, [String], [CodexProcess]?) in
                var sent = 0, failures: [String] = []
                for process in targets {
                    do { try CodexProcessControl.stop(process, force: force, read: CodexProcessControl.allInventory); sent += 1 }
                    catch { failures.append("PID \(process.pid): \(error.localizedDescription)") }
                }
                // Observe actual exit; do not report a sent signal as a stopped process.
                var current: [CodexProcess]?
                for _ in 0..<10 {
                    current = try? CodexProcessControl.allInventory()
                    guard let current, targets.contains(where: { current.contains($0) }) else { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                return (sent, failures, current)
            }.value
            if let current = result.2 {
                processes = current
                let remaining = targets.filter { current.contains($0) }.count
                notice = remaining == 0 ? "Selected processes have exited." : "\(remaining) selected process(es) still running. Review and use Force Quit if needed."
            } else { notice = "Signal sent; could not verify process exit. Refresh to check." }
            error = result.1.isEmpty ? nil : result.1.joined(separator: "\n")
            stopping.removeAll()
        }
    }
}
