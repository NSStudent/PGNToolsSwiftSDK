import FischerCore
import Testing
@testable import PGNTools

@Suite("Filters")
struct FilterTests {
    // sample.pgn: 1 Carlsen-Nepomniachtchi, 2 the same with comments,
    // 3 Anand-Topalov (transposed Najdorf), 4 Ivanchuk-Kramnik (QGD),
    // 5 unreadable, 6 Lucena endgame from FEN, 7 Scholar's mate.

    @Test func player() throws {
        #expect(try Fixtures.matching(PlayerFilter("carlsen")) == [1, 2])
        #expect(try Fixtures.matching(PlayerFilter("Kramnik", side: .white)) == [])
        #expect(try Fixtures.matching(PlayerFilter("Kramnik", side: .black)) == [4])
        #expect(try Fixtures.matching(PlayerFilter("nepomniachtchi", side: .either)) == [1, 2])
    }

    @Test func event() throws {
        #expect(try Fixtures.matching(TagFilter(.event, .contains, "linares")) == [4])
        #expect(try Fixtures.matching(TagFilter(.event, .equal, "World Blitz")) == [2])
        #expect(try Fixtures.matching(TagFilter("Event ~ World")) == [1, 2])
        #expect(try Fixtures.matching(TagFilter("Site != \"Paris FRA\"")) == [3, 4, 6, 7])
    }

    @Test func dateRange() throws {
        let range = DateRangeFilter(from: PGNDate("2010.01.01"), to: PGNDate("2015"))
        #expect(try Fixtures.matching(range) == [3])
        #expect(try Fixtures.matching(DateRangeFilter(from: PGNDate("2021.05.11"))) == [2, 7])
        #expect(try Fixtures.matching(DateRangeFilter(to: PGNDate("1700"))) == [6])
        #expect(try Fixtures.matching(TagFilter("Date < 2000.01.01")) == [4, 6])
    }

    @Test func result() throws {
        #expect(try Fixtures.matching(ResultFilter([.draw])) == [3])
        #expect(try Fixtures.matching(ResultFilter([.loss])) == [4])
        #expect(try Fixtures.matching(ResultFilter([.win])) == [1, 2, 6, 7])
    }

    @Test func elo() throws {
        #expect(try Fixtures.matching(EloFilter(minimum: 2700)) == [1, 2, 3])
        #expect(try Fixtures.matching(EloFilter(minimum: 2800, mode: .either)) == [1, 2, 3])
        #expect(try Fixtures.matching(EloFilter(minimum: 2800, mode: .white)) == [1, 2])
        #expect(try Fixtures.matching(EloFilter(maximum: 2620, mode: .average)) == [7])
        #expect(try Fixtures.matching(TagFilter("BlackElo >= 2800")) == [3])
    }

    @Test func materialPattern() throws {
        let pattern = try MaterialPattern("KRP v KR")
        #expect(try Fixtures.matching(MaterialFilter(.pattern(pattern))) == [6])
        #expect(try Fixtures.matching(MaterialFilter(.pattern(try MaterialPattern("KR : KRP")))) == [])
        #expect(try Fixtures.matching(MaterialFilter(.pattern(try MaterialPattern("KR : KRP")), eitherColor: true)) == [6])
        // Every piece still on the board, any number of pawns.
        let full = try MaterialPattern("Q R2 B2 N2 P* v Q R2 B2 N2 P*")
        #expect(try Fixtures.matching(MaterialFilter(.pattern(full), scope: .finalPosition)) == [1, 2, 3, 4, 7])
        #expect(full.description == "KQR2B2N2P* v KQR2B2N2P*")
        #expect(throws: PGNToolsError.self) { try MaterialPattern("KQX v K") }
        #expect(throws: PGNToolsError.self) { try MaterialPattern("KQ") }
    }

    @Test func materialBalance() throws {
        // A pawn up at the end: the Lucena study and the Scholar's mate.
        #expect(try Fixtures.matching(MaterialFilter(.balance(1...1), scope: .finalPosition)) == [6, 7])
        // In the Najdorf games Black is a pawn up for one ply after 3...cxd4.
        #expect(try Fixtures.matching(MaterialFilter(.balance(-9 ... -1))) == [1, 2, 3])
        #expect(try Fixtures.matching(MaterialFilter(.balance(-9 ... -1), scope: .anyPosition(minPlies: 2))) == [])
        #expect(try Fixtures.matching(MaterialFilter(.balance(1...9))) == [6, 7])
        #expect(try Fixtures.matching(MaterialFilter(.balance(-1 ... -1), eitherColor: true)) == [1, 2, 3, 6, 7])
    }

    @Test func position() throws {
        // The Najdorf English Attack after 6. Be3, reached by games 1-3.
        let englishAttack = "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N1B3/PPP2PPP/R2QKB1R b KQkq - 1 6"
        #expect(try Fixtures.matching(PositionFilter(fen: englishAttack)) == [1, 2, 3])
        #expect(try Fixtures.matching(PositionFilter(fen: englishAttack, finalPositionOnly: true)) == [])
        // Placement only, then side to move only.
        #expect(try Fixtures.matching(PositionFilter(fen: "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N1B3/PPP2PPP/R2QKB1R")) == [1, 2, 3])
        #expect(try Fixtures.matching(PositionFilter(fen: "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N1B3/PPP2PPP/R2QKB1R b")) == [1, 2, 3])
        #expect(try Fixtures.matching(PositionFilter(fen: "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N1B3/PPP2PPP/R2QKB1R w")) == [])
        #expect(try Fixtures.matching(PositionFilter(fen: "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N1B3/PPP2PPP/R2QKB1R b Kkq")) == [])
        // Wildcards: a white queen on f7 next to the black king on e8.
        #expect(try Fixtures.matching(PositionFilter(fen: "????k???/?????Q??/????????/????????/????????/????????/????????/????????")) == [7])
        // A white rook on b4 in front of the white king on b5.
        #expect(try Fixtures.matching(PositionFilter(fen: "????????/????????/????????/?K??????/?R??????/????????/????????/????????")) == [6])
        #expect(throws: PGNToolsError.self) { try PositionFilter(fen: "8/8/8") }
    }

    @Test func combinators() throws {
        let filter = AllOf([PlayerFilter("Carlsen"), Not(TagFilter(.event, .contains, "Blitz"))])
        #expect(try Fixtures.matching(filter) == [1])
        #expect(try Fixtures.matching(AnyOf([ResultFilter([.draw]), ResultFilter([.loss])])) == [3, 4])
        #expect(try Fixtures.matching(AllOf([])) == [1, 2, 3, 4, 6, 7])
    }

    @Test func pipelineFiltersOnOpeningTags() throws {
        var pipeline = PGNPipeline()
        pipeline.classifier = ECOClassifier()
        pipeline.filter = try TagFilter("ECO == B90")
        var numbers: [Int] = []
        let report = try pipeline.run(PGNCollectionReader(source: .file(Fixtures.sampleURL))) { numbers.append($0.record.number) }
        #expect(numbers == [1, 2, 3])
        #expect(report.gamesMatched == 3)
    }
}
