/// A PGN date, possibly with unknown parts (`2024.??.??`).
public struct PGNDate: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int?
    public let day: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = month == nil ? nil : day
    }

    /// Parses `YYYY.MM.DD`, `YYYY-MM-DD`, `YYYY/MM/DD`, `YYYY.MM` or `YYYY`,
    /// with `?` for unknown parts. Returns `nil` when the year is unknown.
    public init?(_ text: String) {
        let parts = text.trimmed.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "/" }).map(String.init)
        guard let first = parts.first, first.count == 4, let year = Int(first) else { return nil }
        let month = parts.count > 1 ? Int(parts[1]).flatMap { (1...12).contains($0) ? $0 : nil } : nil
        let day = parts.count > 2 ? Int(parts[2]).flatMap { (1...31).contains($0) ? $0 : nil } : nil
        self.init(year: year, month: month, day: day)
    }

    /// The first day the date can stand for, as `yyyymmdd`.
    public var earliest: Int { year * 10_000 + (month ?? 1) * 100 + (day ?? 1) }

    /// The last day the date can stand for, as `yyyymmdd`.
    public var latest: Int { year * 10_000 + (month ?? 12) * 100 + (day ?? 31) }

    public static func < (lhs: PGNDate, rhs: PGNDate) -> Bool {
        (lhs.earliest, lhs.latest) < (rhs.earliest, rhs.latest)
    }

    public var description: String {
        func two(_ value: Int?) -> String { value.map { $0 < 10 ? "0\($0)" : "\($0)" } ?? "??" }
        return "\(year).\(two(month)).\(two(day))"
    }
}
