# PGNToolsSwiftSDK

PGN collection tools for Swift, built on
[fischer-core](https://github.com/NSStudent/fischer-core): automatic ECO
classification, duplicate detection, filters by tags, material and position,
splitting, and export to EPD, FEN, UCI and JSON. It is a library plus a
command line tool, `pgntools`, that covers much of the ground of
[pgn-extract](https://www.cs.kent.ac.uk/people/staff/djb/pgn-extract/).

PGNToolsSwiftSDK is an independent implementation written from pgn-extract's
documentation. It contains no pgn-extract code (pgn-extract is GPL v3).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/NSStudent/PGNToolsSwiftSDK.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "PGNTools", package: "PGNToolsSwiftSDK")]),
]
```

Requires Swift 6 (tools 6.0), macOS 13 or iOS 16.

## Products

| Product | Kind | Description |
| --- | --- | --- |
| `PGNTools` | library | Reader, ECO classifier, duplicates, filters, exporters, splitter and pipeline. |
| `pgntools` | executable | Command line front-end to the library. |

## Using the library

### Reading large collections

`PGNCollectionReader` splits the input into games with fischer-core's
`PGNByteChunker` while it reads the file, so memory use does not grow with the
file size. A game that cannot be read is skipped and reported with its game
number, byte offset and reason; the run carries on.

```swift
import PGNTools

let reader = PGNCollectionReader(source: .file(url))
let report = try reader.forEachGame { record in
    // record.number, record.byteOffset, record.text, record.game (AnnotatedPGNGame)
}
for failure in report.skippedGames {
    print(failure) // "game 5 (byte 1072): invalid FEN tag "…""
}
```

`report.partiallyReadGames` lists games that were read up to an illegal move.
Pass `onInvalidGame: { _ in .abort }` to stop at the first unreadable game, and
set `gameNumbers` to read only part of a file.

### ECO classification

The classifier replays the main line, looks every position up by its Zobrist
key and returns the opening of the **last** named position the game reaches.
Since the lookup uses positions rather than move sequences, transpositions are
handled: `1.e4 c5 2.Nf3 d6 3.d4 cxd4 4.Nxd4 a6 5.Nc3 Nf6 6.Be3` is classified
as *B90 Sicilian Defense: Najdorf Variation, English Attack*, although the
table lists that position with `4...Nf6 5.Nc3 a6`.

On import, one game at a time:

```swift
let classifier = ECOClassifier()                  // bundled lichess table
if let found = classifier.classify(game) {        // AnnotatedPGNGame or Game
    found.opening.eco          // "B90"
    found.opening.name         // "Sicilian Defense: Najdorf Variation, English Attack"
    found.opening.family       // "Sicilian Defense"
    found.opening.variation    // "Najdorf Variation"
    found.opening.subVariation // "English Attack"
    found.ply                  // 11: where the named position was reached
}
classifier.classify(uciMoves: ["d2d4", "d7d5", "c2c4"])   // Queen's Gambit
let tagged = classifier.tagging(game)                      // sets ECO, Opening, Variation, SubVariation
let text = classifier.taggedText(record)                   // same, editing only the tag lines
```

For a whole file, use the pipeline (below) with `pipeline.classifier = ECOClassifier()`.
By default positions after the table's longest line plus 10 plies are not
looked up; pass `maxPly: Int.max` to search whole games. Load another table in
the lichess TSV format with `ECODatabase(contentsOf:)`.

### Duplicates

```swift
var detector = DuplicateDetector(criterion: .sameMoves)
try reader.forEachGame { record in
    if let original = detector.check(record) { print("\(record.number) repeats \(original)") }
}
detector.groups // [DuplicateGroup(original: 1, duplicates: [2])]
```

| Criterion | Same when |
| --- | --- |
| `.sameMoves` | main line moves and starting position match; comments, variations, NAGs, move number style and tags are ignored |
| `.sameFinalPosition` | the final position matches (placement, side to move, castling, en passant), however it was reached |
| `.sameTagsAndMoves(tags:)` | the moves match and so do the tags (default White, Black, Event, Site, Round, Date, Result; case and whitespace insensitive) |

### Filters

Every filter conforms to `GameFilter`; combine them with `AllOf`, `AnyOf` and
`Not`.

```swift
let filter = AllOf([
    PlayerFilter("Carlsen"),                          // White or Black; also side: .white / .black
    TagFilter(.event, .contains, "Olympiad"),
    DateRangeFilter(from: PGNDate("2020"), to: PGNDate("2023.06.30")),
    ResultFilter([.win, .draw]),
    EloFilter(minimum: 2600, mode: .both),            // .either, .average, .white, .black
    try TagFilter("WhiteElo >= 2700"),                // == != < <= > >= ~
    MaterialFilter(.pattern(try MaterialPattern("KRP v KR")), scope: .anyPosition(minPlies: 4)),
    MaterialFilter(.balance(2...9), scope: .finalPosition, eitherColor: true),
    try PositionFilter(fen: "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N1B3/PPP2PPP/R2QKB1R b KQkq -"),
])
filter.matches(record)
```

- **Tags:** numbers compare numerically, `Date`/`EventDate`/`UTCDate` compare
  as dates, other values as text without case or diacritics. Dates with unknown
  parts (`2010.??.??`) stand for every day they could be.
- **Material patterns:** one side per colour, separated by `v` or `:`. Letters
  `Q R B N P` (a `K` is optional), each optionally followed by a count (`P3`),
  `*` (any number), `+` (at least one) or a range (`P2-4`, `P2+`). Pieces not
  listed must be absent.
- **Material balance:** White's material minus Black's in pawns (3/3/5/9).
- **Positions:** a FEN or EPD with castling rights matches the exact position
  (move counters ignored); `placement w|b` matches placement and side to move;
  a bare placement may use one-square wildcards: `?` anything, `!` any piece,
  `A` any white piece, `a` any black piece, `-` empty.

### Export

```swift
var exporter = GameExporter(format: .json)   // .pgn, .epd, .fen, .uci, .jsonl
var output = exporter.header()
for game in games { output += exporter.export(game) }
output += exporter.footer()
```

| Format | Output |
| --- | --- |
| `pgn` | The original game text, with any added tags |
| `epd` | One line per position: `<epd> hmvc 0; fmvn 4; id "g7.p7";` |
| `fen` | One FEN per position; a blank line between games |
| `uci` | One line of UCI moves per game, or `position startpos moves …` with `uciStyle: .position` |
| `json` | An array of objects with `number`, `tags`, `result`, `initialFEN`, `moves` (SAN), `uci`, `finalFEN` and `eco` |
| `jsonl` | The same objects, one per line |

EPD and FEN take `positions: .all` (default, every main line position) or
`.final`.

### Splitting

```swift
var splitter = try FileSplitter(mode: .gamesPerFile(1000), directory: outputURL)  // or .byTag(.eco)
try reader.forEachGame { try splitter.add(ProcessedGame(record: $0)) }
let files = try splitter.finish()   // part-0001.pgn, part-0002.pgn, …
```

`CollectionSplitter` does the same in memory.

### The pipeline

`PGNPipeline` does everything in one streaming pass: it classifies openings
(so tag filters can use them), filters, drops duplicates and hands each
remaining game to you.

```swift
var pipeline = PGNPipeline()
pipeline.classifier = ECOClassifier()
pipeline.filter = AllOf([try TagFilter("ECO == B90"), EloFilter(minimum: 2500)])
pipeline.duplicates = .sameMoves
let report = try pipeline.run(PGNCollectionReader(source: .file(url)),
                              onDuplicate: { game, original in /* … */ }) { game in
    // game.text has the new opening tags; game.classification has the opening
}
```

## Command line

```
pgntools [options] FILE...
```

Games are written to standard output (or `-o FILE`); warnings about skipped
games and a summary go to standard error. `pgntools --help` lists every
option. Some examples:

```bash
# Add ECO, Opening, Variation and SubVariation tags to every game
pgntools --eco games.pgn -o classified.pgn

# Carlsen's wins with both players rated 2700+, without duplicate games
pgntools --player Carlsen --result 1-0 --min-elo 2700 --dedup moves games.pgn

# Rook and pawn against rook lasting at least 6 plies, as JSON Lines
pgntools --material "KRP v KR" --material-plies 6 --format jsonl games.pgn

# Games reaching a position, as UCI position commands
pgntools --fen "rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N1B3/PPP2PPP/R2QKB1R b" --format uci --uci-position games.pgn

# One file per ECO code, and files of 1000 games
pgntools --eco --split-tag ECO --output-dir by-eco games.pgn
pgntools --split-games 1000 --output-dir parts games.pgn

# Final positions as EPD; duplicates written to their own file
pgntools --format epd --positions final --dedup position --duplicates dups.pgn games.pgn
```

## Implementation status

**Supported**

- Streaming input from files, memory or standard input, split with
  `PGNByteChunker`; UTF-8 or Latin-1 per line. Unreadable games are skipped and
  reported with game number, byte offset and reason (or abort with `--strict`);
  games cut short by an illegal move are reported as partially read.
- ECO classification by position key from the last named position, with
  transpositions, for single games (`AnnotatedPGNGame`, `Game`, UCI moves) and
  whole files. Writes `ECO`, `Opening`, `Variation` and `SubVariation`,
  replacing or keeping existing tags. Custom tables in the lichess TSV format.
- Duplicate detection by moves, by final position, or by tags plus moves;
  duplicates can be dropped, listed in groups or written to their own file.
  Detection works across several input files.
- Filters: player (either colour or one), event, site, any tag with
  `== != < <= > >= ~`, date range, result, Elo (both, either, average, white,
  black), material patterns (with minimum duration, final position only, either
  colour), material balance, positions by FEN/EPD/placement with one-square
  wildcards, game number ranges, `AllOf`/`AnyOf`/`Not` and `--invert`.
- Splitting into files of N games or by tag value.
- Export to PGN (original text kept), EPD, FEN per position, UCI move lists or
  `position` commands, JSON and JSON Lines.

**Not yet implemented** (pgn-extract features without an equivalent yet)

- Matching move sequences or variations (pgn-extract's `-v`/`-x` variation
  files) and searching positions inside variations; only the main line is
  examined.
- The `*` wildcard (any number of squares) in placement patterns, and
  pgn-extract's tag criteria and ECO files in its own formats.
- Filters for checkmate, stalemate, repetition, the fifty-move rule, game
  length and underpromotion; move-count tags such as `PlyCount`.
- Rewriting the movetext: notation conversion (long algebraic, other
  languages), removing comments, NAGs or variations, adding FEN comments after
  each move. (fischer-core's `PGNWriter` can do some of this on
  `AnnotatedPGNGame`.)
- Null moves (`--`): fischer-core cannot read them yet.

## Opening data and licences

The ECO table comes from
[lichess-org/chess-openings](https://github.com/lichess-org/chess-openings)
(commit `3ba6b20`, 3,865 lines). As a collection of facts it is in the public
domain, and the curation is released under the
[CC0 1.0 Public Domain Dedication](https://creativecommons.org/publicdomain/zero/1.0/).
The unchanged source files are in `Data/chess-openings`. The bundled
`Sources/PGNTools/Resources/openings.tsv` adds a UCI column and the Zobrist key
of each position so the table loads without replaying moves.

Position keys use a fixed SplitMix64 sequence, so they are stable across runs
and platforms, but they are not Polyglot keys.

## Development

```bash
swift build
swift test
```

After updating `Data/chess-openings`, regenerate the bundled index:

```bash
swift run pgntools make-eco-index Data/chess-openings/{a,b,c,d,e}.tsv -o Sources/PGNTools/Resources/openings.tsv
```

A test checks a sample of the index against the source files.

## License

The code is released under the MIT License. The opening data
(`Data/chess-openings` and the bundled `Sources/PGNTools/Resources/openings.tsv`
built from it) keeps its original licence: public domain / CC0 1.0, as
described in [Opening data and licences](#opening-data-and-licences). See
[LICENSE](LICENSE).
