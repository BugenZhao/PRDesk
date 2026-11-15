import Foundation

/// One piece of a PR or issue title as drawn: part of its leading tags (dimmed) or of the subject,
/// and inline code or plain text.
struct TitlePiece: Hashable, Sendable {
    var text: String
    var isPrefix: Bool
    var isCode: Bool
}

/// The little markdown GitHub renders in titles: inline code between backticks.
enum TitleMarkup {
    static func pieces(_ title: String) -> [TitlePiece] {
        let (prefix, rest) = TitlePrefix.split(title)
        return codeSpans(prefix).map { TitlePiece(text: String($0.text), isPrefix: true, isCode: $0.isCode) }
            + codeSpans(rest).map { TitlePiece(text: String($0.text), isPrefix: false, isCode: $0.isCode) }
    }

    /// Splits text at code spans, CommonMark style: a run of backticks opens one that the next run
    /// of exactly as many closes, and a run that nothing closes is plain text. One space on each
    /// side of the code is dropped when both are there (`` ` `a` ` `` shows `` `a` ``).
    static func codeSpans(_ text: Substring) -> [(text: Substring, isCode: Bool)] {
        var spans: [(text: Substring, isCode: Bool)] = []
        var plainStart = text.startIndex
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "`") {
            let openEnd = backtickRunEnd(text, from: open)
            let length = text.distance(from: open, to: openEnd)
            var close: Range<Substring.Index>?
            var search = openEnd
            while let start = text[search...].firstIndex(of: "`") {
                let end = backtickRunEnd(text, from: start)
                if text.distance(from: start, to: end) == length {
                    close = start ..< end
                    break
                }
                search = end
            }
            guard let close else {
                index = openEnd
                continue
            }
            if plainStart < open { spans.append((text[plainStart ..< open], false)) }
            var code = text[openEnd ..< close.lowerBound]
            if code.count > 1, code.first == " ", code.last == " ", code.contains(where: { $0 != " " }) {
                code = code.dropFirst().dropLast()
            }
            spans.append((code, true))
            index = close.upperBound
            plainStart = index
        }
        if plainStart < text.endIndex { spans.append((text[plainStart...], false)) }
        return spans
    }

    private static func backtickRunEnd(_ text: Substring, from start: Substring.Index) -> Substring.Index {
        text[start...].firstIndex { $0 != "`" } ?? text.endIndex
    }
}
