import FischerCore

/// The pieces of one side, kings excluded.
public struct SideMaterial: Hashable, Sendable, CustomStringConvertible {
    public var queens = 0
    public var rooks = 0
    public var bishops = 0
    public var knights = 0
    public var pawns = 0

    public init(queens: Int = 0, rooks: Int = 0, bishops: Int = 0, knights: Int = 0, pawns: Int = 0) {
        self.queens = queens
        self.rooks = rooks
        self.bishops = bishops
        self.knights = knights
        self.pawns = pawns
    }

    /// The value in pawns, counting minor pieces as 3, rooks as 5 and
    /// queens as 9.
    public var points: Int { queens * 9 + rooks * 5 + (bishops + knights) * 3 + pawns }

    /// The count of pieces of `kind`; kings always count 0.
    public subscript(kind: Piece.Kind) -> Int {
        get {
            switch kind {
            case .queen: queens
            case .rook: rooks
            case .bishop: bishops
            case .knight: knights
            case .pawn: pawns
            case .king: 0
            }
        }
        set {
            switch kind {
            case .queen: queens = newValue
            case .rook: rooks = newValue
            case .bishop: bishops = newValue
            case .knight: knights = newValue
            case .pawn: pawns = newValue
            case .king: break
            }
        }
    }

    /// Pieces in the usual order, for example `QRRBP4`.
    public var description: String {
        var text = "K"
        for (letter, count) in [("Q", queens), ("R", rooks), ("B", bishops), ("N", knights)] {
            text += String(repeating: letter, count: count)
        }
        if pawns > 0 { text += pawns == 1 ? "P" : "P\(pawns)" }
        return text
    }
}

/// The material of both sides of a position.
public struct Material: Hashable, Sendable, CustomStringConvertible {
    public var white: SideMaterial
    public var black: SideMaterial

    public init(white: SideMaterial, black: SideMaterial) {
        self.white = white
        self.black = black
    }

    /// Counts the pieces on `board`.
    public init(board: Board) {
        var white = SideMaterial()
        var black = SideMaterial()
        for space in board {
            guard let piece = space.piece else { continue }
            if piece.color == .white {
                white[piece.kind] += 1
            } else {
                black[piece.kind] += 1
            }
        }
        self.init(white: white, black: black)
    }

    /// White's points minus Black's points.
    public var balance: Int { white.points - black.points }

    /// The same material with the colours exchanged.
    public var swapped: Material { Material(white: black, black: white) }

    public var description: String { "\(white) v \(black)" }
}

/// A pattern of material to look for, such as "rook and pawn against rook".
///
/// The text form has one side spec for White and one for Black, separated
/// by `v`, `vs` or `:`. A side spec lists piece letters (`Q R B N P`; `K` is
/// optional and ignored). Each letter may be followed by a quantifier:
///
/// - a number: exactly that many (`P3`, the same as `PPP`);
/// - `*`: any number, including none (`P*`);
/// - `+`: at least one (`P+`);
/// - `N-M` or `N+`: a range (`P2-4`, `P2+`).
///
/// Pieces that are not mentioned must be absent. Examples: `KRP v KR`,
/// `Q P* : R R P*`, `B+ N* P* v P*`.
public struct MaterialPattern: Sendable, Equatable, CustomStringConvertible {
    public var white: [Piece.Kind: ClosedRange<Int>]
    public var black: [Piece.Kind: ClosedRange<Int>]

    public init(white: [Piece.Kind: ClosedRange<Int>], black: [Piece.Kind: ClosedRange<Int>]) {
        self.white = white
        self.black = black
    }

    /// Parses the text form described in the type documentation.
    public init(_ text: String) throws(PGNToolsError) {
        // The sides are separated by ':' or by 'v' / 'vs' (no piece uses V).
        guard let separator = text.firstIndex(where: { $0 == ":" || $0 == "v" || $0 == "V" }) else {
            throw PGNToolsError(.invalidArgument, "material pattern \"\(text)\" needs two sides separated by 'v' or ':'")
        }
        var rest = text[text.index(after: separator)...]
        if text[separator] != ":", rest.first == "s" || rest.first == "S" { rest = rest.dropFirst() }
        white = try Self.parseSide(String(text[..<separator]), in: text)
        black = try Self.parseSide(String(rest), in: text)
    }

    /// Whether `material` fits the pattern.
    public func matches(_ material: Material) -> Bool {
        Self.matches(white, material.white) && Self.matches(black, material.black)
    }

    public var description: String {
        "\(Self.describe(white)) v \(Self.describe(black))"
    }

    private static let kinds: [(Character, Piece.Kind)] = [
        ("Q", .queen), ("R", .rook), ("B", .bishop), ("N", .knight), ("P", .pawn),
    ]

    private static func matches(_ side: [Piece.Kind: ClosedRange<Int>], _ material: SideMaterial) -> Bool {
        kinds.allSatisfy { _, kind in (side[kind] ?? 0...0).contains(material[kind]) }
    }

    private static func describe(_ side: [Piece.Kind: ClosedRange<Int>]) -> String {
        var text = "K"
        for (letter, kind) in kinds {
            guard let range = side[kind] else { continue }
            if range == 1...1 {
                text.append(letter)
            } else if range.upperBound == Int.max {
                text += range.lowerBound == 0 ? "\(letter)*" : "\(letter)\(range.lowerBound)+"
            } else if range.lowerBound == range.upperBound {
                text += "\(letter)\(range.lowerBound)"
            } else {
                text += "\(letter)\(range.lowerBound)-\(range.upperBound)"
            }
        }
        return text
    }

    private static func parseSide(_ text: String, in pattern: String) throws(PGNToolsError) -> [Piece.Kind: ClosedRange<Int>] {
        var result: [Piece.Kind: ClosedRange<Int>] = [:]
        var characters = Array(text.uppercased().filter { !$0.isWhitespace })[...]
        func number() -> Int? {
            let digits = characters.prefix(while: \.isNumber)
            characters = characters.dropFirst(digits.count)
            return digits.isEmpty ? nil : Int(String(digits))
        }
        while let letter = characters.popFirst() {
            if letter == "K" { continue }
            guard let kind = kinds.first(where: { $0.0 == letter })?.1 else {
                throw PGNToolsError(.invalidArgument, "unknown piece '\(letter)' in material pattern \"\(pattern)\"")
            }
            var range: ClosedRange<Int>
            if characters.first == "*" {
                characters.removeFirst()
                range = 0...Int.max
            } else if characters.first == "+" {
                characters.removeFirst()
                range = 1...Int.max
            } else if let low = number() {
                range = low...low
                if characters.first == "+" {
                    characters.removeFirst()
                    range = low...Int.max
                } else if characters.first == "-" {
                    characters.removeFirst()
                    guard let high = number(), high >= low else {
                        throw PGNToolsError(.invalidArgument, "bad range in material pattern \"\(pattern)\"")
                    }
                    range = low...high
                }
            } else {
                range = 1...1
            }
            if let previous = result[kind] {
                // Repeated letters add up: "RR" means two rooks.
                let upper = previous.upperBound == Int.max || range.upperBound == Int.max
                    ? Int.max : previous.upperBound + range.upperBound
                range = (previous.lowerBound + range.lowerBound)...upper
            }
            result[kind] = range
        }
        return result
    }
}
