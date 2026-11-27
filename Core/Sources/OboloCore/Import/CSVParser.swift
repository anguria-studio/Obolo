import Foundation

/// RFC 4180, by hand, in about a hundred lines.
///
/// Written rather than pulled in because the alternative is a package dependency for a
/// grammar with four rules, and because the two files this app must read — a Google
/// Sheets export and its own export — both contain quoted fields with commas in them
/// ("$20 + VAT, billed in USD") and would be silently mangled by a `split(separator:)`.
///
/// What it handles: quoted fields, embedded commas, embedded newlines, `""` as an
/// escaped quote, CRLF and LF and CR line endings, a UTF-8 BOM, and a final line with
/// or without a terminator. Whitespace *outside* quotes is trimmed from each field,
/// because spreadsheets leak it and no column here is whitespace-significant.
public enum CSVParser {

    /// Rows of fields, in file order. Blank lines are dropped — a spreadsheet export
    /// ending in a stray newline should not produce a phantom row.
    public static func parse(_ text: String) -> [[String]] {
        Array(Rows(text))
    }

    public static func parse(_ data: Data) -> [[String]] {
        Array(rows(data))
    }

    static func rows(_ data: Data) -> Rows {
        Rows(String(decoding: data, as: UTF8.self))
    }

    /// Reads one row at a time so a caller can validate the header before parsing the body.
    struct Rows: IteratorProtocol, Sequence {
        private let text: String
        private var cursor: String.Index

        fileprivate init(_ text: String) {
            self.text = text
            cursor = text.hasPrefix("\u{FEFF}") ? text.index(after: text.startIndex) : text.startIndex
        }

        mutating func next() -> [String]? {
            var row: [String] = []
            var field = ""
            var insideQuotes = false
            var wasQuoted = false

            func endField() {
                row.append(wasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
                field = ""
                wasQuoted = false
            }

            func endRow() -> [String]? {
                endField()
                // A single empty field is a blank line.
                if row.count == 1 && row[0].isEmpty {
                    row.removeAll(keepingCapacity: true)
                    return nil
                }
                return row
            }

            while cursor < text.endIndex {
                let character = text[cursor]
                text.formIndex(after: &cursor)

                if insideQuotes {
                    if character == "\"" {
                        // A doubled quote is a literal one. A single quote closes the field.
                        if cursor < text.endIndex && text[cursor] == "\"" {
                            field.append("\"")
                            text.formIndex(after: &cursor)
                        } else {
                            insideQuotes = false
                        }
                    } else {
                        field.append(CSVParser.isLineBreak(character) ? "\n" : character)
                    }
                    continue
                }

                switch character {
                case "\"":
                    insideQuotes = true
                    wasQuoted = true
                case ",":
                    endField()
                case _ where CSVParser.isLineBreak(character):
                    if let completed = endRow() { return completed }
                default:
                    field.append(character)
                }
            }

            return endRow()
        }
    }

    /// LF, CR, and the CRLF pair that Swift presents as one grapheme.
    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
    }

    // MARK: - Writing

    /// Quotes a field when — and only when — it would otherwise be ambiguous.
    public static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
            || field.hasPrefix(" ")
            || field.hasSuffix(" ")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Prevents a spreadsheet from interpreting a text cell as a formula.
    ///
    /// CSV quoting does not stop Excel or Sheets from running a value that starts with
    /// `=`, `+`, `-`, or `@`. A leading apostrophe does. Existing apostrophes are kept,
    /// and the importer removes only the one that this method adds.
    public static func spreadsheetSafe(_ field: String) -> String {
        startsSpreadsheetFormula(field) ? "'" + field : field
    }

    /// Removes one protection apostrophe from a spreadsheet-safe value.
    public static func spreadsheetValue(_ field: String) -> String {
        guard field.hasPrefix("'") else { return field }
        let remainder = String(field.dropFirst())
        return startsSpreadsheetFormula(remainder) ? remainder : field
    }

    private static func startsSpreadsheetFormula(_ field: String) -> Bool {
        let firstMeaningful = field.first { !$0.isWhitespace && $0 != "'" }
        guard let firstMeaningful else { return false }
        return "=+-@".contains(firstMeaningful)
    }

    public static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    /// LF line endings, one per row, with a trailing newline — what every tool on this
    /// platform expects, and what `parse` round-trips exactly.
    public static func serialize(_ rows: [[String]]) -> String {
        rows.map(line).joined(separator: "\n") + "\n"
    }
}
