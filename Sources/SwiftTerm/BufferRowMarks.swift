//
//  BufferRowMarks.swift
//  SwiftTerm
//

/// Buffer rows marked for drawing again, split where the buffer's lines last moved to other rows.
///
/// A row marked since the lines last moved names the line on it now. A row marked before then may name a
/// line that has moved since, to another row or out of the buffer, so a renderer that keeps draw data by
/// line draws again a line that moved off or past such a row.
struct BufferRowMarks: Equatable {
    /// The rows marked before the buffer's lines last moved.
    private(set) var beforeLinesMoved: ClosedRange<Int>?
    /// The rows marked since then.
    private(set) var sinceLinesMoved: ClosedRange<Int>?
    /// The buffer's count of line moves, `CircularBufferLineList.lineMoves`, when the rows in
    /// `sinceLinesMoved` were marked.
    private(set) var lineMoves = 0

    /// Every row marked.
    var allRows: ClosedRange<Int>? {
        Self.union(beforeLinesMoved, sinceLinesMoved)
    }

    /// Marks `rows` in a buffer that has counted `lineMoves` line moves.
    mutating func mark(_ rows: ClosedRange<Int>, lineMoves: Int) {
        noteLineMoves(lineMoves)
        sinceLinesMoved = Self.union(sinceLinesMoved, rows)
    }

    /// Marks `rows` as rows that may name lines that have moved since.
    mutating func markBeforeLinesMoved(_ rows: ClosedRange<Int>) {
        beforeLinesMoved = Self.union(beforeLinesMoved, rows)
    }

    /// Notes that the buffer has counted `lineMoves` line moves. When its lines have moved since the rows
    /// in `sinceLinesMoved` were marked, those rows count as marked before the lines last moved.
    mutating func noteLineMoves(_ lineMoves: Int) {
        guard lineMoves != self.lineMoves else {
            return
        }
        self.lineMoves = lineMoves
        beforeLinesMoved = Self.union(beforeLinesMoved, sinceLinesMoved)
        sinceLinesMoved = nil
    }

    private static func union(_ a: ClosedRange<Int>?, _ b: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard let a else {
            return b
        }
        guard let b else {
            return a
        }
        return min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }
}
