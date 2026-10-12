#if os(iOS)
import Testing
import UIKit

@testable import SwiftTerm

/// The runs a line's segments hand the Metal renderer to shape, which must be the runs it once found by
/// enumerating the attributes of each segment's attributed string.
@MainActor
struct iOSLineRunTests {
    /// A line styled the ways the line walk dresses text.
    enum Line: CaseIterable, Sendable {
        case sixteenColors
        case colors256
        case trueColors
        case boldItalicDim
        case underlineStyles
        case inverseInvisibleStrikethrough
        case wideCharacters
        case combiningMarks
        /// A family joined by zero-width joiners, a skin tone, a flag, a keycap, symbols that prefer text
        /// presentation, and emoji that prefer their own.
        case emoji
        /// Powerline separators, box drawing and block elements, which the renderer draws itself in
        /// place of a space in the text.
        case boxDrawingAndPowerline
        case hyperlinks
        case blinkShown
        case blinkHidden
        case rightToLeft
        /// A selection over part of differently styled text.
        case selection

        var text: String {
            switch self {
            case .sixteenColors:
                "\u{1b}[30mk\u{1b}[31mr\u{1b}[32mg\u{1b}[33my\u{1b}[34mb\u{1b}[35mm\u{1b}[36mc\u{1b}[37mw"
                    + "\u{1b}[90mK\u{1b}[91mR\u{1b}[92mG\u{1b}[93mY\u{1b}[94mB\u{1b}[95mM\u{1b}[96mC\u{1b}[97mW\u{1b}[0m"
                    + " \u{1b}[41;97m red \u{1b}[42;30m green \u{1b}[104;30m bright blue \u{1b}[0m"
            case .colors256:
                "\u{1b}[38;5;16ma\u{1b}[38;5;82mb\u{1b}[38;5;196mc\u{1b}[38;5;231md\u{1b}[38;5;244me"
                    + "\u{1b}[48;5;17m f \u{1b}[48;5;226;38;5;0m g \u{1b}[0m"
            case .trueColors:
                "\u{1b}[38;2;255;128;0morange\u{1b}[0m \u{1b}[48;2;10;20;30;38;2;200;220;240mnight\u{1b}[0m"
                    + " \u{1b}[38;2;1;2;3mx\u{1b}[38;2;1;2;4my\u{1b}[0m"
            case .boldItalicDim:
                "\u{1b}[1mbold\u{1b}[22m \u{1b}[3mitalic\u{1b}[23m \u{1b}[1;3mbold italic\u{1b}[0m"
                    + " \u{1b}[2mdim\u{1b}[22m \u{1b}[1;31mbold red\u{1b}[0m"
            case .underlineStyles:
                "\u{1b}[4msingle\u{1b}[24m \u{1b}[4:2mdouble\u{1b}[24m \u{1b}[4:3mcurly\u{1b}[24m"
                    + " \u{1b}[4:4mdotted\u{1b}[24m \u{1b}[4:5mdashed\u{1b}[24m \u{1b}[21mdouble\u{1b}[24m"
                    + " \u{1b}[4;58;5;196mred\u{1b}[59;24m \u{1b}[4;58;2;0;128;255mblue\u{1b}[0m"
            case .inverseInvisibleStrikethrough:
                "\u{1b}[7minverse\u{1b}[27m \u{1b}[8minvisible\u{1b}[28m \u{1b}[9mstrike\u{1b}[29m"
                    + " \u{1b}[7;9;32mall three\u{1b}[0m"
            case .wideCharacters:
                "a\u{6F22}b\u{5B57}c \u{30C6}\u{30B9}\u{30C8} \u{D55C}\u{AD6D}\u{C5B4} \u{FF57}\u{FF49}\u{FF44}\u{FF45}"
            case .combiningMarks:
                "e\u{301}a\u{308}o\u{302}\u{323} n\u{303} Z\u{335}\u{321}\u{34D}"
            case .emoji:
                "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} \u{1F44D}\u{1F3FD} \u{1F1EF}\u{1F1F5}"
                    + " 1\u{FE0F}\u{20E3} \u{263A} \u{2714} \u{1F600} \u{2764}\u{FE0F}"
            case .boxDrawingAndPowerline:
                "\u{1b}[44;37m main \u{1b}[34;42m\u{E0B0}\u{1b}[30m ok \u{1b}[0;32m\u{E0B0}\u{1b}[0m \u{E0B2}\u{E0B6}"
                    + " \u{250C}\u{2500}\u{252C}\u{2500}\u{2510}\u{2502}\u{255E}\u{2550}\u{2561}"
                    + " \u{2580}\u{2584}\u{2588}\u{2591}\u{2592}\u{2593}"
            case .hyperlinks:
                "\u{1b}]8;;https://example.com\u{1b}\\link text\u{1b}]8;;\u{1b}\\ plain"
                    + " \u{1b}]8;id=x;https://example.org\u{1b}\\\u{1b}[32mgreen link\u{1b}]8;;\u{1b}\\\u{1b}[0m"
            case .blinkShown, .blinkHidden:
                "\u{1b}[5mblink\u{1b}[25m steady \u{1b}[5;4;31mblink underlined\u{1b}[0m"
            case .rightToLeft:
                "Hebrew \u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD}"
                    + " Arabic \u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645} end"
            case .selection:
                "\u{1b}[31mred \u{1b}[4munderlined\u{1b}[24m \u{1b}[9mstrike\u{1b}[0m plain"
            }
        }

        /// Shows the line in `view` as its case names, beyond its text.
        @MainActor func present(in view: TerminalView) {
            switch self {
            case .blinkHidden:
                view.setTextBlinkVisibleForTesting(false)
            case .selection:
                view.selection.setSelection(start: Position(col: 2, row: 0), end: Position(col: 14, row: 0))
            default:
                break
            }
        }
    }

    /// A stretch of a segment's text in one set of attributes, compared code unit by code unit.
    struct ComparedRun: Equatable {
        var utf16Offset: Int
        var codeUnits: [UInt16]
        var attributes: NSDictionary
    }

    /// The runs enumerating the attributes of `string` finds.
    private func enumeratedRuns(of string: NSAttributedString) -> [ComparedRun] {
        var runs: [ComparedRun] = []
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            runs.append(ComparedRun(utf16Offset: range.location,
                                    codeUnits: Array(string.attributedSubstring(from: range).string.utf16),
                                    attributes: attributes as NSDictionary))
        }
        return runs
    }

    /// Each segment of the line hands the renderer the runs its attributed string holds: the same text,
    /// starting at the same place, in attributes an attributed string holds equal.
    @Test(arguments: Line.allCases)
    func segmentRunsAreTheRunsOfItsAttributedString(_ line: Line) throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 1000, height: 200))
        view.linkHighlightMode = .always
        view.feed(text: line.text)
        line.present(in: view)
        let terminal = view.getTerminal()
        let segments = view.buildAttributedString(row: 0, line: terminal.displayBuffer.lines[0],
                                                  cols: terminal.cols).segments
        try #require(!segments.isEmpty, "the line walk made no segment of the line")
        for segment in segments {
            let runs = segment.runs.map { run in
                ComparedRun(utf16Offset: run.utf16Offset, codeUnits: Array(run.text.utf16),
                            attributes: run.attributes as NSDictionary)
            }
            #expect(runs == enumeratedRuns(of: segment.attributedString))
        }
    }
}
#endif
