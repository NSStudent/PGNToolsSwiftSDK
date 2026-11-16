import FischerCore
import Foundation

/// An output format for games.
public enum ExportFormat: String, Sendable, CaseIterable {
    /// The game's PGN text, unchanged apart from added tags.
    case pgn
    /// One EPD line per position, with `hmvc`, `fmvn` and `id` opcodes.
    case epd
    /// One FEN line per position; a blank line separates games.
    case fen
    /// One line of UCI moves per game.
    case uci
    /// A JSON array with one object per game.
    case json
    /// One JSON object per line (JSON Lines).
    case jsonl
}

/// A game ready to be written: its record, its current PGN text (with any
/// added tags) and its opening, when it was classified.
public struct ProcessedGame: Sendable {
    public let record: GameRecord
    public var text: String
    public var classification: ECOClassification?

    public init(record: GameRecord, text: String? = nil, classification: ECOClassification? = nil) {
        self.record = record
        self.text = text ?? record.text
        self.classification = classification
    }
}

/// Writes games in an ``ExportFormat``.
///
/// Call ``header()`` once, ``export(_:)`` for each game and ``footer()`` at
/// the end, and concatenate the results.
public struct GameExporter: Sendable {
    /// Which positions EPD and FEN output include.
    public enum Positions: String, Sendable, CaseIterable {
        /// Every main line position, including the initial one.
        case all
        /// The final position of the main line only.
        case final
    }

    /// How UCI output is written.
    public enum UCIStyle: String, Sendable, CaseIterable {
        /// The moves only: `e2e4 e7e5 g1f3`.
        case moves
        /// A UCI `position` command: `position startpos moves e2e4 e7e5`.
        case position
    }

    public var format: ExportFormat
    public var positions: Positions
    public var uciStyle: UCIStyle
    private var exported = 0

    public init(format: ExportFormat, positions: Positions = .all, uciStyle: UCIStyle = .moves) {
        self.format = format
        self.positions = positions
        self.uciStyle = uciStyle
    }

    /// Text written before the first game.
    public func header() -> String {
        format == .json ? "[" : ""
    }

    /// Text written after the last game.
    public func footer() -> String {
        guard format == .json else { return "" }
        return exported == 0 ? "]\n" : "\n]\n"
    }

    /// The text of one game, including any separator from the previous one.
    public mutating func export(_ game: ProcessedGame) -> String {
        defer { exported += 1 }
        switch format {
        case .pgn:
            return (exported == 0 ? "" : "\n") + game.text + "\n"
        case .epd:
            return epdLines(game).map { $0 + "\n" }.joined()
        case .fen:
            return (exported == 0 ? "" : "\n") + selectedPositions(game).map { $0.fen + "\n" }.joined()
        case .uci:
            return uciLine(game) + "\n"
        case .json:
            return (exported == 0 ? "\n" : ",\n") + json(game, prettyPrinted: true)
        case .jsonl:
            return json(game, prettyPrinted: false) + "\n"
        }
    }

    /// Exports `games` as one document.
    public static func export(_ games: [ProcessedGame], format: ExportFormat,
                              positions: Positions = .all, uciStyle: UCIStyle = .moves) -> String {
        var exporter = GameExporter(format: format, positions: positions, uciStyle: uciStyle)
        return exporter.header() + games.map { exporter.export($0) }.joined() + exporter.footer()
    }

    // MARK: - Formats

    private func selectedPositions(_ game: ProcessedGame) -> [ReplayedPosition] {
        switch positions {
        case .all: return game.record.game.mainlinePositions()
        case .final: return [game.record.game.finalPosition]
        }
    }

    func epdLines(_ game: ProcessedGame) -> [String] {
        selectedPositions(game).map { position in
            let id = "g\(game.record.number).p\(position.ply)"
            return "\(position.epd) hmvc \(position.position.halfmoves); fmvn \(position.position.fullmoves); id \"\(id)\";"
        }
    }

    func uciLine(_ game: ProcessedGame) -> String {
        let tree = game.record.game.tree
        let moves = tree.mainline.map(\.node.uci).joined(separator: " ")
        switch uciStyle {
        case .moves:
            return moves
        case .position:
            let start = tree.startsFromStandardPosition ? "startpos" : "fen \(tree.initialFEN)"
            return "position \(start)" + (moves.isEmpty ? "" : " moves \(moves)")
        }
    }

    func json(_ game: ProcessedGame, prettyPrinted: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONGame(game))) ?? Data("{}".utf8)
        var text = String(decoding: data, as: UTF8.self)
        if prettyPrinted {
            // Indent the object inside the array.
            text = text.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
        }
        return text
    }
}

/// The JSON form of a game.
public struct JSONGame: Codable, Sendable, Equatable {
    public struct ECO: Codable, Sendable, Equatable {
        public let code: String
        public let name: String
        public let ply: Int
    }

    /// 1-based number of the game in the input.
    public let number: Int
    public let tags: [String: String]
    public let result: String
    /// The starting position, when it is not the standard one.
    public let initialFEN: String?
    /// Main line moves in SAN.
    public let moves: [String]
    /// Main line moves in UCI notation.
    public let uci: [String]
    public let finalFEN: String
    public let eco: ECO?

    public init(_ game: ProcessedGame) {
        let source = game.record.game
        number = game.record.number
        var tags: [String: String] = [:]
        for (tag, value) in source.tags { tags[tag.rawValue] = value }
        if let found = game.classification {
            for (tag, value) in found.tags { tags[tag.rawValue] = value }
        }
        self.tags = tags
        result = source.tags[.result] ?? source.result.rawValue
        initialFEN = source.tree.startsFromStandardPosition ? nil : source.tree.initialFEN
        let mainline = source.tree.mainline
        moves = mainline.map { $0.node.san.description }
        uci = mainline.map(\.node.uci)
        finalFEN = source.finalPosition.fen
        eco = game.classification.map { ECO(code: $0.opening.eco, name: $0.opening.name, ply: $0.ply) }
    }
}
