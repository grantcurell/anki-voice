//
//  VoiceCommands.swift
//  AnkiVoice
//
//  Language-aware voice command phrases and TTS prompts for speech recognition.
//  Used when input language is Spanish to recognize Spanish commands.
//

import Foundation

/// Provides voice command phrases and TTS prompts in the user's input language.
enum VoiceCommandPhrases {
    
    static func isSpanish(_ localeIdentifier: String) -> Bool {
        localeIdentifier.hasPrefix("es")
    }
    
    // MARK: - Command phrase sets (for matching user speech)
    
    static func rereadQuestionPhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["repetir pregunta", "repetir la pregunta", "di la pregunta otra vez", "lee la pregunta otra vez",
                    "otra vez la pregunta", "repite la pregunta", "repíteme la pregunta"]
        }
        return ["reread question", "reread the question", "say the question again", "read question again",
                "repeat question", "repeat the question"]
    }
    
    static func rereadAnswerPhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["repetir respuesta", "repetir la respuesta", "di la respuesta otra vez", "lee la respuesta otra vez",
                    "otra vez la respuesta", "repite la respuesta"]
        }
        return ["reread answer", "reread the answer", "say the answer again", "read answer again"]
    }
    
    static func readAnswerPhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["lee la respuesta", "muéstrame la respuesta", "dime la respuesta",
                    "mostrar respuesta", "enséñame la respuesta"]
        }
        return ["read answer", "read the answer", "show answer", "tell me the answer"]
    }
    
    static func deleteNotePhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["eliminar nota", "eliminar la nota", "borrar nota", "borrar la nota", "eliminar esta nota",
                    "eliminar tarjeta", "eliminar la tarjeta", "borrar tarjeta", "borrar la tarjeta"]
        }
        return ["delete note", "delete the note", "remove note", "remove the note", "delete this note",
                "delete card", "delete the card"]
    }
    
    static func skipLLMPhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["no sé", "no tengo idea", "no estoy seguro", "no idea", "ni idea", "ni siquiera sé",
                    "no lo sé", "no lo se", "no tengo ni idea"]
        }
        return ["i don't know", "i have no idea", "i'm not sure", "no idea", "don't know", "i dunno"]
    }
    
    static func undoPhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["deshacer", "cambiar", "retroceder", "deshacer eso", "cambiar eso", "atrás", "volver"]
        }
        return ["undo", "change", "take back", "undo that", "change that"]
    }
    
    static func examplePhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["dame un ejemplo", "dame un ejemplo de uso", "muéstrame un ejemplo", "ejemplo de uso",
                    "ejemplo", "un ejemplo", "necesito un ejemplo"]
        }
        return ["give me an example", "give me an example usage", "show me an example", "example usage", "example"]
    }
    
    /// Phrases that confirm an action (e.g., "confirm", "yes")
    static func confirmPhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["confirmar", "sí", "si", "hazlo", "adelante", "de acuerdo", "vale", "ok", "okay"]
        }
        return ["confirm", "yes", "do it", "that's fine", "okay", "ok"]
    }
    
    /// Phrases that cancel an action
    static func cancelPhrases(locale: String) -> [String] {
        if isSpanish(locale) {
            return ["no", "cancelar", "espera", "espera un momento", "cambiar", "para"]
        }
        return ["no", "cancel", "wait", "hold on", "change"]
    }
    
    // MARK: - TTS prompts (spoken feedback to user)
    
    static func undoPrompt(locale: String) -> String {
        if isSpanish(locale) {
            return "Di 'deshacer' para cambiarlo."
        }
        return "Say 'undo' to change it."
    }
    
    static func deleteConfirmPrompt(locale: String) -> String {
        if isSpanish(locale) {
            return "¿Eliminar esta nota? Di confirmar para eliminar, o di cancelar."
        }
        return "Delete this note? Say confirm to delete, or say cancel."
    }
    
    static func gradeConfirmPrompt(canonical: String, locale: String) -> String {
        if isSpanish(locale) {
            return "¿\(canonical)? Di confirmar para continuar, o di otra calificación."
        }
        return "\(canonical)? Say confirm to proceed, or say a different grade."
    }
    
    static func didntGetThatPrompt(locale: String) -> String {
        if isSpanish(locale) {
            return "No entendí. Di una calificación como 'bien' o haz una pregunta."
        }
        return "I didn't get that. Say a grade like 'grade good' or ask a question."
    }
    
    static func cancelledPrompt(locale: String) -> String {
        if isSpanish(locale) {
            return "De acuerdo. Cancelado."
        }
        return "Okay. Cancelled."
    }

    static func sayGradeOrQuestionPrompt(locale: String) -> String {
        if isSpanish(locale) {
            return "De acuerdo. Di una calificación o haz una pregunta."
        }
        return "Okay. Say a grade or ask a question."
    }
    
    static func noteDeletedPrompt(locale: String) -> String {
        if isSpanish(locale) {
            return "Nota eliminada."
        }
        return "Note deleted."
    }
    
    static func markedPrompt(canonical: String, locale: String) -> String {
        if isSpanish(locale) {
            return "Marcado \(canonical). \(undoPrompt(locale: locale))"
        }
        return "Marked \(canonical). \(undoPrompt(locale: locale))"
    }
    
    /// Grade name for TTS (e.g., "good", "bien")
    static func canonicalName(ease: Int, locale: String) -> String {
        if isSpanish(locale) {
            switch ease {
            case 1: return "otra vez"
            case 2: return "difícil"
            case 3: return "bien"
            default: return "fácil"
            }
        }
        switch ease {
        case 1: return "again"
        case 2: return "hard"
        case 3: return "good"
        default: return "easy"
        }
    }
}
