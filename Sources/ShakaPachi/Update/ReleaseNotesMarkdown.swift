// ReleaseNotesMarkdown.swift
// Block-level markdown parser for GitHub release notes.
// Hand-rolled rather than pulling in a dependency: release notes only need
// headings, lists, blockquotes, fenced code, tables and horizontal rules —
// not a full CommonMark implementation. Inline syntax (bold, links, code
// spans) is left to Foundation's AttributedString(markdown:) at the render
// site (see UpdateWindow.swift); this file only splits text into blocks.

import Foundation

// MARK: - Block model

/// The marker a list item was introduced with.
enum ReleaseNoteListMarker: Equatable {
    case bullet
    case ordered(Int)
}

/// Per-column text alignment for a table, taken from the delimiter row
/// (`:---` leading, `:---:` center, `---:` trailing, plain `---` leading).
enum ReleaseNoteTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

/// A parsed GFM table: header cells, one alignment per header column, and
/// body rows (each padded/truncated to the header's column count).
struct ReleaseNoteTable: Equatable {
    let header: [String]
    let alignments: [ReleaseNoteTableAlignment]
    let rows: [[String]]
}

/// One block-level element of a release note. Inline markdown (bold, links,
/// code spans) is NOT resolved here — every `String`/`[String]` payload still
/// carries raw inline syntax for the caller to render.
enum ReleaseNoteBlock: Equatable {
    case heading(level: Int, text: String)
    case listItem(indent: Int, marker: ReleaseNoteListMarker, text: String)
    case paragraph(String)
    case quote([String])
    case table(ReleaseNoteTable)
    case code(String)
    case rule
    case blank
}

// MARK: - ReleaseNotesMarkdown

enum ReleaseNotesMarkdown {

    /// Parses release-note markdown into a flat list of block-level elements.
    /// Line-based: paragraphs are intentionally NOT joined across soft-wrapped
    /// lines, since the notes are Japanese and joining with a space would
    /// insert a stray space between characters that should stay adjacent.
    static func parse(_ notes: String) -> [ReleaseNoteBlock] {
        let lines = notes.components(separatedBy: "\n")
        var blocks: [ReleaseNoteBlock] = []
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                blocks.append(.blank)
                index += 1
                continue
            }

            if let fence = fenceMarker(trimmed) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces) == fence {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            // Table: current line contains "|" and the next line is a delimiter
            // row. Checked before the horizontal-rule test below so a delimiter
            // row such as "|---|---|" is never mistaken for a rule.
            if trimmed.contains("|"), index + 1 < lines.count,
                let alignments = tableDelimiterAlignments(lines[index + 1])
            {
                let header = splitTableRow(trimmed)
                let columnCount = header.count
                let paddedAlignments = pad(alignments, to: columnCount, with: .leading)
                index += 2  // consume header + delimiter
                var rows: [[String]] = []
                while index < lines.count {
                    let bodyLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard bodyLine.contains("|") else { break }
                    rows.append(pad(splitTableRow(bodyLine), to: columnCount, with: ""))
                    index += 1
                }
                blocks.append(.table(ReleaseNoteTable(header: header, alignments: paddedAlignments, rows: rows)))
                continue
            }

            if isHorizontalRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    var remainder = line.dropFirst()
                    if remainder.hasPrefix(" ") {
                        remainder.removeFirst()
                    }
                    quoteLines.append(String(remainder))
                    index += 1
                }
                blocks.append(.quote(quoteLines))
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                let rest = trimmed.dropFirst(hashes.count)
                if (1...6).contains(hashes.count), rest.hasPrefix(" ") {
                    let text = rest.drop(while: { $0 == " " })
                    blocks.append(.heading(level: hashes.count, text: String(text)))
                    index += 1
                    continue
                }
                // Falls through to paragraph: no space after "#" (e.g. "#hashtag"),
                // or more than 6 "#" — neither is a valid heading.
            }

            let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count
            let indent = min(leadingSpaces / 2, 3)

            if let text = bulletText(trimmed) {
                blocks.append(.listItem(indent: indent, marker: .bullet, text: text))
                index += 1
                continue
            }

            if let (number, text) = orderedListItem(trimmed) {
                blocks.append(.listItem(indent: indent, marker: .ordered(number), text: text))
                index += 1
                continue
            }

            blocks.append(.paragraph(trimmed))
            index += 1
        }

        return blocks
    }

    // MARK: - Line classifiers

    /// Returns the fence string (e.g. "```" or "~~~~") if `line` opens a
    /// fenced code block, ignoring any trailing language annotation.
    private static func fenceMarker(_ line: String) -> String? {
        if line.hasPrefix("```") {
            return String(line.prefix(while: { $0 == "`" }))
        }
        if line.hasPrefix("~~~") {
            return String(line.prefix(while: { $0 == "~" }))
        }
        return nil
    }

    /// A line of only `-`, `*` or `_`, repeated 3 or more times.
    private static func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func orderedListItem(_ line: String) -> (Int, String)? {
        guard let match = line.range(of: "^\\d+\\.\\s", options: .regularExpression) else { return nil }
        let digits = line[line.startIndex..<match.upperBound].prefix(while: { $0.isNumber })
        return (Int(digits) ?? 0, String(line[match.upperBound...]))
    }

    // MARK: - Table helpers

    /// Splits a row on "|", dropping the empty leading/trailing cell produced
    /// by outer pipes (e.g. "| a | b |") and trimming each remaining cell.
    private static func splitTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Returns per-column alignments if `line` is a valid table delimiter row
    /// (every cell matches `^:?-{1,}:?$`), or nil otherwise.
    ///
    /// The "|" requirement is what keeps a plain "---" from being read as a
    /// single-column delimiter: without it, any line containing a pipe that
    /// happens to precede a horizontal rule would swallow the rule and turn
    /// into an empty table.
    private static func tableDelimiterAlignments(_ line: String) -> [ReleaseNoteTableAlignment]? {
        guard line.contains("|") else { return nil }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [ReleaseNoteTableAlignment] = []
        for cell in cells {
            guard cell.range(of: "^:?-{1,}:?$", options: .regularExpression) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)  // ":---" leading and plain "---" leading
            }
        }
        return alignments
    }

    private static func pad<T>(_ array: [T], to count: Int, with value: T) -> [T] {
        if array.count < count {
            return array + Array(repeating: value, count: count - array.count)
        }
        return Array(array.prefix(count))
    }
}
