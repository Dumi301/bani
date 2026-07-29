import Foundation

/// A value-type snapshot of one `CategoryRule`, so the pure matching logic can
/// be unit-tested with no SwiftData / no `ModelContext`. `CategoryRuleStore`
/// maps live `CategoryRule`s into these before calling `Categorizer`.
struct CategoryRuleSnapshot: Equatable, Sendable {
    let keyword: String
    let category: TransactionCategory
    let origin: CategoryRuleOrigin
    let hitCount: Int
}

/// Deterministic keyword categorizer — no LLM, no embeddings. Pure value logic,
/// `Sendable`, safe from any isolation context.
///
/// MATCHING PRECEDENCE (`bestMatch`):
/// 1. LEARNED rules beat SEED rules on any conflict.
/// 2. Within the winning tier, the LONGEST keyword wins (a more specific match).
/// 3. Ties on length break on `hitCount` (descending).
/// No match → the caller substitutes `.other` (the chip is never empty).
enum Categorizer {

    /// Diacritic-fold + lowercase, matching `RuleBasedParser.normalize` so the
    /// parser and the categorizer agree on token identity ("benzină" → "benzina").
    static func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "ro_RO")).lowercased()
    }

    /// Splits normalized text into alphanumeric tokens (punctuation dropped).
    static func tokenize(_ normalized: String) -> [String] {
        normalized
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Currency words + numeric tokens are never salient keywords (see
    /// `salientKeyword`) — they carry no category signal.
    static let currencyStopwords: Set<String> = ["lei", "ron", "euro", "eur", "de"]

    /// The category text a transaction is matched/learned on: its description,
    /// plus the merchant when the parser split one out (so a merchant-only
    /// signal like "OMV" still categorizes).
    static func categorizationText(description: String, merchant: String?) -> String {
        guard let merchant, !merchant.isEmpty else { return description }
        return "\(description) \(merchant)"
    }

    /// Whether `keyword` (already normalized) appears in `text`. Single-token
    /// keywords match a whole token; multi-word learned keywords match as a
    /// substring of the normalized text.
    static func matches(text normalized: String, tokens: Set<String>, keyword: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        if keyword.contains(" ") {
            return normalized.contains(keyword)
        }
        return tokens.contains(keyword)
    }

    /// The winning rule for `text`, or `nil` when nothing matches.
    static func bestMatch(for text: String, rules: [CategoryRuleSnapshot]) -> CategoryRuleSnapshot? {
        let normalized = normalize(text)
        let tokenSet = Set(tokenize(normalized))

        let matched = rules.filter { matches(text: normalized, tokens: tokenSet, keyword: $0.keyword) }
        guard !matched.isEmpty else { return nil }

        let learned = matched.filter { $0.origin == .learned }
        let pool = learned.isEmpty ? matched.filter { $0.origin == .seed } : learned

        return pool.max { a, b in
            if a.keyword.count != b.keyword.count { return a.keyword.count < b.keyword.count }
            return a.hitCount < b.hitCount
        }
    }

    /// The category guess for `text` — `.other` when nothing matches, so the
    /// confirmation card's chip is ALWAYS filled, never a placeholder.
    static func category(for text: String, rules: [CategoryRuleSnapshot]) -> TransactionCategory {
        bestMatch(for: text, rules: rules)?.category ?? .other
    }

    /// The keyword a correction should be remembered under: the longest
    /// non-numeric, non-currency token. If there is no such token (e.g. the
    /// description was only an amount), fall back to the full normalized text.
    ///
    /// e.g. "50 lei cafea la Starbucks" → description "cafea la Starbucks" →
    /// candidate tokens [cafea, la, starbucks] → "starbucks" (the longest).
    static func salientKeyword(in text: String) -> String {
        let normalized = normalize(text)
        let tokens = tokenize(normalized)
        let candidates = tokens.filter { token in
            !currencyStopwords.contains(token) && !token.allSatisfy(\.isNumber)
        }
        guard !candidates.isEmpty else {
            return tokens.joined(separator: " ")
        }
        // Longest wins; first occurrence breaks a length tie (deterministic).
        return candidates.max { a, b in a.count < b.count } ?? ""
    }
}
