import FischerCore
import Foundation
import Testing
@testable import PGNTools

@Suite("ECO classification")
struct ECOTests {
    @Test func bundledTableLoads() {
        let database = ECODatabase.lichess
        #expect(database.openings.count > 3000)
        #expect(database.positionCount > 3000)
        #expect(database.maxPly > 10)
        #expect(database.openings.allSatisfy { $0.eco.count == 3 })
    }

    @Test func classifiesFromTheLastKnownPosition() throws {
        // The table names the position after 8. f3 but nothing later.
        let record = try Fixtures.game("1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 Be6 8. f3 h5 9. Qd2 Nbd7 *")
        let found = try #require(ECOClassifier().classify(record.game))
        #expect(found.opening.eco == "B90")
        #expect(found.opening.name == "Sicilian Defense: Najdorf Variation, English Attack")
        #expect(found.ply == 15)
        #expect(found.opening.family == "Sicilian Defense")
        #expect(found.opening.variation == "Najdorf Variation")
        #expect(found.opening.subVariation == "English Attack")
    }

    @Test func findsTranspositions() throws {
        // 4...a6 5.Nc3 Nf6 is not the table's move order for the Najdorf.
        let transposed = try Fixtures.game("1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 a6 5. Nc3 Nf6 6. Be3 *")
        let direct = try Fixtures.game("1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 *")
        let classifier = ECOClassifier()
        let fromTransposition = try #require(classifier.classify(transposed.game))
        let fromDirect = try #require(classifier.classify(direct.game))
        #expect(fromTransposition == fromDirect)
        #expect(fromTransposition.opening.name == "Sicilian Defense: Najdorf Variation, English Attack")
        let playedUCI = transposed.game.tree.mainline.map(\.node.uci)
        #expect(playedUCI != fromTransposition.opening.uciMoves)
    }

    @Test func bundledIndexMatchesTheSourceFiles() throws {
        // Data/chess-openings holds the unchanged lichess-org files.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Data/chess-openings")
        var rows: [String] = []
        for volume in ["a", "b", "c", "d", "e"] {
            let text = try String(contentsOf: directory.appendingPathComponent("\(volume).tsv"), encoding: .utf8)
            rows += text.split(separator: "\n").dropFirst().map(String.init)
        }
        let bundled = ECODatabase.lichess.openings
        #expect(rows.count == bundled.count)
        // Replaying every row is slow in debug builds; check a sample.
        let sample = stride(from: 0, to: rows.count, by: 37).map { $0 }
        let replayed = try ECODatabase(tsv: sample.map { rows[$0] }.joined(separator: "\n")).openings
        for (offset, index) in sample.enumerated() {
            #expect(replayed[offset] == bundled[index])
        }
    }

    @Test func classifiesUCIAndGames() throws {
        let classifier = ECOClassifier()
        let fromUCI = try #require(classifier.classify(uciMoves: ["d2d4", "d7d5", "c2c4"]))
        #expect(fromUCI.opening.eco == "D06")
        #expect(fromUCI.opening.name == "Queen's Gambit")

        var game = Game()
        for uci in ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"] {
            let move = try #require(ResolvedMove(uci: uci))
            try game.execute(move: move.move)
        }
        #expect(classifier.classify(game)?.opening.name == "Ruy Lopez")
        #expect(classifier.classify(uciMoves: ["e2e5"]) == nil)
    }

    @Test func gamesOutsideTheTableAreNotClassified() throws {
        let study = try Fixtures.sampleGames().first { $0.number == 6 }!
        #expect(ECOClassifier().classify(study.game) == nil)
    }

    @Test func tagsTheTextWithoutTouchingTheMovetext() throws {
        let pgn = """
        [Event "Test"]
        [ECO "A00"]
        [Opening "Wrong"]

        1. d4 {queen pawn} d5 2. c4 (2. Nf3) 2... e6 3. Nc3 Nf6 *
        """
        let record = try Fixtures.game(pgn)
        let text = ECOClassifier().taggedText(record)
        #expect(text.contains("[ECO \"D"))
        #expect(!text.contains("A00"))
        #expect(text.contains("[Opening \"Queen's Gambit Declined\"]"))
        #expect(text.hasSuffix("1. d4 {queen pawn} d5 2. c4 (2. Nf3) 2... e6 3. Nc3 Nf6 *"))
        #expect(ECOClassifier().taggedText(record, overwrite: false) == record.text)

        let tagged = ECOClassifier().tagging(record.game)
        #expect(tagged.tags[.eco]?.hasPrefix("D") == true)
        #expect(tagged.tags[.opening] == "Queen's Gambit Declined")
    }

    @Test func classifiesAWholeFile() throws {
        var pipeline = PGNPipeline()
        pipeline.classifier = ECOClassifier()
        var codes: [Int: String] = [:]
        let report = try pipeline.run(PGNCollectionReader(source: .file(Fixtures.sampleURL))) { game in
            codes[game.record.number] = game.record.game.tags[.eco]
            if game.classification != nil {
                #expect(game.text.contains("[ECO \"\(game.classification!.opening.eco)\"]"))
            }
        }
        #expect(codes[1] == "B90")
        #expect(codes[3] == "B90")
        #expect(codes[4]?.hasPrefix("D") == true)
        #expect(codes[6] == nil)
        #expect(codes[7] == "C23")
        #expect(report.gamesClassified == 5)
        #expect(report.read.skippedGames.map(\.gameNumber) == [5])
    }

    @Test func readsCustomTables() throws {
        let tsv = "eco\tname\tpgn\nZ01\tTest Opening: Line A, Sub\t1. e4 e5 2. Nf3\n"
        let database = try ECODatabase(tsv: tsv)
        #expect(database.openings.count == 1)
        let classifier = ECOClassifier(database: database)
        let found = try #require(classifier.classify(uciMoves: ["g1f3", "e7e5", "e2e4"]))
        #expect(found.opening.eco == "Z01")
        #expect(found.opening.subVariation == "Sub")
        #expect(throws: PGNToolsError.self) { try ECODatabase(tsv: "Z02\tBroken\t1. e5") }
    }

    @Test func positionKeysIgnoreMoveCountersAndUnusableEnPassant() throws {
        let a = try #require(PositionKey(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"))
        let b = try #require(PositionKey(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 5 9"))
        #expect(a == b)
        let castling = try #require(PositionKey(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b Kkq -"))
        #expect(a != castling)
        let white = try #require(PositionKey(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -"))
        #expect(a != white)
        // Here Black can capture en passant, so the square counts.
        let withCapture = try #require(PositionKey(fen: "4k3/8/8/8/3pP3/8/8/4K3 b - e3"))
        let withoutSquare = try #require(PositionKey(fen: "4k3/8/8/8/3pP3/8/8/4K3 b - -"))
        #expect(withCapture != withoutSquare)
    }
}
