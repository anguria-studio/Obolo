import Foundation
import Testing
@testable import OboloCore

/// RFC 4180, one rule per test.
///
/// The reference file has a notes column containing "$20 + VAT, billed in USD" — a
/// comma inside a quoted field. A parser that splits on commas turns that one row into
/// two broken ones, silently, which is why this grammar is implemented rather than
/// approximated.
@Suite("CSV parsing")
struct CSVParserTests {

    @Test("Plain rows split on commas")
    func plainRows() {
        #expect(CSVParser.parse("a,b,c\n1,2,3\n") == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test("A quoted field keeps its commas")
    func quotedCommas() {
        #expect(CSVParser.parse("name,notes\nSpotify,\"Billed in USD, converted at the stored rate\"\n")
                == [["name", "notes"], ["Spotify", "Billed in USD, converted at the stored rate"]])
    }

    @Test("A quoted field keeps its newlines")
    func quotedNewlines() {
        let rows = CSVParser.parse("name,notes\nThing,\"first line\nsecond line\"\nOther,x\n")
        #expect(rows.count == 3)
        #expect(rows[1] == ["Thing", "first line\nsecond line"])
        #expect(rows[2] == ["Other", "x"])
    }

    @Test("A doubled quote inside a quoted field is one literal quote")
    func escapedQuotes() {
        #expect(CSVParser.parse("a\n\"He said \"\"hi\"\"\"\n") == [["a"], ["He said \"hi\""]])
    }

    @Test("CRLF, LF and a lone CR all end a row")
    func lineEndings() {
        let expected = [["a", "b"], ["1", "2"]]
        #expect(CSVParser.parse("a,b\r\n1,2\r\n") == expected)
        #expect(CSVParser.parse("a,b\n1,2\n") == expected)
        #expect(CSVParser.parse("a,b\r1,2\r") == expected)
    }

    @Test("A final row without a trailing newline is still a row")
    func missingTrailingNewline() {
        #expect(CSVParser.parse("a,b\n1,2") == [["a", "b"], ["1", "2"]])
    }

    @Test("Empty fields are preserved, including a trailing one")
    func emptyFields() {
        #expect(CSVParser.parse("a,b,c\n1,,3\n") == [["a", "b", "c"], ["1", "", "3"]])
        #expect(CSVParser.parse("a,b\n1,\n") == [["a", "b"], ["1", ""]])
        #expect(CSVParser.parse("a,b\n,2\n") == [["a", "b"], ["", "2"]])
    }

    @Test("Blank lines are dropped rather than becoming empty rows")
    func blankLines() {
        #expect(CSVParser.parse("a,b\n\n1,2\n\n") == [["a", "b"], ["1", "2"]])
    }

    @Test("A byte-order mark does not become part of the first header")
    func byteOrderMark() {
        #expect(CSVParser.parse("\u{FEFF}Name,Cost\nThing,10\n") == [["Name", "Cost"], ["Thing", "10"]])
    }

    @Test("Stray whitespace around bare fields is trimmed, and kept inside quotes")
    func whitespace() {
        #expect(CSVParser.parse("a , b\n 1 , 2 \n") == [["a", "b"], ["1", "2"]])
        #expect(CSVParser.parse("a\n\"  padded  \"\n") == [["a"], ["  padded  "]])
    }

    // MARK: - Writing

    @Test("Only fields that need quoting get quoted")
    func escaping() {
        #expect(CSVParser.escape("plain") == "plain")
        #expect(CSVParser.escape("with, comma") == "\"with, comma\"")
        #expect(CSVParser.escape("with \"quote\"") == "\"with \"\"quote\"\"\"")
        #expect(CSVParser.escape("with\nnewline") == "\"with\nnewline\"")
        #expect(CSVParser.escape(" padded ") == "\" padded \"")
        #expect(CSVParser.escape("") == "")
    }

    @Test("Anything written can be read back exactly")
    func roundTrip() {
        let rows = [
            ["Name", "Notes", "Price"],
            ["Spotify", "Billed in USD, converted at the stored rate", "10.99"],
            ["Quotes", "He said \"hi\"", "0"],
            ["Multi", "line one\nline two", "1"],
            ["Empty", "", "2"],
            ["Padded", "  spaces  ", "3"]
        ]
        #expect(CSVParser.parse(CSVParser.serialize(rows)) == rows)
    }

    @Test("Spreadsheet protection is reversible")
    func spreadsheetProtection() {
        let dangerous = ["=2+2", "+cmd", "-10+20", "@SUM(A1:A2)", "  =2+2", "'=2+2"]
        for value in dangerous {
            let protected = CSVParser.spreadsheetSafe(value)
            #expect(protected.hasPrefix("'"))
            #expect(CSVParser.spreadsheetValue(protected) == value)
        }
        #expect(CSVParser.spreadsheetSafe("ordinary text") == "ordinary text")
    }
}
