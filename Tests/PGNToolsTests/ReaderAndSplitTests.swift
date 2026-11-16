import FischerCore
import Foundation
import Testing
@testable import PGNTools

@Suite("Reading and splitting")
struct ReaderAndSplitTests {
    @Test func skipsUnreadableGamesAndReportsThem() throws {
        let data = try Data(contentsOf: Fixtures.sampleURL)
        // Read the file in tiny blocks to exercise the streaming chunker.
        let reader = PGNCollectionReader(source: .file(Fixtures.sampleURL), blockSize: 7)
        var numbers: [Int] = []
        let report = try reader.forEachGame { numbers.append($0.number) }
        #expect(numbers == [1, 2, 3, 4, 6, 7])
        #expect(report.gamesFound == 7)
        #expect(report.gamesRead == 6)
        let skipped = try #require(report.skippedGames.first)
        #expect(report.skippedGames.count == 1)
        #expect(skipped.gameNumber == 5)
        let offset = try #require(data.range(of: Data("[Event \"Bad FEN\"]".utf8))?.lowerBound)
        #expect(skipped.byteOffset == Int64(offset))
        #expect(skipped.reason.contains("FEN"))
    }

    @Test func memorySourcesMatchFiles() throws {
        let fromText = try PGNCollectionReader(source: .text(Fixtures.sampleText)).readAll()
        let fromFile = try PGNCollectionReader(source: .file(Fixtures.sampleURL)).readAll()
        #expect(fromText.games.map(\.number) == fromFile.games.map(\.number))
        #expect(fromText.games.map(\.byteOffset) == fromFile.games.map(\.byteOffset))
        #expect(fromText.report == fromFile.report)
    }

    @Test func abortsWhenAsked() throws {
        let reader = PGNCollectionReader(source: .file(Fixtures.sampleURL), onInvalidGame: { _ in .abort })
        var read = 0
        #expect(throws: PGNToolsError.self) { try reader.forEachGame { _ in read += 1 } }
        #expect(read == 4)
    }

    @Test func readsOnlySelectedGameNumbers() throws {
        var reader = PGNCollectionReader(source: .file(Fixtures.sampleURL))
        reader.gameNumbers = 4...6
        let (games, report) = try reader.readAll()
        #expect(games.map(\.number) == [4, 6])
        #expect(report.skippedGames.map(\.gameNumber) == [5])
        #expect(report.gamesFound == 7)

        var pipeline = PGNPipeline()
        pipeline.gameNumbers = 6...7
        var numbers: [Int] = []
        let pipelineReport = try pipeline.run(PGNCollectionReader(source: .file(Fixtures.sampleURL))) { numbers.append($0.record.number) }
        #expect(numbers == [6, 7])
        #expect(pipelineReport.read.skippedGames.isEmpty)
    }

    @Test func reportsPartiallyReadGames() throws {
        let pgn = "[Event \"a\"]\n\n1. e4 e5 2. Ke3 Nc6 *\n\n[Event \"b\"]\n\n1. d4 *\n"
        let (games, report) = try PGNCollectionReader(source: .text(pgn)).readAll()
        #expect(games.count == 2)
        #expect(games[0].game.tree.mainline.count == 2)
        #expect(report.partiallyReadGames.map(\.gameNumber) == [1])
    }

    @Test func missingFileIsAnInputError() {
        let reader = PGNCollectionReader(source: .file(URL(fileURLWithPath: "/nonexistent/games.pgn")))
        #expect(throws: PGNToolsError.self) { try reader.forEachGame { _ in } }
    }

    @Test func splitsByGameCount() throws {
        var splitter = CollectionSplitter(mode: .gamesPerFile(4), baseName: "chunk")
        for game in try Fixtures.sampleGames() { splitter.add(ProcessedGame(record: game)) }
        let parts = splitter.parts
        #expect(parts.map(\.name) == ["chunk-0001", "chunk-0002"])
        let first = try PGNCollectionReader(source: .text(parts[0].text)).readAll()
        let second = try PGNCollectionReader(source: .text(parts[1].text)).readAll()
        #expect(first.games.count == 4)
        #expect(second.games.count == 2)
        #expect(second.games[0].game.tags[.event] == "Endgame study")
    }

    @Test func splitsByTag() throws {
        var pipeline = PGNPipeline()
        pipeline.classifier = ECOClassifier()
        var splitter = CollectionSplitter(mode: .byTag(.eco))
        try pipeline.run(PGNCollectionReader(source: .file(Fixtures.sampleURL))) { splitter.add($0) }
        let names = splitter.parts.map(\.name)
        #expect(names.count == 4)
        #expect(names[0] == "B90")
        #expect(names.contains("unknown"))
        #expect(names.contains("C23"))
        let b90 = splitter.parts.first { $0.name == "B90" }!.text
        #expect(try PGNCollectionReader(source: .text(b90)).readAll().games.count == 3)
        #expect(CollectionSplitter.safeFileName("World Ch. 2024/25: R1") == "World Ch. 2024_25_ R1")
    }

    @Test func splitsToFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgntools-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var splitter = try FileSplitter(mode: .gamesPerFile(2), directory: directory, baseName: "games")
        splitter.flushThreshold = 10
        for game in try Fixtures.sampleGames() { try splitter.add(ProcessedGame(record: game)) }
        let files = try splitter.finish()
        #expect(files.map(\.lastPathComponent) == ["games-0001.pgn", "games-0002.pgn", "games-0003.pgn"])
        for file in files {
            let (games, report) = try PGNCollectionReader(source: .file(file)).readAll()
            #expect(games.count == 2)
            #expect(report.skippedGames.isEmpty)
        }

        var byEvent = try FileSplitter(mode: .byTag(.white), directory: directory.appendingPathComponent("white"))
        for game in try Fixtures.sampleGames() { try byEvent.add(ProcessedGame(record: game)) }
        let players = try byEvent.finish()
        #expect(players.count == 5)
        let carlsen = try #require(players.first { $0.lastPathComponent == "Carlsen_ Magnus.pgn" })
        #expect(try PGNCollectionReader(source: .file(carlsen)).readAll().games.count == 2)
    }

    @Test func editsTagsInPlace() {
        let pgn = "[Event \"x\"]\n[ECO \"A00\"]\n\n1. e4 *"
        let edited = PGNTextEditing.settingTags([(.eco, "B00"), (.opening, "Say \"hi\""), (.event, nil)], in: pgn)
        #expect(edited == "[ECO \"B00\"]\n[Opening \"Say \\\"hi\\\"\"]\n\n1. e4 *")
        #expect(PGNTextEditing.settingTags([(.eco, "C00")], in: "1. e4 e6 *") == "[ECO \"C00\"]\n\n1. e4 e6 *")
    }
}
