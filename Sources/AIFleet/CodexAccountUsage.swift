import Foundation

struct CodexAccountDailyUsage: Codable, Identifiable, Equatable {
    let day: Date
    let tokens: Int

    var id: Date { day }
}

struct CodexAccountUsage: Codable, Equatable {
    let lifetimeTokens: Int?
    let peakDailyTokens: Int?
    let longestRunningTurnSeconds: Int?
    let currentStreakDays: Int?
    let longestStreakDays: Int?
    let daily: [CodexAccountDailyUsage]
    let fetchedAt: Date
}

enum CodexAccountUsageReaderError: Error, Equatable {
    case codexUnavailable
    case launchFailed
    case timedOut
    case invalidResponse
    case server(String)
}

struct CodexAccountUsageReader {
    var executableURL: URL? = ProviderCatalog.executableURL(for: ProviderCatalog.codex)
    var timeout: TimeInterval = 15
    var calendar = Calendar.autoupdatingCurrent

    func read(fetchedAt: Date = Date()) throws -> CodexAccountUsage {
        guard let executableURL else { throw CodexAccountUsageReaderError.codexUnavailable }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let responseReady = DispatchSemaphore(value: 0)
        let collector = CodexUsageResponseCollector()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in responseReady.signal() }

        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty || collector.ingest(data) {
                responseReady.signal()
            }
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            throw CodexAccountUsageReaderError.launchFailed
        }

        defer {
            outputHandle.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let requests = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"ai_fleet","title":"AI Fleet","version":"1.0.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/usage/read","id":1}"#
        ].joined(separator: "\n") + "\n"
        inputPipe.fileHandleForWriting.write(Data(requests.utf8))

        guard responseReady.wait(timeout: .now() + timeout) == .success else {
            throw CodexAccountUsageReaderError.timedOut
        }
        guard let response = collector.currentResponse() else {
            throw CodexAccountUsageReaderError.invalidResponse
        }
        return try decode(response: response, fetchedAt: fetchedAt, calendar: calendar)
    }

    func decode(response: Data, fetchedAt: Date, calendar: Calendar) throws -> CodexAccountUsage {
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw CodexAccountUsageReaderError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw CodexAccountUsageReaderError.server(error["message"] as? String ?? "Unknown error")
        }
        guard let result = object["result"] else {
            throw CodexAccountUsageReaderError.invalidResponse
        }

        let resultData = try JSONSerialization.data(withJSONObject: result)
        let payload = try JSONDecoder().decode(AccountUsagePayload.self, from: resultData)
        let daily = payload.dailyUsageBuckets?.compactMap { bucket -> CodexAccountDailyUsage? in
            guard let day = Self.day(from: bucket.startDate, calendar: calendar) else { return nil }
            return CodexAccountDailyUsage(day: day, tokens: bucket.tokens)
        }.sorted { $0.day < $1.day } ?? []

        return CodexAccountUsage(
            lifetimeTokens: payload.summary.lifetimeTokens,
            peakDailyTokens: payload.summary.peakDailyTokens,
            longestRunningTurnSeconds: payload.summary.longestRunningTurnSec,
            currentStreakDays: payload.summary.currentStreakDays,
            longestStreakDays: payload.summary.longestStreakDays,
            daily: daily,
            fetchedAt: fetchedAt
        )
    }

    private static func day(from value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

private final class CodexUsageResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var response: Data?

    func currentResponse() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }

    func ingest(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard response == nil else { return true }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 1 else {
                continue
            }
            response = line
            return true
        }
        return false
    }
}

private struct AccountUsagePayload: Decodable {
    struct Summary: Decodable {
        let lifetimeTokens: Int?
        let peakDailyTokens: Int?
        let longestRunningTurnSec: Int?
        let currentStreakDays: Int?
        let longestStreakDays: Int?
    }

    struct DailyBucket: Decodable {
        let startDate: String
        let tokens: Int
    }

    let summary: Summary
    let dailyUsageBuckets: [DailyBucket]?
}
