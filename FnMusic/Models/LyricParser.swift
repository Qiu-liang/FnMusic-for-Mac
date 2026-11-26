import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double?
    let text: String
}

struct ParsedLyrics: Sendable {
    let lines: [LyricLine]
    private let timedIndices: [(index: Int, time: Double)]
    var isTimed: Bool { !timedIndices.isEmpty }

    init(lines: [LyricLine]) {
        self.lines = lines
        timedIndices = lines.enumerated().compactMap { index, line in
            line.time.map { (index: index, time: $0) }
        }.sorted { $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time }
    }

    func currentIndex(at seconds: Double) -> Int? {
        // Search only real timestamps, returning the index in the displayed lines.
        var low = 0
        var high = timedIndices.count
        while low < high {
            let middle = (low + high) / 2
            if timedIndices[middle].time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? timedIndices[low - 1].index : nil
    }
}

enum LyricParser {
    static func parse(_ lyric: Lyric) -> ParsedLyrics {
        let source = (lyric.content ?? "").components(separatedBy: .newlines)
        let offsetPattern = #"\[offset:([+-]?\d+)\]"#
        let stampPattern = #"\[(\d{1,3}):(\d{1,2})(?:[\.:](\d{1,3}))?\]"#
        // Enhanced LRC adds per-word timing (`<00:17.42>You <00:17.69>jump`).
        // Those markers are not lyrics and must never reach the display.
        let wordStampPattern = #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#
        guard let stamp = try? NSRegularExpression(pattern: stampPattern),
              let offsetRegex = try? NSRegularExpression(pattern: offsetPattern, options: .caseInsensitive) else {
            return plain(source)
        }
        let wordStamp = try? NSRegularExpression(pattern: wordStampPattern)
        var embeddedOffset: Double = 0
        for line in source {
            let ns = line as NSString
            if let match = offsetRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let value = Double(ns.substring(with: match.range(at: 1))) { embeddedOffset = value }
        }
        // LRC convention: positive offset advances the displayed lyric. Server
        // offset is applied as the same local display adjustment; no writeback.
        let adjustment = ((lyric.offset ?? 0) + embeddedOffset) / 1_000
        var timed: [(time: Double, text: String, order: Int, untimed: [String])] = []
        var fallback: [String] = []
        for line in source {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let rich = parseRichLine(trimmed) {
                timed.append((rich.time - adjustment, clean(rich.text, wordStamp: wordStamp), timed.count, []))
                continue
            }
            let ns = trimmed as NSString
            let matches = stamp.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                let text = clean(stamp.stringByReplacingMatches(in: trimmed, range: NSRange(location: 0, length: ns.length), withTemplate: ""),
                                 wordStamp: wordStamp)
                for match in matches {
                    guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                          let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                    var fraction: Double = 0
                    let range = match.range(at: 3)
                    if range.location != NSNotFound {
                        let digits = ns.substring(with: range)
                        fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                    }
                    timed.append((minutes * 60 + seconds + fraction - adjustment, text, timed.count, []))
                }
            } else if !isMetadata(trimmed) {
                if timed.isEmpty {
                    fallback.append(clean(trimmed, wordStamp: wordStamp))
                } else {
                    // Keep translations/continuations beside the preceding timed
                    // entry when sorting, without giving them its timestamp.
                    let continuation = clean(trimmed, wordStamp: wordStamp)
                    if !continuation.isEmpty { timed[timed.count - 1].untimed.append(continuation) }
                }
            }
        }
        guard !timed.isEmpty else { return plain(fallback) }
        let sorted = timed.sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var lines = plain(fallback).lines
        for line in sorted {
            lines.append(LyricLine(id: lines.count, time: line.time, text: line.text.isEmpty ? "♪" : line.text))
            for text in line.untimed {
                lines.append(LyricLine(id: lines.count, time: nil, text: text))
            }
        }
        return ParsedLyrics(lines: lines)
    }

    /// Strips enhanced-LRC per-word markers and trims the result. Lyrics that
    /// legitimately contain angle brackets (e.g. `<3`) survive because the
    /// pattern only matches digit:digit timing shapes.
    private static func clean(_ text: String, wordStamp: NSRegularExpression?) -> String {
        var result = text
        if let wordStamp {
            let ns = result as NSString
            result = wordStamp.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plain(_ lines: [String]) -> ParsedLyrics {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ParsedLyrics(lines: lines.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) })
    }

    private static func isMetadata(_ line: String) -> Bool {
        ["[ti:", "[ar:", "[al:", "[by:", "[offset:", "[re:", "[ve:", "[length:"].contains { line.lowercased().hasPrefix($0) }
    }

    private static func parseRichLine(_ line: String) -> (time: Double, text: String)? {
        struct RichLine: Decodable {
            let t: Double
            let c: [Fragment]
            struct Fragment: Decodable { let tx: String? }
        }
        guard line.hasPrefix("{"), let decoded = try? JSONDecoder().decode(RichLine.self, from: Data(line.utf8)) else { return nil }
        let text = decoded.c.compactMap(\.tx).joined()
        guard !text.isEmpty else { return nil }
        return (decoded.t / 1_000, text)
    }
}
