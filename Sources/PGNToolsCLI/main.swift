import FischerCore
import Foundation
import PGNTools

/// Command line front-end for PGNTools, in the spirit of pgn-extract: one
/// streaming pass that classifies openings, filters, drops duplicates and
/// writes the remaining games in the chosen format.
struct Options {
    var inputs: [String] = []
    var strict = false
    var gameNumbers: ClosedRange<Int>?

    var eco = false
    var keepECO = false
    var ecoTable: String?
    var ecoDepth: Int?

    var filters: [any GameFilter] = []
    var invert = false
    var minElo: Int?
    var maxElo: Int?
    var eloMode = EloFilter.Mode.both
    var dateFrom: PGNDate?
    var dateTo: PGNDate?
    var results: Set<PGNOutcome> = []
    var materialConditions: [MaterialFilter.Condition] = []
    var materialPlies = 1
    var materialFinal = false
    var eitherColor = false
    var fens: [String] = []
    var fenFinal = false

    var duplicates: DuplicateCriterion?
    var duplicatesOutput: String?

    var output: String?
    var format = ExportFormat.pgn
    var positions = GameExporter.Positions.all
    var uciStyle = GameExporter.UCIStyle.moves
    var splitMode: SplitMode?
    var outputDirectory = "."
    var splitName = "part"
    var quiet = false

    static let usage = """
    usage: pgntools [options] FILE...
           pgntools make-eco-index FILE.tsv... [-o openings.tsv]

    Reads PGN files (- for standard input) as a stream and writes the games
    that pass every filter. Unreadable games are skipped and reported on
    standard error with their game number, byte offset and reason.

    Input
      --strict                stop at the first unreadable game
      --games LO[-HI]         only process these game numbers

    Opening classification
      --eco                   add ECO, Opening, Variation and SubVariation tags
      --keep-eco              keep the opening tags games already have
      --eco-table FILE        use another opening table (TSV: eco, name, pgn)
      --eco-depth N           last ply searched for a named position

    Filters (a game must pass all of them)
      --player NAME           White or Black contains NAME
      --white NAME, --black NAME
      --event TEXT, --site TEXT
      --from DATE, --to DATE  Date range (YYYY[.MM[.DD]])
      --result R              1-0, 0-1, 1/2-1/2 or * (repeatable)
      --min-elo N, --max-elo N
      --elo-mode MODE         both (default), either, average, white, black
      --tag "TAG OP VALUE"    OP is == != < <= > >= ~ (repeatable)
      --material PATTERN      material such as "KRP v KR" (repeatable)
      --balance LO[:HI]       White minus Black material in pawns
      --material-plies N      the material must last N plies (default 1)
      --material-final        check material in the final position only
      --either-color          material may also match with colours swapped
      --fen FEN               reaches a position: FEN, EPD or placement with
                              ? ! A a wildcards (repeatable)
      --fen-final             check the final position only
      --invert                output the games that fail the filters

    Duplicates
      --dedup CRITERION       moves, position or tags: drop later duplicates
      --duplicates FILE       write dropped duplicates to FILE

    Output
      -o, --output FILE       output file (default: standard output)
      --format FORMAT         pgn (default), epd, fen, uci, json, jsonl
      --positions WHICH       all (default) or final, for epd and fen
      --uci-position          write UCI as "position startpos moves ..."
      --split-games N         write files of N games to --output-dir
      --split-tag TAG         write one file per value of TAG
      --output-dir DIR        directory for split files (default: .)
      --split-name NAME       prefix for --split-games files (default: part)
      -q, --quiet             do not print the summary
    """

    init(arguments: [String]) throws {
        var index = 0
        func next() throws -> String {
            index += 1
            guard index < arguments.count else {
                throw PGNToolsError(.invalidArgument, "missing value for \(arguments[index - 1])")
            }
            return arguments[index]
        }
        func number() throws -> Int {
            let text = try next()
            guard let value = Int(text) else { throw PGNToolsError(.invalidArgument, "expected a number, got \(text)") }
            return value
        }
        func date() throws -> PGNDate {
            let text = try next()
            guard let value = PGNDate(text) else { throw PGNToolsError(.invalidArgument, "invalid date \(text)") }
            return value
        }
        func range(_ text: String, separators: Set<Character>) throws -> ClosedRange<Int> {
            // Accept "LO", "LO-HI" or "LO:HI"; a leading minus is a sign.
            if let low = Int(text) { return low...low }
            for (offset, character) in text.enumerated() where offset > 0 && separators.contains(character) {
                let split = text.index(text.startIndex, offsetBy: offset)
                if let low = Int(text[..<split]), let high = Int(text[text.index(after: split)...]), low <= high {
                    return low...high
                }
            }
            throw PGNToolsError(.invalidArgument, "invalid range \(text)")
        }
        func choice<T: RawRepresentable & CaseIterable>(_ type: T.Type) throws -> T where T.RawValue == String {
            let text = try next()
            guard let value = T(rawValue: text) else {
                let names = T.allCases.map(\.rawValue).joined(separator: ", ")
                throw PGNToolsError(.invalidArgument, "\(text) is not one of: \(names)")
            }
            return value
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--strict": strict = true
            case "--games": gameNumbers = try range(try next(), separators: ["-", ":"])
            case "--eco": eco = true
            case "--keep-eco": keepECO = true
            case "--eco-table": ecoTable = try next(); eco = true
            case "--eco-depth": ecoDepth = try number()
            case "--player": filters.append(PlayerFilter(try next()))
            case "--white": filters.append(PlayerFilter(try next(), side: .white))
            case "--black": filters.append(PlayerFilter(try next(), side: .black))
            case "--event": filters.append(TagFilter(.event, .contains, try next()))
            case "--site": filters.append(TagFilter(.site, .contains, try next()))
            case "--from": dateFrom = try date()
            case "--to": dateTo = try date()
            case "--result":
                let text = try next()
                guard let result = PGNOutcome(rawValue: text) else {
                    throw PGNToolsError(.invalidArgument, "invalid result \(text)")
                }
                results.insert(result)
            case "--min-elo": minElo = try number()
            case "--max-elo": maxElo = try number()
            case "--elo-mode": eloMode = try choice(EloFilter.Mode.self)
            case "--tag": filters.append(try TagFilter(try next()))
            case "--material": materialConditions.append(.pattern(try MaterialPattern(try next())))
            case "--balance": materialConditions.append(.balance(try range(try next(), separators: [":"])))
            case "--material-plies": materialPlies = try number()
            case "--material-final": materialFinal = true
            case "--either-color", "--either-colour": eitherColor = true
            case "--fen": fens.append(try next())
            case "--fen-final": fenFinal = true
            case "--invert": invert = true
            case "--dedup":
                let text = try next()
                switch text {
                case "moves": duplicates = .sameMoves
                case "position": duplicates = .sameFinalPosition
                case "tags": duplicates = .sameTagsAndMoves()
                default: throw PGNToolsError(.invalidArgument, "--dedup takes moves, position or tags")
                }
            case "--duplicates": duplicatesOutput = try next()
            case "-o", "--output": output = try next()
            case "--format": format = try choice(ExportFormat.self)
            case "--positions": positions = try choice(GameExporter.Positions.self)
            case "--uci-position": uciStyle = .position
            case "--split-games":
                let size = try number()
                guard size > 0 else { throw PGNToolsError(.invalidArgument, "--split-games needs a positive number") }
                splitMode = .gamesPerFile(size)
            case "--split-tag":
                let name = try next()
                splitMode = .byTag(PGNTag(rawValue: name) ?? .custom(name))
            case "--output-dir": outputDirectory = try next()
            case "--split-name": splitName = try next()
            case "-q", "--quiet": quiet = true
            case "-h", "--help":
                print(Self.usage)
                exit(0)
            default:
                guard argument == "-" || !argument.hasPrefix("-") else {
                    throw PGNToolsError(.invalidArgument, "unknown option \(argument)")
                }
                inputs.append(argument)
            }
            index += 1
        }
        guard !inputs.isEmpty else { throw PGNToolsError(.invalidArgument, "no input files (see --help)") }
        if splitMode != nil, format != .pgn {
            throw PGNToolsError(.invalidArgument, "splitting writes PGN files; --format cannot be used with it")
        }
    }

    /// Every filter from the options, combined.
    func filter() throws -> (any GameFilter)? {
        var all = filters
        if dateFrom != nil || dateTo != nil { all.append(DateRangeFilter(from: dateFrom, to: dateTo)) }
        if !results.isEmpty { all.append(ResultFilter(results)) }
        if minElo != nil || maxElo != nil { all.append(EloFilter(minimum: minElo, maximum: maxElo, mode: eloMode)) }
        let scope: MaterialFilter.Scope = materialFinal ? .finalPosition : .anyPosition(minPlies: materialPlies)
        for condition in materialConditions {
            all.append(MaterialFilter(condition, scope: scope, eitherColor: eitherColor))
        }
        if !fens.isEmpty { all.append(try PositionFilter(fens: fens, finalPositionOnly: fenFinal)) }
        guard !all.isEmpty else { return nil }
        let combined = AllOf(all)
        return invert ? Not(combined) : combined
    }
}

/// Buffers text and writes it to a file or standard output in large blocks.
final class OutputStream {
    private let handle: FileHandle
    private let closes: Bool
    private var buffer = Data()

    init(path: String?) throws {
        if let path, path != "-" {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else {
                throw PGNToolsError(.output, "cannot write \(path)")
            }
            // Devices such as /dev/null cannot be truncated.
            try? handle.truncate(atOffset: 0)
            self.handle = handle
            closes = true
        } else {
            handle = FileHandle.standardOutput
            closes = false
        }
    }

    func write(_ text: String) {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= 65_536 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        flush()
        if closes { try? handle.close() }
    }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// `pgntools make-eco-index`: builds the bundled opening index from the
/// lichess-org/chess-openings TSV files.
func makeECOIndex(_ arguments: [String]) throws {
    var files: [String] = []
    var output: String?
    var index = 0
    while index < arguments.count {
        if arguments[index] == "-o", index + 1 < arguments.count {
            output = arguments[index + 1]
            index += 2
            continue
        }
        files.append(arguments[index])
        index += 1
    }
    guard !files.isEmpty else { throw PGNToolsError(.invalidArgument, "no TSV files") }
    var openings: [Opening] = []
    for file in files {
        openings += try ECODatabase(contentsOf: URL(fileURLWithPath: file)).openings
    }
    let stream = try OutputStream(path: output)
    stream.write(ECODatabase(openings: openings).indexTSV)
    stream.close()
    printError("\(openings.count) openings written")
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "make-eco-index" {
        try makeECOIndex(Array(arguments.dropFirst()))
        return
    }
    let options = try Options(arguments: arguments)

    var pipeline = PGNPipeline()
    if options.eco {
        let database = try options.ecoTable.map { try ECODatabase(contentsOf: URL(fileURLWithPath: $0)) } ?? .lichess
        pipeline.classifier = ECOClassifier(database: database, maxPly: options.ecoDepth)
        pipeline.overwriteOpeningTags = !options.keepECO
    }
    pipeline.filter = try options.filter()
    pipeline.duplicates = options.duplicates
    pipeline.gameNumbers = options.gameNumbers

    var exporter = GameExporter(format: options.format, positions: options.positions, uciStyle: options.uciStyle)
    var splitter = try options.splitMode.map {
        try FileSplitter(mode: $0, directory: URL(fileURLWithPath: options.outputDirectory), baseName: options.splitName)
    }
    let output = splitter == nil ? try OutputStream(path: options.output) : nil
    let duplicatesOutput = try options.duplicatesOutput.map { try OutputStream(path: $0) }
    var duplicateExporter = GameExporter(format: .pgn)
    output?.write(exporter.header())

    var totals = PipelineReport()
    for input in options.inputs {
        let source: PGNSource = input == "-"
            ? .data(FileHandle.standardInput.readDataToEndOfFile())
            : .file(URL(fileURLWithPath: input))
        let strict = options.strict
        let reader = PGNCollectionReader(source: source, onInvalidGame: { failure in
            printError("\(input): skipped \(failure)")
            return strict ? .abort : .skip
        })
        let report = try pipeline.run(reader, onDuplicate: { game, _ in
            duplicatesOutput?.write(duplicateExporter.export(game))
        }) { game in
            if splitter != nil {
                try splitter!.add(game)
            } else {
                output?.write(exporter.export(game))
            }
        }
        for partial in report.read.partiallyReadGames {
            printError("\(input): partially read \(partial)")
        }
        totals.read.gamesFound += report.read.gamesFound
        totals.read.gamesRead += report.read.gamesRead
        totals.read.skippedGames += report.read.skippedGames
        totals.gamesMatched += report.gamesMatched
        totals.gamesOutput += report.gamesOutput
        totals.duplicatesRemoved += report.duplicatesRemoved
        totals.gamesClassified += report.gamesClassified
    }
    output?.write(exporter.footer())
    output?.close()
    duplicatesOutput?.close()
    let files = try splitter?.finish() ?? []

    if !options.quiet {
        var summary = "\(totals.read.gamesFound) games, \(totals.read.skippedGames.count) skipped"
        if pipeline.filter != nil { summary += ", \(totals.gamesMatched) matched" }
        if options.duplicates != nil { summary += ", \(totals.duplicatesRemoved) duplicates removed" }
        if options.eco { summary += ", \(totals.gamesClassified) classified" }
        summary += ", \(totals.gamesOutput) written"
        if !files.isEmpty { summary += " to \(files.count) files in \(options.outputDirectory)" }
        printError(summary)
    }
}

do {
    try run()
} catch {
    printError("pgntools: \(error)")
    exit(1)
}
