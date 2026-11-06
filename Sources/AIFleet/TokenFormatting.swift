import Foundation

struct BookTokenComparison: Equatable {
    let title: String
    let approximateWords: Int
}

let bookTokenComparisons: [BookTokenComparison] = [
    BookTokenComparison(title: "The Little Prince", approximateWords: 16_500),
    BookTokenComparison(title: "The Hobbit", approximateWords: 95_000),
    BookTokenComparison(title: "the complete Lord of the Rings trilogy", approximateWords: 481_000),
    BookTokenComparison(title: "the complete seven-book Harry Potter series", approximateWords: 1_084_000),
    BookTokenComparison(title: "Dune", approximateWords: 188_000),
    BookTokenComparison(title: "1984", approximateWords: 89_000),
    BookTokenComparison(title: "Brave New World", approximateWords: 64_000),
    BookTokenComparison(title: "A Game of Thrones", approximateWords: 298_000),
    BookTokenComparison(title: "The Name of the Wind", approximateWords: 259_000),
    BookTokenComparison(title: "American Gods", approximateWords: 183_000),
    BookTokenComparison(title: "The Hitchhiker's Guide to the Galaxy", approximateWords: 46_000),
    BookTokenComparison(title: "Ender's Game", approximateWords: 101_000),
    BookTokenComparison(title: "Neuromancer", approximateWords: 79_000),
    BookTokenComparison(title: "The Martian", approximateWords: 105_000),
    BookTokenComparison(title: "Fahrenheit 451", approximateWords: 46_000)
]

enum TokenHelpMetric: Equatable {
    case accountTotal
    case total
    case input
    case output

    var explanation: String {
        switch self {
        case .accountTotal:
            return "Account-wide Codex token activity reported by OpenAI. It follows your ChatGPT account and can include work whose session files are no longer stored on this Mac. OpenAI does not split this account total into input, output, or models here."
        case .total:
            return "Total tokens cover everything the model processed—not only what you typed. Total is Input + Output."
        case .input:
            return "Input tokens cover everything the model read: your messages, instructions, earlier conversation, files, tool results, and cached context."
        case .output:
            return "Output tokens cover everything the model generated: replies and actions returned to you, plus internal reasoning reported by Codex. Reasoning is usually not visible."
        }
    }

    var cacheNote: String {
        switch self {
        case .accountTotal, .total, .input:
            return " Cached context can be counted repeatedly, so this is processed text rather than unique reading."
        case .output:
            return ""
        }
    }
}

func tokenVolumeHelpExamples(_ tokens: Int, metric: TokenHelpMetric = .total) -> [String] {
    let words = Double(max(0, tokens)) * 0.75
    return bookTokenComparisons.map { book in
        let copies = words / Double(book.approximateWords)
        let formattedWords = groupedInteger(book.approximateWords)
        let comparison = bookCopyComparison(copies, title: book.title)
        return "\(metric.explanation)\n\nFor a sense of scale, that is \(comparison) (~\(formattedWords) words each). Book lengths and the token-to-text conversion are approximate.\(metric.cacheNote) Hover again for another book."
    }
}

func bookCopyComparison(_ copies: Double, title: String) -> String {
    guard copies >= 0.5 else { return "less than one copy of \(title)" }
    let roundedCopies = Int(copies.rounded())
    if roundedCopies == 1 { return "roughly one copy of \(title)" }
    return "roughly \(groupedInteger(roundedCopies)) copies of \(title)"
}

func groupedInteger(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal; formatter.groupingSeparator = " "
    formatter.usesGroupingSeparator = true; formatter.groupingSize = 3
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

func formattedNumber(_ value: Double, fractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = " "
    formatter.groupingSize = 3
    formatter.secondaryGroupingSize = 3
    formatter.decimalSeparator = "."
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}


func compactCount(_ value: Int) -> String {
    let magnitude = Decimal(value.magnitude)
    for (threshold, unit, digits) in [(1_000_000_000, "B", 2), (1_000_000, "M", 2), (1_000, "K", 1)] {
        var scaled = magnitude / Decimal(threshold)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, digits, .plain)
        if magnitude >= Decimal(threshold) || (unit != "K" && (unit == "B" ? magnitude >= 999_995_000 : magnitude >= 999_950)) {
            let number = NumberFormatter()
            number.locale = Locale(identifier: "en_US_POSIX")
            number.minimumFractionDigits = digits; number.maximumFractionDigits = digits
            number.decimalSeparator = "."; number.groupingSeparator = " "
            number.usesGroupingSeparator = true; number.numberStyle = .decimal
            return (number.string(from: NSDecimalNumber(decimal: Decimal(value) / Decimal(threshold))) ?? "—") + unit
        }
    }
    return groupedInteger(value)
}
func billionsCount(_ value: Int) -> String { compactCount(value) }
func millionsCount(_ value: Int) -> String { compactCount(value) }

struct TokenBookScale: Equatable {
    let title: String
    let approximateWords: Int
    let copies: Double
    let metric: TokenHelpMetric
    static func comparisons(tokens: Int, metric: TokenHelpMetric) -> [TokenBookScale] {
        guard tokens > 0 else { return [] }
        return bookTokenComparisons.map { TokenBookScale(title: $0.title, approximateWords: $0.approximateWords,
            copies: Double(tokens) * 0.75 / Double($0.approximateWords), metric: metric) }
    }
}
