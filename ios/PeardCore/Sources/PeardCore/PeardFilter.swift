import Foundation

/// Builds PocketBase filter expressions without letting a user-supplied value
/// change the structure of the expression (Requirement 5.8).
public enum PeardFilter {
    /// Escapes a value for use inside a double-quoted PocketBase filter
    /// literal: backslashes first, then double quotes, then control characters
    /// (which would otherwise terminate or corrupt the expression) are dropped.
    public static func escaped(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            default:
                // Strip C0/C1 controls, including newlines, which PocketBase's
                // parser treats as expression separators.
                if scalar.properties.generalCategory == .control { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// `field = "value"` with `value` escaped.
    public static func equals(_ field: String, _ value: String) -> String {
        "\(field) = \"\(escaped(value))\""
    }

    /// `field != "value"` with `value` escaped.
    public static func notEquals(_ field: String, _ value: String) -> String {
        "\(field) != \"\(escaped(value))\""
    }

    /// Joins clauses with `&&`.
    public static func and(_ clauses: String...) -> String {
        and(clauses)
    }

    public static func and(_ clauses: [String]) -> String {
        clauses.filter { !$0.isEmpty }.joined(separator: " && ")
    }
}
