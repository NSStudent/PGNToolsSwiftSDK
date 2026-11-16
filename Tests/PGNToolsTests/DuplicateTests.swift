import FischerCore
import Testing
@testable import PGNTools

@Suite("Duplicate detection")
struct DuplicateTests {
    /// Runs a detector over `sample.pgn` and returns the duplicate groups.
    private func groups(_ criterion: DuplicateCriterion) throws -> [DuplicateGroup] {
        var detector = DuplicateDetector(criterion: criterion)
        for record in try Fixtures.sampleGames() { _ = detector.check(record) }
        return detector.groups
    }

    @Test func sameMovesIgnoresFormattingCommentsAndTags() throws {
        // Game 2 repeats game 1 with comments, a variation and other tags.
        #expect(try groups(.sameMoves) == [DuplicateGroup(original: 1, duplicates: [2])])
    }

    @Test func sameFinalPositionFindsTranspositions() throws {
        // Game 3 reaches the final position of game 1 by another move order.
        #expect(try groups(.sameFinalPosition) == [DuplicateGroup(original: 1, duplicates: [2, 3])])
    }

    @Test func sameTagsAndMovesNeedsMatchingTags() throws {
        // Games 1 and 2 differ in Event, Date and Round.
        #expect(try groups(.sameTagsAndMoves()).isEmpty)
        #expect(try groups(.sameTagsAndMoves(tags: [.white, .black, .result]))
            == [DuplicateGroup(original: 1, duplicates: [2])])

        let a = try Fixtures.game("[White \"Tal, Mikhail\"]\n[Black \"Smyslov\"]\n[Result \"1-0\"]\n\n1. e4 e5 1-0")
        let b = try Fixtures.game("[Black \"smyslov\"]\n[White \"Tal,  Mikhail\"]\n[Result \"1-0\"]\n\n1.e4 {!} e5 1-0")
        let c = try Fixtures.game("[White \"Tal, Mikhail\"]\n[Black \"Smyslov\"]\n[Result \"0-1\"]\n\n1. e4 e5 0-1")
        let criterion = DuplicateCriterion.sameTagsAndMoves()
        #expect(DuplicateDetector.key(for: a.game, criterion: criterion) == DuplicateDetector.key(for: b.game, criterion: criterion))
        #expect(DuplicateDetector.key(for: a.game, criterion: criterion) != DuplicateDetector.key(for: c.game, criterion: criterion))
    }

    @Test func pipelineDropsDuplicatesAndReportsThem() throws {
        var pipeline = PGNPipeline()
        pipeline.duplicates = .sameMoves
        var kept: [Int] = []
        var dropped: [(Int, Int)] = []
        let report = try pipeline.run(PGNCollectionReader(source: .file(Fixtures.sampleURL)),
                                      onDuplicate: { game, original in dropped.append((game.record.number, original)) },
                                      { kept.append($0.record.number) })
        #expect(kept == [1, 3, 4, 6, 7])
        #expect(dropped.map(\.0) == [2])
        #expect(dropped.map(\.1) == [1])
        #expect(report.duplicatesRemoved == 1)
        #expect(report.gamesOutput == 5)
        #expect(report.duplicateGroups == [DuplicateGroup(original: 1, duplicates: [2])])
    }
}
