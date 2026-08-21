import SwiftSyntax

// MARK: - Foundation-Free String Helpers

/// Trims whitespace from both ends of a string without importing Foundation.
/// Swift-native replacement for `NSString.trimmingCharacters(in: .whitespaces)`.
func trimmed(_ s: String) -> String {
    String(s.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
}
