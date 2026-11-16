import FischerCore
import Foundation
import Testing
@testable import PGNTools

@Suite("Export formats")
struct ExportTests {
    private let scholar = """
    [Event "Casual game"]
    [White "Doe, John"]
    [Black "Roe, Richard"]
    [Result "1-0"]

    1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0
    """

    private func processed(_ pgn: String, number: Int = 1) throws -> ProcessedGame {
        ProcessedGame(record: try GameRecord(pgn: pgn, number: number))
    }

    @Test func epd() throws {
        let game = try processed(scholar)
        let lines = GameExporter.export([game], format: .epd).split(separator: "\n")
        #expect(lines.count == 8)
        #expect(lines.first == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - hmvc 0; fmvn 1; id \"g1.p0\";")
        #expect(lines.last == "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - hmvc 0; fmvn 4; id \"g1.p7\";")
        let final = GameExporter.export([game], format: .epd, positions: .final)
        #expect(final == String(lines.last!) + "\n")
    }

    @Test func fenPerPosition() throws {
        let games = [try processed(scholar), try processed("1. d4 d5 *", number: 2)]
        let text = GameExporter.export(games, format: .fen)
        let blocks = text.components(separatedBy: "\n\n")
        #expect(blocks.count == 2)
        let first = blocks[0].split(separator: "\n")
        #expect(first.count == 8)
        #expect(first[1] == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        #expect(first.last == "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4")
        #expect(blocks[1].split(separator: "\n").count == 3)
        #expect(GameExporter.export(games, format: .fen, positions: .final).split(separator: "\n").count == 2)
    }

    @Test func uciMoveLists() throws {
        let game = try processed(scholar)
        #expect(GameExporter.export([game], format: .uci) == "e2e4 e7e5 f1c4 b8c6 d1h5 g8f6 h5f7\n")
        #expect(GameExporter.export([game], format: .uci, uciStyle: .position)
            == "position startpos moves e2e4 e7e5 f1c4 b8c6 d1h5 g8f6 h5f7\n")

        let study = try Fixtures.sampleGames().first { $0.number == 6 }!
        let line = GameExporter.export([ProcessedGame(record: study)], format: .uci, uciStyle: .position)
        #expect(line.hasPrefix("position fen 1K1k4/1P6/8/8/8/8/r7/2R5 w - - 0 1 moves c1d1 d8e7 "))

        let castling = try processed("1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. O-O *")
        #expect(GameExporter.export([castling], format: .uci) == "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 e1g1\n")
    }

    @Test func json() throws {
        let record = try GameRecord(pgn: scholar)
        let classification = ECOClassifier().classify(record.game)
        let game = ProcessedGame(record: record, classification: classification)
        let text = GameExporter.export([game, try processed("1. d4 *", number: 2)], format: .json)
        let decoded = try JSONDecoder().decode([JSONGame].self, from: Data(text.utf8))
        #expect(decoded.count == 2)
        let first = decoded[0]
        #expect(first.number == 1)
        #expect(first.tags["White"] == "Doe, John")
        #expect(first.tags["ECO"] == "C23")
        #expect(first.tags["Opening"] == "Bishop's Opening")
        #expect(first.result == "1-0")
        #expect(first.moves == ["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#"])
        #expect(first.uci.count == 7)
        #expect(first.initialFEN == nil)
        #expect(first.finalFEN == "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4")
        #expect(first.eco == JSONGame.ECO(code: "C23", name: "Bishop's Opening", ply: 3))
        #expect(decoded[1].result == "*")
        #expect(decoded[1].eco == nil)
        #expect(GameExporter.export([], format: .json) == "[]\n")
    }

    @Test func jsonLines() throws {
        let games = [try processed(scholar), try processed("1. d4 *", number: 2)]
        let lines = GameExporter.export(games, format: .jsonl).split(separator: "\n")
        #expect(lines.count == 2)
        let second = try JSONDecoder().decode(JSONGame.self, from: Data(lines[1].utf8))
        #expect(second.number == 2)
        #expect(second.uci == ["d2d4"])
    }

    @Test func pgnKeepsTheOriginalText() throws {
        let game = try processed("[Event \"x\"]\n\n1. e4 {comment} (1. d4) 1... e5 *")
        let text = GameExporter.export([game, game], format: .pgn)
        #expect(text == "[Event \"x\"]\n\n1. e4 {comment} (1. d4) 1... e5 *\n\n[Event \"x\"]\n\n1. e4 {comment} (1. d4) 1... e5 *\n")
    }
}
