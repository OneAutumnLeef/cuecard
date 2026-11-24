import Foundation

/// Greedy word wrapping. Measuring is injected so the same code works with real fonts and in tests.
public enum LineLayout {
    /// Returns token indices per display line. A paragraph start always begins a new line,
    /// and a word wider than the line gets a line of its own.
    public static func wrap(_ tokens: [Token], maxWidth: Double, spaceWidth: Double,
                            width: (Int) -> Double) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var used = 0.0
        for i in tokens.indices {
            let w = width(i)
            if tokens[i].paragraphStart, !current.isEmpty {
                lines.append(current); current = []; used = 0
            }
            let needed = current.isEmpty ? w : used + spaceWidth + w
            if needed > maxWidth, !current.isEmpty {
                lines.append(current)
                current = [i]
                used = w
            } else {
                current.append(i)
                used = needed
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// For each token, the index of the line it sits on.
    public static func lineIndex(of lines: [[Int]], tokenCount: Int) -> [Int] {
        var result = Array(repeating: 0, count: tokenCount)
        for (li, line) in lines.enumerated() { for t in line where t < tokenCount { result[t] = li } }
        return result
    }
}
