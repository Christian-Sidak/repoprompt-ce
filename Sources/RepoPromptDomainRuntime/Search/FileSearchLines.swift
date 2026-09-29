import Foundation

/// The line model of the app's `file_search` content scan (`SearchLineIndex` and the PCRE2 line
/// scanners), for headless `file_search`: a line ends at LF, CR, or CRLF (one terminator); a trailing
/// terminator starts no further line, so an empty text has no lines. No other character (vertical
/// tab, form feed, U+0085, U+2028, U+2029) ends a line.
package enum FileSearchLines {
    package static func lines(of text: String) -> [Substring] {
        let utf8 = text.utf8
        var lines: [Substring] = []
        var lineStart = utf8.startIndex
        var index = utf8.startIndex
        // LF and CR are ASCII, so they never occur inside a multi-byte scalar, and a grapheme break
        // always falls before and after them: every slice bound is a character boundary.
        while index < utf8.endIndex {
            let byte = utf8[index]
            guard byte == 10 || byte == 13 else {
                index = utf8.index(after: index)
                continue
            }
            lines.append(text[lineStart ..< index])
            var next = utf8.index(after: index)
            if byte == 13, next < utf8.endIndex, utf8[next] == 10 {
                next = utf8.index(after: next)
            }
            lineStart = next
            index = next
        }
        if lineStart < utf8.endIndex {
            lines.append(text[lineStart...])
        }
        return lines
    }
}
