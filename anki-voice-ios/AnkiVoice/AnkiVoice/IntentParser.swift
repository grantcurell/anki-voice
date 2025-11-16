//
//  IntentParser.swift
//  AnkiVoice
//
//  Parses user voice input to determine intent (grade, question, or ambiguous)
//

import Foundation

enum UserIntent {
    case grade(ease: Int, canonical: String, unambiguous: Bool)
    case question(text: String)
    case ambiguous
}

struct IntentParser {

    // Precompiled regexes
    private static let numberWords: [String:Int] = [
        "one":1, "two":2, "three":3, "four":4
    ]

    private static let gradeWords: [String:Int] = [
        // canonical mapping
        "again":1, "wrong":1, "repeat":1, "fail":1, "failed":1, "miss":1, "missed":1, "red":1, // include some colloquials

        "hard":2, "difficult":2, "struggled":2,

        "good":3, "ok":3, "okay":3, "okey":3, "decent":3, "solid":3, "correct":3,

        "easy":4, "trivial":4, "simple":4
    ]

    private static let gradeVerbs = [
        "grade", "mark", "set", "make", "give", "record", "submit"
    ]

    private static let questionStarters = [
        "what","why","how","when","where","who","which",
        "explain","clarify","tell me","give me","compare","example","more about",
        "can you","could you","do you","would you","help me","walk me through","i don't understand","i dont understand","not clear"
    ]

    static func parse(_ raw: String) -> UserIntent {
        let text = normalize(raw)

        if let g = matchGrade(text) {
            return g
        }

        if looksLikeQuestion(text) {
            return .question(text: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Heuristic: longer than 3 words and not a grade → question
        if text.split(separator: " ").count >= 3 {
            return .question(text: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return .ambiguous
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        // Basic cleanup
        t.unicodeScalars.removeAll { CharacterSet.punctuationCharacters.contains($0) && $0 != "?" }
        t = t.replacingOccurrences(of: "  ", with: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchGrade(_ t: String) -> UserIntent? {
        var isUnambiguous = false
        
        // 1) explicit numerals - always unambiguous ("grade 3", "mark 2")
        if let n = extractExplicitNumberCommand(t) {
            if let mapped = mapEase(n) {
                isUnambiguous = true
                return .grade(ease: mapped, canonical: canonicalName(mapped), unambiguous: isUnambiguous)
            }
        }

        // 2) words "one/two/three/four" - unambiguous when with verb ("grade one")
        if let n = extractWordNumberCommand(t) {
            if let mapped = mapEase(n) {
                // Check if it's a command (has grade verb) vs just the word
                let hasVerb = gradeVerbs.contains { t.contains($0) }
                isUnambiguous = hasVerb || t.split(separator: " ").count == 1 // bare number word is clear
                return .grade(ease: mapped, canonical: canonicalName(mapped), unambiguous: isUnambiguous)
            }
        }

        // 3) bare grade words or "mark it X", "grade X", etc.
        if let e = extractWordGrade(t) {
            // Unambiguous if: exact match, starts with verb, or single word
            let tokens = t.split(separator: " ").map(String.init)
            let canonical = canonicalName(e)
            let isExact = t == canonical || t == "grade \(canonical)" || t == "mark \(canonical)"
            let hasVerb = gradeVerbs.contains { t.contains($0) && t.contains(canonical) }
            isUnambiguous = isExact || hasVerb || tokens.count <= 2
            
            // Ambiguous: "that was good", "pretty easy", "kind of hard"
            if t.contains("was") || t.contains("pretty") || t.contains("kind of") || t.contains("sort of") {
                isUnambiguous = false
            }
            
            return .grade(ease: e, canonical: canonical, unambiguous: isUnambiguous)
        }

        return nil
    }

    private static func extractExplicitNumberCommand(_ t: String) -> Int? {
        // Matches: "grade 3", "grade it 2", "mark 4", "give it 1", "set to 3", "make it 2"
        // Also accept bare: "3", "grade three" handled elsewhere
        let tokens = t.split(separator: " ").map(String.init)

        // bare single digit
        if tokens.count == 1, let d = Int(tokens[0]), (1...4).contains(d) {
            return d
        }

        // verb + optional "it/as/to" + number
        for v in gradeVerbs {
            if t.contains(v + " ") {
                if let d = extractTrailingDigit(t) { return d }
            }
        }

        // "give it a 3"
        if let d = matchRegex(t, pattern: #"(?:give|mark|set|make|grade)[^\d]*(\d)"#) {
            if let n = Int(d), (1...4).contains(n) { return n }
        }

        return nil
    }

    private static func extractWordNumberCommand(_ t: String) -> Int? {
        // "grade three", "mark it two", bare "four"
        let tokens = t.split(separator: " ").map(String.init)
        if tokens.count == 1, let n = numberWords[tokens[0]] {
            return n
        }
        for (w,n) in numberWords {
            if t.contains(" \(w)") || t.hasPrefix(w) {
                // ensure it's tied to a grade verb or obvious intent
                for v in gradeVerbs {
                    if t.contains(v) { return n }
                }
            }
        }
        return nil
    }

    private static func extractWordGrade(_ t: String) -> Int? {
        // bare "again/hard/good/easy" or with verbs "mark it good"
        var foundEase: Int?

        for (w, e) in gradeWords {
            if t == w || t.hasPrefix(w + " ") || t.contains(" " + w + " ") || t.hasSuffix(" " + w) {
                foundEase = e
                break
            }
        }
        if foundEase == nil {
            // verb + canonical
            for v in gradeVerbs {
                if t.contains(v + " ") {
                    for (w, e) in gradeWords {
                        if t.contains(" " + w) {
                            foundEase = e
                            break
                        }
                    }
                }
            }
        }
        return foundEase
    }

    private static func looksLikeQuestion(_ t: String) -> Bool {
        if t.contains("?") { return true }
        for q in questionStarters {
            if t == q { return true }
            if t.hasPrefix(q + " ") { return true }
        }
        // common stems
        if t.contains("explain") || t.contains("don't understand") || t.contains("dont understand") ||
           t.contains("not clear") || t.contains("what does") || t.contains("more about") {
            return true
        }
        return false
    }

    private static func extractTrailingDigit(_ t: String) -> Int? {
        if let s = matchRegex(t, pattern: #"(\d)(?:\D*)$"#) {
            if let n = Int(s), (1...4).contains(n) { return n }
        }
        return nil
    }

    private static func matchRegex(_ t: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let r = NSRange(location: 0, length: t.utf16.count)
        if let m = re.firstMatch(in: t, options: [], range: r), m.numberOfRanges >= 2,
           let rg = Range(m.range(at: 1), in: t) {
            return String(t[rg])
        }
        return nil
    }

    private static func mapEase(_ n: Int) -> Int? {
        return (1...4).contains(n) ? n : nil
    }

    private static func canonicalName(_ ease: Int) -> String {
        switch ease {
        case 1: return "again"
        case 2: return "hard"
        case 3: return "good"
        default: return "easy"
        }
    }
}

