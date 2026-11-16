import FischerCore

/// A summary of a pipeline run.
public struct PipelineReport: Sendable, Equatable {
    /// What the reader found, including skipped and partially read games.
    public var read = ReadReport()
    /// Games that passed the filters (duplicates included).
    public var gamesMatched = 0
    /// Games passed on to the output.
    public var gamesOutput = 0
    /// Games dropped as duplicates of an earlier matching game.
    public var duplicatesRemoved = 0
    /// The duplicate groups among the matching games of every run of the
    /// pipeline so far. Game numbers are 1-based positions in their input.
    public var duplicateGroups: [DuplicateGroup] = []
    /// Games for which an opening was found.
    public var gamesClassified = 0

    public init() {}
}

/// Processes a PGN collection in one streaming pass, in the spirit of
/// pgn-extract: classify openings, filter, drop duplicates, then hand each
/// remaining game to the caller for output.
///
/// ```swift
/// var pipeline = PGNPipeline()
/// pipeline.classifier = ECOClassifier()
/// pipeline.filter = AllOf([PlayerFilter("Carlsen"), EloFilter(minimum: 2700)])
/// pipeline.duplicates = .sameMoves
/// var exporter = GameExporter(format: .json)
/// var output = exporter.header()
/// let report = try pipeline.run(PGNCollectionReader(source: .file(url))) { game in
///     output += exporter.export(game)
/// }
/// output += exporter.footer()
/// ```
public struct PGNPipeline {
    /// Adds `ECO`, `Opening`, `Variation` and `SubVariation` tags before
    /// filtering, so tag filters can use them.
    public var classifier: ECOClassifier?
    /// Replace opening tags that games already have.
    public var overwriteOpeningTags = true
    /// Games must pass this filter.
    public var filter: (any GameFilter)?
    /// Drops games that duplicate an earlier matching game. Duplicates are
    /// detected across every run of the same pipeline, so several files can
    /// be processed as one collection.
    public var duplicates: DuplicateCriterion?
    private var detector: DuplicateDetector?
    /// Only these game numbers (1-based) are processed.
    public var gameNumbers: ClosedRange<Int>?

    public init() {}

    /// Runs the pipeline over one input.
    ///
    /// - Parameters:
    ///   - reader: The input.
    ///   - onDuplicate: Called with each dropped duplicate and the number of
    ///     the game it repeats.
    ///   - body: Called with each game that passes, in input order.
    @discardableResult
    public mutating func run(
        _ reader: PGNCollectionReader,
        onDuplicate: ((ProcessedGame, Int) throws -> Void)? = nil,
        _ body: (ProcessedGame) throws -> Void
    ) throws -> PipelineReport {
        var report = PipelineReport()
        if detector?.criterion != duplicates { detector = duplicates.map { DuplicateDetector(criterion: $0) } }
        var detector = self.detector
        defer { self.detector = detector }
        var reader = reader
        if let gameNumbers {
            if let existing = reader.gameNumbers {
                // Game numbers start at 1, so 0...0 selects nothing.
                reader.gameNumbers = existing.overlaps(gameNumbers) ? existing.clamped(to: gameNumbers) : 0...0
            } else {
                reader.gameNumbers = gameNumbers
            }
        }
        report.read = try reader.forEachGame { record in
            let context = GameContext(record: record)
            var processed = ProcessedGame(record: record)
            if let classifier, overwriteOpeningTags || record.game.tags[.eco] == nil,
               let found = classifier.classify(keys: context.positions.lazy.map(\.key)) {
                report.gamesClassified += 1
                processed.classification = found
                var game = record.game
                for (tag, value) in found.tags {
                    if value != nil, game.tags[tag] == nil, !game.tagOrder.contains(tag) { game.tagOrder.append(tag) }
                    game.tags[tag] = value
                }
                let text = PGNTextEditing.settingTags(found.tags, in: record.text)
                context.record = GameRecord(number: record.number, byteOffset: record.byteOffset, text: text, game: game)
                processed = ProcessedGame(record: context.record, text: text, classification: found)
            }
            if let filter, !filter.matches(context) { return }
            report.gamesMatched += 1
            if detector != nil {
                let key = DuplicateDetector.key(for: context, criterion: detector!.criterion)
                if let original = detector!.check(key: key, gameNumber: record.number) {
                    report.duplicatesRemoved += 1
                    try onDuplicate?(processed, original)
                    return
                }
            }
            report.gamesOutput += 1
            try body(processed)
        }
        report.duplicateGroups = detector?.groups ?? []
        return report
    }
}
