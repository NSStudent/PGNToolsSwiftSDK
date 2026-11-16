import FischerCore
import Foundation

/// An error raised by the PGN tools: unreadable input, an aborted run or an
/// invalid argument.
public struct PGNToolsError: Error, Sendable, CustomStringConvertible, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The input could not be opened or read, or a game was rejected by
        /// ``PGNCollectionReader/onInvalidGame``.
        case input
        /// The output could not be written.
        case output
        /// An option or pattern is not valid.
        case invalidArgument
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

/// A game that could not be read from the PGN input, or that was read only
/// in part.
public struct GameReadError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 1-based position of the game in the input.
    public let gameNumber: Int
    /// Byte offset where the game starts in the input.
    public let byteOffset: Int64
    /// Why the game could not be read.
    public let reason: String

    public init(gameNumber: Int, byteOffset: Int64, reason: String) {
        self.gameNumber = gameNumber
        self.byteOffset = byteOffset
        self.reason = reason
    }

    public var description: String { "game \(gameNumber) (byte \(byteOffset)): \(reason)" }
}

/// What to do when a game in the PGN input cannot be read.
public enum InvalidGameDecision: Sendable {
    /// Skip the game, record it in ``ReadReport/skippedGames`` and continue.
    case skip
    /// Stop reading and throw a ``PGNToolsError``.
    case abort
}

/// Where PGN text comes from.
public enum PGNSource: Sendable {
    /// PGN text already in memory.
    case text(String)
    /// PGN bytes in memory (UTF-8, or Latin-1 line by line).
    case data(Data)
    /// A PGN file, read incrementally in blocks.
    case file(URL)
}

/// One game read from a collection.
public struct GameRecord: Sendable {
    /// 1-based position of the game in the input.
    public let number: Int
    /// Byte offset where the game starts in the input.
    public let byteOffset: Int64
    /// The original text of the game, trimmed, with `\n` line endings.
    public let text: String
    /// The parsed game.
    public let game: AnnotatedPGNGame

    public init(number: Int, byteOffset: Int64, text: String, game: AnnotatedPGNGame) {
        self.number = number
        self.byteOffset = byteOffset
        self.text = text
        self.game = game
    }

    /// Reads a single game from PGN text.
    public init(pgn: String, number: Int = 1) throws {
        let text = pgn.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(number: number, byteOffset: 0, text: text, game: try AnnotatedPGNGame(pgn: text))
    }
}

/// A summary of one pass over a PGN collection.
public struct ReadReport: Sendable, Equatable {
    /// Number of games found in the input, readable or not.
    public var gamesFound = 0
    /// Number of games that were read and passed to the caller.
    public var gamesRead = 0
    /// Games that could not be read and were skipped.
    public var skippedGames: [GameReadError] = []
    /// Games that were read up to an illegal or unreadable move; the moves
    /// after it were dropped.
    public var partiallyReadGames: [GameReadError] = []

    public init() {}
}

/// Reads the games of a PGN collection one at a time.
///
/// Files are split into games with fischer-core's ``PGNByteChunker`` while
/// they are read, so memory use does not grow with the size of the file.
/// A game that cannot be read is reported through ``onInvalidGame`` and, by
/// default, skipped; the run continues with the next game.
///
/// ```swift
/// let reader = PGNCollectionReader(source: .file(url))
/// let report = try reader.forEachGame { record in
///     print(record.number, record.game.tags[.white] ?? "?")
/// }
/// for failure in report.skippedGames { print("skipped", failure) }
/// ```
public struct PGNCollectionReader: Sendable {
    public var source: PGNSource
    /// Size of the blocks read from a file.
    public var blockSize: Int
    /// Only these game numbers (1-based) are parsed; the others are passed
    /// over without reading their moves.
    public var gameNumbers: ClosedRange<Int>?
    /// Decides what happens when a game cannot be read. The default skips
    /// it (see ``ReadReport/skippedGames``); return `.abort` to stop.
    public var onInvalidGame: @Sendable (GameReadError) -> InvalidGameDecision

    public init(
        source: PGNSource,
        blockSize: Int = 1 << 20,
        onInvalidGame: @escaping @Sendable (GameReadError) -> InvalidGameDecision = { _ in .skip }
    ) {
        self.source = source
        self.blockSize = blockSize
        self.onInvalidGame = onInvalidGame
    }

    /// Calls `body` with every readable game, in input order.
    ///
    /// - Returns: How many games were read and which ones were skipped.
    /// - Throws: ``PGNToolsError`` when the input cannot be read or a game is
    ///   rejected by ``onInvalidGame``, or any error thrown by `body`.
    @discardableResult
    public func forEachGame(_ body: (GameRecord) throws -> Void) throws -> ReadReport {
        var report = ReadReport()
        try forEachChunk { chunk in
            report.gamesFound += 1
            let number = chunk.index + 1
            if let gameNumbers, !gameNumbers.contains(number) { return }
            let game: AnnotatedPGNGame
            do {
                game = try chunk.annotatedGame()
            } catch {
                let failure = GameReadError(gameNumber: number, byteOffset: chunk.startByteOffset,
                                            reason: Self.describe(error))
                report.skippedGames.append(failure)
                if onInvalidGame(failure) == .abort {
                    throw PGNToolsError(.input, "cannot read PGN \(failure)")
                }
                return
            }
            if let issue = game.issues.first {
                report.partiallyReadGames.append(GameReadError(
                    gameNumber: number, byteOffset: chunk.startByteOffset,
                    reason: "stopped at \(issue); later moves were ignored"))
            }
            report.gamesRead += 1
            try body(GameRecord(number: number, byteOffset: chunk.startByteOffset, text: chunk.text, game: game))
        }
        return report
    }

    /// Reads every game into memory. Convenient for small collections.
    public func readAll() throws -> (games: [GameRecord], report: ReadReport) {
        var games: [GameRecord] = []
        let report = try forEachGame { games.append($0) }
        return (games, report)
    }

    /// Calls `body` with the raw text of every game, without parsing moves.
    public func forEachChunk(_ body: (PGNGameChunk) throws -> Void) throws {
        switch source {
        case .text(let text):
            for chunk in PGNGameSplitter.chunks(in: Data(text.utf8)) { try body(chunk) }
        case .data(let data):
            for chunk in PGNGameSplitter.chunks(in: data) { try body(chunk) }
        case .file(let url):
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw PGNToolsError(.input, "cannot open \(url.path): \(error.localizedDescription)")
            }
            defer { try? handle.close() }
            var chunker = PGNByteChunker()
            while true {
                let block: Data
                do {
                    block = try handle.read(upToCount: blockSize) ?? Data()
                } catch {
                    throw PGNToolsError(.input, "cannot read \(url.path): \(error.localizedDescription)")
                }
                if block.isEmpty { break }
                for chunk in chunker.consume(block) { try body(chunk) }
            }
            for chunk in chunker.finish() { try body(chunk) }
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case AnnotatedPGNError.invalidFEN(let fen): return "invalid FEN tag \"\(fen)\""
        case AnnotatedPGNError.noGame: return "no game found"
        case AnnotatedPGNError.illegalMove(let issue): return "illegal move: \(issue)"
        default: return String(describing: error)
        }
    }
}
