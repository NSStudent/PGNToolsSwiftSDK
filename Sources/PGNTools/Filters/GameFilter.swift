import FischerCore

/// A game being filtered, with its main line positions computed on demand
/// and cached for the other filters.
public final class GameContext {
    /// The game. The pipeline replaces it when it adds opening tags; the
    /// moves never change.
    public internal(set) var record: GameRecord
    public var game: AnnotatedPGNGame { record.game }

    /// The main line positions, starting with the initial position.
    public private(set) lazy var positions: [ReplayedPosition] = record.game.mainlinePositions()

    public init(record: GameRecord) {
        self.record = record
    }
}

/// A condition on a game.
public protocol GameFilter: Sendable {
    func matches(_ context: GameContext) -> Bool
}

public extension GameFilter {
    /// Whether `record` passes the filter.
    func matches(_ record: GameRecord) -> Bool {
        matches(GameContext(record: record))
    }
}

/// Passes games that pass every filter. An empty list passes every game.
public struct AllOf: GameFilter {
    public var filters: [any GameFilter]
    public init(_ filters: [any GameFilter]) { self.filters = filters }
    public func matches(_ context: GameContext) -> Bool { filters.allSatisfy { $0.matches(context) } }
}

/// Passes games that pass at least one filter.
public struct AnyOf: GameFilter {
    public var filters: [any GameFilter]
    public init(_ filters: [any GameFilter]) { self.filters = filters }
    public func matches(_ context: GameContext) -> Bool { filters.contains { $0.matches(context) } }
}

/// Passes games that fail `filter`.
public struct Not: GameFilter {
    public var filter: any GameFilter
    public init(_ filter: any GameFilter) { self.filter = filter }
    public func matches(_ context: GameContext) -> Bool { !filter.matches(context) }
}
