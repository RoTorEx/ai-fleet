import CryptoKit
import Foundation

struct UsageJournalTimestamps {
    private let plain = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func date(from value: String) -> Date? { fractional.date(from: value) ?? plain.date(from: value) }
}

struct UsageJournalState: Codable, Equatable {
    var entries: [CodexUsageLogEntry] = []
    var keyedEntries: [String: CodexUsageLogEntry] = [:]
    var model = "Unknown model"
    var previousCumulative: [String: Int]?
    var seenCounters: Set<String> = []
    var legacyTurn = 0
    var legacyStep = ""
    var partial = false

    var accounting: [CodexUsageLogEntry] {
        if keyedEntries.isEmpty { return entries }
        return keyedEntries.sorted { a, b in
            a.value.timestamp == b.value.timestamp ? a.key < b.key : a.value.timestamp < b.value.timestamp
        }.map(\.value)
    }

    var eventCount: Int { entries.count + keyedEntries.count }
}

struct UsageJournalCheckpoint: Codable, Equatable {
    let byteCount: Int
    let digest: Data
    let lines: Int
    let state: UsageJournalState
}

struct ParsedUsageJournal {
    var entries: [CodexUsageLogEntry] = []
    var issue: String?
    var unreadable = false
    var checkpoint: UsageJournalCheckpoint?
    var resumed = false

    static func unavailable(_ file: URL) -> Self {
        Self(issue: "Unreadable source: " + file.path, unreadable: true)
    }
}

/// The checkpoint contains accounting, parser context and a digest of a complete
/// byte prefix. A changed prefix is replayed even if the file grew in place.
func readUsageJournal(
    _ file: URL, checkpoint: UsageJournalCheckpoint? = nil, saveCheckpoint: Bool = false,
    consume: (inout UsageJournalState, Data, Int) -> Void
) -> ParsedUsageJournal {
    do {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard let length = Int(exactly: size) else { return .unavailable(file) }
        try handle.seek(toOffset: 0)

        var state = UsageJournalState()
        var offset = 0
        var lines = 0
        var digest = SHA256()
        // Read a stable prefix in bounded chunks. Raw verification is cheaper
        // than decoding previous records and also detects rewrites with growth.
        if let checkpoint, checkpoint.byteCount > 0, checkpoint.byteCount <= length {
            try readUsageBytes(handle, count: checkpoint.byteCount) { digest.update(data: $0) }
            if Data(digest.finalize()) == checkpoint.digest {
                state = checkpoint.state
                offset = checkpoint.byteCount
                lines = checkpoint.lines
            } else {
                try handle.seek(toOffset: 0)
                digest = SHA256()
            }
        }

        var trailing = Data()
        try readUsageBytes(handle, count: length - offset) { chunk in
            if saveCheckpoint { digest.update(data: chunk) }
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 10) {
                if trailing.isEmpty {
                    if start < end {
                        autoreleasepool { consume(&state, chunk[start..<end], lines) }
                        lines += 1
                    }
                } else {
                    trailing.append(chunk[start..<end])
                    autoreleasepool { consume(&state, trailing, lines) }
                    lines += 1
                    trailing = Data()
                }
                start = end + 1
            }
            trailing.append(chunk[start...])
        }
        let saved = saveCheckpoint && trailing.isEmpty && length > 0
            ? UsageJournalCheckpoint(byteCount: length, digest: Data(digest.finalize()), lines: lines, state: state)
            : nil
        // A valid unterminated final record is usable, but may change as a
        // writer finishes the line. Resume only from newline-terminated data.
        if !trailing.isEmpty { autoreleasepool { consume(&state, trailing, lines) } }
        return ParsedUsageJournal(entries: state.accounting,
            issue: state.partial ? "Partial accounting source: " + file.path : nil,
            checkpoint: saved, resumed: offset > 0)
    } catch {
        return .unavailable(file)
    }
}

func readUsageBytes(_ handle: FileHandle, count: Int, consume: (Data) throws -> Void) throws {
    var remaining = count
    while remaining > 0 {
        let chunk = try autoreleasepool { try handle.read(upToCount: min(64 * 1024, remaining)) }
        guard let chunk, !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try consume(chunk)
        remaining -= chunk.count
    }
}
