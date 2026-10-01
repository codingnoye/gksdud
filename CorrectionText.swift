import AppKit

// Bounded keyboard-layout conversion primitives; no automatic word detection.
enum CorrectionLanguage { case english, korean }

enum HangulKeys {
    static let initials = ["r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
    static let vowels = ["k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
    static let finals = ["", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "qt", "t", "T", "d", "w", "c", "z", "x", "v", "g"]
    static let consonants = ["r", "R", "rt", "s", "sw", "sg", "e", "E", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "Q", "qt", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
    static func encode(_ text: String) -> String? {
        guard !text.isEmpty, text.utf16.count <= 64 else { return nil }
        var result = ""
        for scalar in text.unicodeScalars {
            let value = Int(scalar.value)
            switch value {
            case 0xAC00...0xD7A3:
                let index = value - 0xAC00
                result += initials[index / 588] + vowels[index % 588 / 28] + finals[index % 28]
            case 0x3131...0x314E: result += consonants[value - 0x3131]
            case 0x314F...0x3163: result += vowels[value - 0x314F]
            default: return nil
            }
        }
        return result
    }
}

struct CorrectionContext: Equatable {
    let pid: pid_t
    let sourceID: String
    var language: CorrectionLanguage? {
        if ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(sourceID) { return .english }
        if sourceID == "com.apple.inputmethod.Korean.2SetKorean" { return .korean }
        return nil
    }
}

struct CorrectionSnapshot: Equatable {
    let tail: String // At most 96 UTF-16 units before the insertion point.
    let caret: Int
}

protocol CorrectionEditor: AnyObject {
    var providesTextReadback: Bool { get }
    func snapshot() -> CorrectionSnapshot?
    // Replace only this suffix of a freshly revalidated snapshot. Never set AXValue.
    func replace(_ snapshot: CorrectionSnapshot, suffix: String, with replacement: String) -> CorrectionSnapshot?
    func replace(_ snapshot: CorrectionSnapshot, suffix: String, with replacement: String,
                 valid: @escaping () -> Bool, completion: @escaping (CorrectionSnapshot?) -> Void)
}

extension CorrectionEditor {
    var providesTextReadback: Bool { true }
    func replace(_ snapshot: CorrectionSnapshot, suffix: String, with replacement: String,
                 valid: @escaping () -> Bool, completion: @escaping (CorrectionSnapshot?) -> Void) {
        guard valid() else { completion(nil); return }
        completion(replace(snapshot, suffix: suffix, with: replacement))
    }
}
