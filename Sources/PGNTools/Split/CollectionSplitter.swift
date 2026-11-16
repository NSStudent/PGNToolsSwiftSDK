import FischerCore
import Foundation

/// How a collection is divided into parts.
public enum SplitMode: Sendable, Equatable {
    /// Consecutive parts of at most `n` games.
    case gamesPerFile(Int)
    /// One part per value of a tag, such as `ECO` or `Event`. Games without
    /// the tag go to the part named `unknown`.
    case byTag(PGNTag)
}

/// Divides a stream of games into named parts.
///
/// In memory:
///
/// ```swift
/// var splitter = CollectionSplitter(mode: .gamesPerFile(1000))
/// for game in games { splitter.add(game) }
/// let parts = splitter.parts // [(name: "part-0001", text: "...")]
/// ```
///
/// Or straight to files with ``FileSplitter``.
public struct CollectionSplitter: Sendable {
    public let mode: SplitMode
    /// Prefix of the part names for ``SplitMode/gamesPerFile(_:)``.
    public var baseName: String
    private var gamesSeen = 0
    private var order: [String] = []
    private var texts: [String: String] = [:]

    public init(mode: SplitMode, baseName: String = "part") {
        self.mode = mode
        self.baseName = baseName
    }

    /// The name of the part `game` belongs to; `index` is the 0-based
    /// position of the game among the games added.
    public func partName(for game: ProcessedGame, index: Int) -> String {
        switch mode {
        case .gamesPerFile(let size):
            let number = String(index / max(1, size) + 1)
            return "\(baseName)-\(String(repeating: "0", count: max(0, 4 - number.count)))\(number)"
        case .byTag(let tag):
            let value = game.record.game.tags[tag]?.trimmed ?? ""
            return Self.safeFileName(value.isEmpty || value == "?" ? "unknown" : value)
        }
    }

    /// Returns the name of the part of the next game without storing it.
    public mutating func assign(_ game: ProcessedGame) -> String {
        defer { gamesSeen += 1 }
        return partName(for: game, index: gamesSeen)
    }

    /// Adds a game and returns the name of its part.
    @discardableResult
    public mutating func add(_ game: ProcessedGame) -> String {
        let name = assign(game)
        if let existing = texts[name] {
            texts[name] = existing + "\n" + game.text + "\n"
        } else {
            order.append(name)
            texts[name] = game.text + "\n"
        }
        return name
    }

    /// The parts in order of first appearance, as PGN text.
    public var parts: [(name: String, text: String)] {
        order.map { ($0, texts[$0] ?? "") }
    }

    /// Replaces characters that are not safe in file names.
    public static func safeFileName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.+ "))
        let mapped = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "unknown" : String(trimmed.prefix(100))
    }
}

/// Writes the parts of a split collection to `.pgn` files in a directory,
/// buffering a little text per part so few files are open at once.
public struct FileSplitter {
    public let directory: URL
    private var splitter: CollectionSplitter
    private var buffers: [String: String] = [:]
    private var written: Set<String> = []
    private var order: [String] = []
    private var bufferedBytes = 0
    /// Bytes buffered before everything is flushed to disk.
    public var flushThreshold: Int = 4 * 1_048_576

    /// Creates the directory if needed.
    public init(mode: SplitMode, directory: URL, baseName: String = "part") throws(PGNToolsError) {
        self.directory = directory
        self.splitter = CollectionSplitter(mode: mode, baseName: baseName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PGNToolsError(.output, "cannot create \(directory.path): \(error.localizedDescription)")
        }
    }

    /// Adds a game to its part.
    public mutating func add(_ game: ProcessedGame) throws(PGNToolsError) {
        let name = splitter.assign(game)
        if buffers[name] == nil && !written.contains(name) { order.append(name) }
        let separator = buffers[name] != nil || written.contains(name) ? "\n" : ""
        let text = separator + game.text + "\n"
        buffers[name, default: ""] += text
        bufferedBytes += text.utf8.count
        // Parts of consecutive games are complete once the next one starts.
        if bufferedBytes >= flushThreshold { try flush() }
        if case .gamesPerFile = splitter.mode, buffers.count > 1 { try flush() }
    }

    /// Writes what is buffered and returns the files of every part, in
    /// order of first appearance.
    public mutating func finish() throws(PGNToolsError) -> [URL] {
        try flush()
        return order.map(url(for:))
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("pgn")
    }

    private mutating func flush() throws(PGNToolsError) {
        for (name, text) in buffers {
            let url = url(for: name)
            do {
                if written.contains(name), let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(text.utf8))
                } else {
                    try Data(text.utf8).write(to: url)
                }
            } catch {
                throw PGNToolsError(.output, "cannot write \(url.path): \(error.localizedDescription)")
            }
            written.insert(name)
        }
        buffers.removeAll(keepingCapacity: true)
        bufferedBytes = 0
    }
}
