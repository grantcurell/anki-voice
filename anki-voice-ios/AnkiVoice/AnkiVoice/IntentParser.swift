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

    // English dictionaries
    private static let numberWordsEN: [String:Int] = [
        "one":1, "two":2, "three":3, "four":4
    ]
    private static let numberWordsES: [String:Int] = [
        "uno":1, "dos":2, "tres":3, "cuatro":4
    ]

    private static let gradeWordsEN: [String:Int] = [
        "again":1, "wrong":1, "repeat":1, "fail":1, "failed":1, "miss":1, "missed":1, "red":1,
        "hard":2, "difficult":2, "struggled":2,
        "good":3, "ok":3, "okay":3, "okey":3, "decent":3, "solid":3, "correct":3,
        "easy":4, "trivial":4, "simple":4
    ]
    private static let gradeWordsES: [String:Int] = [
        "otra vez":1, "repetir":1, "mal":1, "fallar":1, "fallé":1, "errar":1, "equivocado":1,
        "difícil":2, "duro":2, "costó":2,
        "bien":3, "bueno":3, "ok":3, "okay":3, "decente":3, "correcto":3,
        "fácil":4, "trivial":4, "simple":4
    ]

    private static let gradeVerbsEN = [
        "grade", "mark", "set", "make", "give", "record", "submit"
    ]
    private static let gradeVerbsES = [
        "calificar", "marcar", "poner", "dar", "registrar", "enviar"
    ]

    private static let questionStartersEN = [
        "what","why","how","when","where","who","which",
        "explain","clarify","tell me","give me","compare","example","more about",
        "can you","could you","do you","would you","help me","walk me through","i don't understand","i dont understand","not clear"
    ]
    private static let questionStartersES = [
        "qué","que","por qué","porque","cómo","como","cuándo","cuando","dónde","donde","quién","quien","cuál","cual",
        "explicar","explica","aclarar","aclara","dime","dame","compara","ejemplo","más sobre","mas sobre",
        "puedes","podrías","me ayudas","no entiendo","no está claro","no esta claro"
    ]

    /// Parse with default English locale (for backward compatibility)
    static func parse(_ raw: String) -> UserIntent {
        parse(raw, localeIdentifier: "en-US")
    }

    static func parse(_ raw: String, localeIdentifier: String) -> UserIntent {
        let text = normalize(raw)
        let isSpanish = VoiceCommandPhrases.isSpanish(localeIdentifier)

        if let g = matchGrade(text, isSpanish: isSpanish) {
            return g
        }

        if looksLikeQuestion(text, isSpanish: isSpanish) {
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

    private static func matchGrade(_ t: String, isSpanish: Bool) -> UserIntent? {
        var isUnambiguous = false
        let gradeWords = isSpanish ? gradeWordsES : gradeWordsEN
        let gradeVerbs = isSpanish ? gradeVerbsES : gradeVerbsEN

        // 1) explicit numerals - always unambiguous ("grade 3", "mark 2")
        if let n = extractExplicitNumberCommand(t, gradeVerbs: gradeVerbs) {
            if let mapped = mapEase(n) {
                isUnambiguous = true
                return .grade(ease: mapped, canonical: VoiceCommandPhrases.canonicalName(ease: mapped, locale: isSpanish ? "es-ES" : "en-US"), unambiguous: isUnambiguous)
            }
        }

        // 2) words "one/two/three/four" or "uno/dos/tres/cuatro" - unambiguous when with verb
        if let n = extractWordNumberCommand(t, isSpanish: isSpanish) {
            if let mapped = mapEase(n) {
                let hasVerb = gradeVerbs.contains { t.contains($0) }
                isUnambiguous = hasVerb || t.split(separator: " ").count == 1
                return .grade(ease: mapped, canonical: VoiceCommandPhrases.canonicalName(ease: mapped, locale: isSpanish ? "es-ES" : "en-US"), unambiguous: isUnambiguous)
            }
        }

        // 3) bare grade words or "mark it X", "grade X", etc.
        if let e = extractWordGrade(t, gradeWords: gradeWords, gradeVerbs: gradeVerbs) {
            let canonical = VoiceCommandPhrases.canonicalName(ease: e, locale: isSpanish ? "es-ES" : "en-US")
            let tokens = t.split(separator: " ").map(String.init)
            let exactPatterns = isSpanish ? ["calificar \(canonical)", "marcar \(canonical)"] : ["grade \(canonical)", "mark \(canonical)"]
            let isExact = t == canonical || exactPatterns.contains(t)
            let hasVerb = gradeVerbs.contains { t.contains($0) && t.contains(canonical) }
            isUnambiguous = isExact || hasVerb || tokens.count <= 2

            // Ambiguous: "that was good", "pretty easy", "kind of hard" / "eso estuvo bien", "bastante fácil"
            if t.contains("was") || t.contains("pretty") || t.contains("kind of") || t.contains("sort of") ||
               t.contains("estuvo") || t.contains("bastante") || t.contains("un poco") {
                isUnambiguous = false
            }

            return .grade(ease: e, canonical: canonical, unambiguous: isUnambiguous)
        }

        return nil
    }

    private static func extractExplicitNumberCommand(_ t: String, gradeVerbs: [String]) -> Int? {
        let tokens = t.split(separator: " ").map(String.init)

        if tokens.count == 1, let d = Int(tokens[0]), (1...4).contains(d) {
            return d
        }

        for v in gradeVerbs {
            if t.contains(v + " ") {
                if let d = extractTrailingDigit(t) { return d }
            }
        }

        if let d = matchRegex(t, pattern: #"(?:give|mark|set|make|grade|calificar|marcar|dar|poner)[^\d]*(\d)"#) {
            if let n = Int(d), (1...4).contains(n) { return n }
        }

        return nil
    }

    private static func extractWordNumberCommand(_ t: String, isSpanish: Bool) -> Int? {
        let numberWords = isSpanish ? numberWordsES : numberWordsEN
        let gradeVerbs = isSpanish ? gradeVerbsES : gradeVerbsEN
        let tokens = t.split(separator: " ").map(String.init)

        if tokens.count == 1, let n = numberWords[tokens[0]] {
            return n
        }
        for (w, n) in numberWords {
            if t.contains(" \(w)") || t.hasPrefix(w) {
                for v in gradeVerbs {
                    if t.contains(v) { return n }
                }
            }
        }
        return nil
    }

    private static func extractWordGrade(_ t: String, gradeWords: [String: Int], gradeVerbs: [String]) -> Int? {
        var foundEase: Int?

        for (w, e) in gradeWords {
            if t == w || t.hasPrefix(w + " ") || t.contains(" " + w + " ") || t.hasSuffix(" " + w) {
                foundEase = e
                break
            }
        }
        if foundEase == nil {
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

    private static func looksLikeQuestion(_ t: String, isSpanish: Bool) -> Bool {
        if t.contains("?") { return true }
        let questionStarters = isSpanish ? questionStartersES : questionStartersEN
        for q in questionStarters {
            if t == q { return true }
            if t.hasPrefix(q + " ") { return true }
        }
        if isSpanish {
            if t.contains("explicar") || t.contains("explica") || t.contains("no entiendo") ||
               t.contains("no está claro") || t.contains("qué significa") || t.contains("más sobre") {
                return true
            }
        } else {
            if t.contains("explain") || t.contains("don't understand") || t.contains("dont understand") ||
               t.contains("not clear") || t.contains("what does") || t.contains("more about") {
                return true
            }
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
}

