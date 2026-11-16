import FischerCore
import Foundation

/// A named opening position.
public struct Opening: Sendable, Hashable {
    /// The ECO code, such as `B90`.
    public let eco: String
    /// The full name, such as `Sicilian Defense: Najdorf Variation, English Attack`.
    public let name: String
    /// The moves of a line that reaches the position, as PGN movetext.
    public let moves: String
    /// The same moves in UCI notation.
    public let uciMoves: [String]
    /// The key of the named position.
    public let key: PositionKey

    public init(eco: String, name: String, moves: String, uciMoves: [String], key: PositionKey) {
        self.eco = eco
        self.name = name
        self.moves = moves
        self.uciMoves = uciMoves
        self.key = key
    }

    /// Number of half-moves in ``moves``.
    public var plies: Int { uciMoves.count }

    /// The opening family: the part of ``name`` before the colon
    /// (`Sicilian Defense`).
    public var family: String {
        name.split(separator: ":", maxSplits: 1).first.map { String($0).trimmed } ?? name
    }

    /// The first part after the colon (`Najdorf Variation`), if any.
    public var variation: String? { variationParts.first }

    /// The rest after the variation (`English Attack`), if any.
    public var subVariation: String? {
        let parts = variationParts.dropFirst()
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var variationParts: [String] {
        let halves = name.split(separator: ":", maxSplits: 1)
        guard halves.count == 2 else { return [] }
        return halves[1].split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }
}

/// A table of named opening positions, indexed by position key.
///
/// ``lichess`` is the bundled table built from
/// [lichess-org/chess-openings](https://github.com/lichess-org/chess-openings)
/// (CC0 1.0). Load other tables in the same tab-separated format with
/// ``init(tsv:)``.
public struct ECODatabase: Sendable {
    /// The openings, in input order.
    public let openings: [Opening]
    /// The most half-moves of any opening line.
    public let maxPly: Int
    private let index: [PositionKey: Int]

    /// Builds a table from openings.
    ///
    /// When several openings name the same position, the one with the
    /// shortest line wins, then the first one.
    public init(openings: [Opening]) {
        self.openings = openings
        var index: [PositionKey: Int] = [:]
        for (offset, opening) in openings.enumerated() {
            if let existing = index[opening.key], openings[existing].plies <= opening.plies { continue }
            index[opening.key] = offset
        }
        self.index = index
        self.maxPly = openings.map(\.plies).max() ?? 0
    }

    /// Reads tab-separated rows of `eco`, `name` and `pgn` (the format of
    /// lichess-org/chess-openings), optionally followed by `uci` and `key`
    /// columns as written by ``indexTSV``. Rows with a `key` are not
    /// replayed, which makes loading fast. A first row starting with `eco`
    /// is a header and is skipped.
    ///
    /// - Throws: ``PGNToolsError`` naming the row whose moves cannot be played.
    public init(tsv: String) throws(PGNToolsError) {
        try self.init(openings: Self.parse(tsv: tsv, source: "TSV"))
    }

    /// The opening whose position has `key`, if any.
    public func opening(for key: PositionKey) -> Opening? {
        index[key].map { openings[$0] }
    }

    /// Number of distinct named positions.
    public var positionCount: Int { index.count }

    /// The table as tab-separated `eco`, `name`, `pgn`, `uci` and `key`
    /// columns, with a header row. ``init(tsv:)`` reads it back without
    /// replaying the moves.
    public var indexTSV: String {
        var lines = ["eco\tname\tpgn\tuci\tkey"]
        for opening in openings {
            lines.append([opening.eco, opening.name, opening.moves, opening.uciMoves.joined(separator: " "),
                          opening.key.description].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The bundled lichess-org/chess-openings table.
    public static let lichess: ECODatabase = {
        do {
            return try bundled()
        } catch {
            preconditionFailure("the bundled opening table cannot be read: \(error)")
        }
    }()

    /// Reads the bundled lichess-org/chess-openings table.
    public static func bundled() throws(PGNToolsError) -> ECODatabase {
        guard let url = Bundle.module.url(forResource: "openings", withExtension: "tsv") else {
            throw PGNToolsError(.input, "missing bundled opening table openings.tsv")
        }
        return try ECODatabase(contentsOf: url)
    }

    /// Reads a table file in the format of ``init(tsv:)``.
    public init(contentsOf url: URL) throws(PGNToolsError) {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PGNToolsError(.input, "cannot read \(url.path): \(error.localizedDescription)")
        }
        try self.init(openings: Self.parse(tsv: text, source: url.lastPathComponent))
    }

    static func parse(tsv: String, source: String) throws(PGNToolsError) -> [Opening] {
        var openings: [Opening] = []
        for (lineIndex, line) in tsv.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { String($0).trimmed }
            guard fields.count >= 3, !fields[0].isEmpty else { continue }
            if lineIndex == 0, fields[0].lowercased() == "eco" { continue }
            if fields.count >= 5, let raw = UInt64(fields[4], radix: 16) {
                openings.append(Opening(eco: fields[0], name: fields[1], moves: fields[2],
                                        uciMoves: fields[3].split(separator: " ").map(String.init),
                                        key: PositionKey(rawValue: raw)))
                continue
            }
            var game = Game()
            var uci: [String] = []
            for token in fields[2].split(whereSeparator: \.isWhitespace) {
                // Skip move numbers ("1." or "12...").
                if token.last == "." || token.allSatisfy({ $0.isNumber || $0 == "." }) { continue }
                let san = token.drop { $0.isNumber || $0 == "." }
                do {
                    let move = try game.resolve(san: String(san))
                    try game.execute(move: move.move, considerHalfmoves: false, promotion: move.promotion ?? .queen)
                    uci.append(move.uci)
                } catch {
                    throw PGNToolsError(.input, "\(source) line \(lineIndex + 1): cannot play \(san) in \"\(fields[2])\"")
                }
            }
            openings.append(Opening(eco: fields[0], name: fields[1], moves: fields[2], uciMoves: uci,
                                    key: PositionKey(game: game)))
        }
        return openings
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
