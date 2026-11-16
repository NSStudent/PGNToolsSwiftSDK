import Foundation
@testable import PGNTools

enum Fixtures {
    static var sampleURL: URL {
        Bundle.module.url(forResource: "sample", withExtension: "pgn", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "sample", withExtension: "pgn")!
    }

    static var sampleText: String {
        try! String(contentsOf: sampleURL, encoding: .utf8)
    }

    /// The readable games of `sample.pgn` (game 5 has an invalid FEN).
    static func sampleGames() throws -> [GameRecord] {
        try PGNCollectionReader(source: .file(sampleURL)).readAll().games
    }

    static func game(_ pgn: String) throws -> GameRecord {
        try GameRecord(pgn: pgn)
    }

    /// Numbers of the games of `sample.pgn` that pass `filter`.
    static func matching(_ filter: any GameFilter) throws -> [Int] {
        try sampleGames().filter { filter.matches($0) }.map(\.number)
    }
}
