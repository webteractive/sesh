/// Case-insensitive subsequence scorer for the palette and menu bar search.
public enum FuzzyMatcher {
    /// nil = no match. Higher = better: +8 first-char prefix, +4 word
    /// boundary, +6 consecutive run, +1 per hit, small length penalty so
    /// tighter candidates win ties.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        if q.isEmpty { return 0 }

        var total = 0
        var searchFrom = 0
        var previousHit: Int? = nil

        for ch in q {
            var found: Int? = nil
            var i = searchFrom
            while i < c.count {
                if c[i] == ch { found = i; break }
                i += 1
            }
            guard let hit = found else { return nil }

            var gain = 1
            if hit == 0 {
                gain += 8
            } else {
                let before = c[hit - 1]
                if !before.isLetter && !before.isNumber { gain += 4 }
            }
            if let prev = previousHit, hit == prev + 1 { gain += 6 }

            total += gain
            previousHit = hit
            searchFrom = hit + 1
        }
        total -= max(0, c.count - q.count) / 4
        return total
    }
}
