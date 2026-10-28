import AppKit
import CryptoKit
import Foundation

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    enum State: Equatable {
        case idle
        case checking
        case downloading(String)
        case installing(String)
        case upToDate(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?

    private init() {}

    var actionTitle: String {
        if case .failed = state { return "Retry update…" }
        return "Update…"
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func update() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            await performUpdate()
        }
    }

    private func performUpdate() async {
        var workspaceURL: URL?
        do {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                throw UpdateError.notInstalledApplication
            }

            state = .checking
            let release = try await ReleaseUpdater.latestRelease()
            let currentVersion = ReleaseUpdater.currentVersion
            guard ReleaseUpdater.isNewer(release.version, than: currentVersion) else {
                state = .upToDate(currentVersion)
                return
            }

            state = .downloading(release.version)
            let download = try await ReleaseUpdater.download(release)
            workspaceURL = download.workspaceURL

            state = .installing(release.version)
            let replacement = try await Task.detached {
                try ReleaseUpdater.prepare(download)
            }.value
            try installAndRelaunch(replacement)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? "Update failed.")
        }

        if let workspaceURL {
            try? FileManager.default.removeItem(at: workspaceURL)
        }
    }

    private func installAndRelaunch(_ replacement: URL) throws {
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.installLocationNotWritable
        }

        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: replacement,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.state = .failed("Updated, but relaunch failed: \(error.localizedDescription)")
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

enum ReleaseUpdater {
    private static let repository = "RoTorEx/ai-fleet"
    private static let bundleIdentifier = "dev.ai-fleet"

    struct Download: Sendable {
        let version: String
        let workspaceURL: URL
        let archiveURL: URL
        let checksumURL: URL
    }

    struct Release: Sendable {
        let version: String
        let archive: Asset
        let checksum: Asset
    }

    struct Asset: Sendable {
        let name: String
        let browserDownloadURL: URL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateVersion = AppSemanticVersion(candidate),
              let currentVersion = AppSemanticVersion(current) else { return false }
        return candidateVersion > currentVersion
    }

    static func latestRelease(session: URLSession = .shared) async throws -> Release {
        // The public release redirect also powers the terminal installer and avoids
        // GitHub's shared unauthenticated API allowance.
        let url = URL(string: "https://github.com/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("AI-Fleet/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) }
        catch { throw UpdateError.requestFailed("Update check", error.localizedDescription) }
        try validate(response, operation: "Update check")
        guard let final = response.url, final.scheme == "https", final.host == "github.com",
              final.path.hasPrefix("/\(repository)/releases/tag/v") else { throw UpdateError.invalidRelease }
        let tag = final.lastPathComponent
        let version = String(tag.dropFirst())
        guard tag.hasPrefix("v"), isSemanticVersion(version),
              final.path == "/\(repository)/releases/tag/\(tag)" else { throw UpdateError.invalidRelease }
        let basename = "AIFleet-\(tag)-macos-\(architecture).zip"
        let base = "https://github.com/\(repository)/releases/download/\(tag)/"
        return Release(version: version,
            archive: Asset(name: basename, browserDownloadURL: URL(string: base + basename)!),
            checksum: Asset(name: basename + ".sha256", browserDownloadURL: URL(string: base + basename + ".sha256")!))
    }

    static func download(_ release: Release) async throws -> Download {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AI-Fleet-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        do {
            async let archiveURL = download(release.archive, to: workspaceURL)
            async let checksumURL = download(release.checksum, to: workspaceURL)
            return try await Download(
                version: release.version,
                workspaceURL: workspaceURL,
                archiveURL: archiveURL,
                checksumURL: checksumURL
            )
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            throw error
        }
    }

    static func prepare(_ download: Download) throws -> URL {
        let expectedChecksum = try String(contentsOf: download.checksumURL, encoding: .utf8)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
        guard let expectedChecksum,
              expectedChecksum.count == 64,
              expectedChecksum.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.invalidChecksum
        }
        guard try sha256(of: download.archiveURL) == expectedChecksum.lowercased() else {
            throw UpdateError.checksumMismatch
        }

        let extractionURL = download.workspaceURL.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", arguments: ["-x", "-k", download.archiveURL.path, extractionURL.path])

        let applicationURL = extractionURL.appendingPathComponent("AIFleet.app", isDirectory: true)
        let plistURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil)
            as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier,
              plist["CFBundleShortVersionString"] as? String == download.version else {
            throw UpdateError.invalidApplicationBundle
        }

        try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", applicationURL.path])
        return applicationURL
    }

    private static var architecture: String {
        #if arch(arm64)
        return "aarch64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    private static func isSemanticVersion(_ version: String) -> Bool {
        AppSemanticVersion(version) != nil
    }

    private static func download(_ asset: Asset, to directory: URL) async throws -> URL {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("AI-Fleet/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let temporaryURL: URL
        let response: URLResponse
        do { (temporaryURL, response) = try await URLSession.shared.download(for: request) }
        catch { throw UpdateError.requestFailed("Release download", error.localizedDescription) }
        try validate(response, operation: "Release download")

        let destination = directory.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    static func validate(_ response: URLResponse, operation: String) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateError.requestFailed(operation, "Invalid server response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpFailure(operation, http.statusCode)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = try? errorPipe.fileHandleForReading.readToEnd()
            let detail = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.validationFailed(detail)
        }
    }
}

struct AppSemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  part == "0" || !part.hasPrefix("0") else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

private enum UpdateError: LocalizedError {
    case notInstalledApplication
    case installLocationNotWritable
    case invalidRelease
    case missingReleaseAsset
    case httpFailure(String, Int)
    case requestFailed(String, String)
    case invalidChecksum
    case checksumMismatch
    case invalidApplicationBundle
    case validationFailed(String?)

    var errorDescription: String? {
        switch self {
        case .notInstalledApplication:
            return "Updates are available from the installed AI Fleet.app."
        case .installLocationNotWritable:
            return "AI Fleet cannot replace the app in its current folder."
        case .invalidRelease:
            return "GitHub returned an invalid release."
        case .missingReleaseAsset:
            return "The latest release has no build for this Mac."
        case .httpFailure(let operation, let code):
            return "\(operation) failed (HTTP \(code)). Retry update."
        case .requestFailed(let operation, let reason):
            return "\(operation) failed: \(reason)"
        case .invalidChecksum:
            return "The release checksum is invalid."
        case .checksumMismatch:
            return "The downloaded release failed checksum verification."
        case .invalidApplicationBundle:
            return "The downloaded application bundle is invalid."
        case .validationFailed(let detail):
            return detail.map { "Release validation failed: \($0)" } ?? "Release validation failed."
        }
    }
}
