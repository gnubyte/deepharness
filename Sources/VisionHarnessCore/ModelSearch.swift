import Foundation

// MARK: - Searching the model picker
//
// The list gets long: every Guardian model, every Bedrock route, each Spark
// model, local servers, and Guardian's people. The picker narrows it with a
// search box and a row of source filters; this is the pure part.

/// Where an entry in the model picker comes from. The picker shows a filter
/// chip only for the sources that actually have entries.
public enum ModelSource: String, CaseIterable, Hashable, Sendable, Identifiable {
    case guardian, guardianLocal, people, spark, bedrock, local, hosted

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .guardian: "Guardian"
        case .guardianLocal: "Guardian local"
        case .people: "People"
        case .spark: "Spark"
        case .bedrock: "Bedrock"
        case .local: "Local"
        case .hosted: "Hosted"
        }
    }
}

public enum ModelSearch {
    /// Every whitespace-separated word of the query must appear somewhere in
    /// the fields, in any order and any case. "qwen orb" finds "Orbital · qwen3.6".
    public static func matches(query: String, fields: [String]) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = fields.joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}
