import Foundation

/// Keeps subprocess diagnostics useful without retaining unbounded output or
/// exposing common credential forms in user-facing errors.
final class BoundedDataCapture: @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ incoming: Data) {
        lock.withLock {
            let remaining = max(0, maxBytes - data.count)
            if remaining > 0 {
                data.append(incoming.prefix(remaining))
            }
            if incoming.count > remaining {
                truncated = true
            }
        }
    }

    var diagnostic: String? {
        lock.withLock {
            guard !data.isEmpty else { return nil }
            let suffix = truncated ? " [truncated]" : ""
            let message = DiagnosticSanitizer.clean(String(decoding: data, as: UTF8.self))
            guard !message.isEmpty else { return truncated ? "[truncated]" : nil }
            return message + suffix
        }
    }
}

public enum DiagnosticSanitizer {
    private static let replacement = "[REDACTED]"

    public static func clean(
        _ input: String,
        maxCharacters: Int = 512,
        maxUTF8Bytes: Int = 2 * 1024
    ) -> String {
        let characterLimit = max(0, maxCharacters)
        let byteLimit = max(0, maxUTF8Bytes)
        guard characterLimit > 0, byteLimit > 0 else { return "" }

        // Credential redaction runs before presentation truncation. The working
        // prefix is still bounded so a hostile diagnostic cannot force unbounded
        // regular-expression work; anything capable of reaching the output is
        // comfortably inside this prefix.
        let scaledWorkingLimit = characterLimit.multipliedReportingOverflow(by: 8)
        let workingLimit = max(
            4_096,
            scaledWorkingLimit.overflow ? Int.max : scaledWorkingLimit.partialValue
        )
        let canonical = canonicalizeForRedaction(String(input.prefix(workingLimit)))
        let redacted = redactCredentials(in: canonical)

        var sanitized = ""
        sanitized.reserveCapacity(min(redacted.utf8.count, byteLimit))
        var utf8Bytes = 0
        var previousWasSpace = false

        for scalar in redacted.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || scalar.isUnsafeFormatCharacter
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let scalarToAppend: Unicode.Scalar?
            if isControl || isWhitespace {
                if !previousWasSpace && !sanitized.isEmpty {
                    scalarToAppend = " "
                } else {
                    scalarToAppend = nil
                }
                previousWasSpace = true
            } else {
                scalarToAppend = scalar
                previousWasSpace = false
            }

            guard let scalarToAppend else { continue }
            let scalarBytes = scalarToAppend.utf8ByteCount
            if scalarBytes > byteLimit - utf8Bytes {
                break
            }
            sanitized.unicodeScalars.append(scalarToAppend)
            utf8Bytes += scalarBytes
        }

        let presentationBounded = String(sanitized.prefix(characterLimit))
        return presentationBounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func redactCredentials(in input: String) -> String {
        // User-facing diagnostics do not need to preserve text surrounding a
        // credential. Redacting the complete bounded diagnostic once any marker
        // is present is intentionally conservative: it also covers unterminated
        // quotes and URL authorities whose closing `@` lies beyond our bounded
        // inspection prefix.
        let indicatorPatterns = [
            // A colon inside a URL authority may be user-info. This also hides
            // some harmless host:port diagnostics, which is the safer tradeoff.
            #"(?i)\b[a-z][a-z0-9+.-]*://[^/\s?#]*:"#,
            // Authorization and proxy-authorization assignments, including JSON.
            #"(?i)\b(?:proxy[-_]?authorization|authorization)[\"']?\s*[:=]"#,
            // Named secrets in snake, kebab, camel, JSON, query, and env forms.
            #"(?i)\b(?:openai[_-]?api[_-]?key|api[_-]?key|x[_-]?api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd|secret|token)[\"']?\s*[:=]"#,
            // Common standalone API-token shapes and JSON web tokens.
            #"(?i)\b(?:sk-(?:proj-)?[a-z0-9_-]{8,}|gh[pousr]_[a-z0-9]{8,}|github_pat_[a-z0-9_]{8,}|xox[baprs]-[a-z0-9-]{8,}|akia[a-z0-9]{16})\b"#,
            #"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b"#
        ]

        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        for pattern in indicatorPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            if expression.firstMatch(in: input, range: range) != nil {
                return replacement
            }
        }
        return input
    }

    /// Remove non-rendering format controls before matching credentials so an
    /// attacker cannot split a key or token shape and have presentation later
    /// join it back together. Whitespace remains a separator.
    private static func canonicalizeForRedaction(_ input: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(input.unicodeScalars.count)
        for scalar in input.unicodeScalars {
            if CharacterSet.illegalCharacters.contains(scalar)
                || scalar.isUnsafeFormatCharacter {
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    output.append(" ")
                }
                continue
            }
            output.append(scalar)
        }
        return String(output)
    }

}

/// Format controls and default-ignorable scalars must not split a credential
/// key during matching or make an otherwise empty presentation value look real.
/// The ranges deliberately include unassigned default-ignorable code points so
/// behavior remains conservative as Unicode evolves.
extension Unicode.Scalar {
    var isUnsafeFormatCharacter: Bool {
        if (0xfdd0 ... 0xfdef).contains(value)
            || (value & 0xffff) >= 0xfffe {
            return true
        }
        return switch value {
        case 0x00ad,
             0x034f,
             0x0600 ... 0x0605,
             0x061c,
             0x06dd,
             0x070f,
             0x0890 ... 0x0891,
             0x08e2,
             0x115f ... 0x1160,
             0x17b4 ... 0x17b5,
             0x180b ... 0x180f,
             0x200b ... 0x200f,
             0x202a ... 0x202e,
             0x2060 ... 0x206f,
             0x3164,
             0xfe00 ... 0xfe0f,
             0xfeff,
             0xffa0,
             0xfff0 ... 0xfffb,
             0x110bd,
             0x110cd,
             0x13430 ... 0x13455,
             0x1bca0 ... 0x1bca3,
             0x1d173 ... 0x1d17a,
             0xe0000 ... 0xe0fff:
            true
        default:
            false
        }
    }
}

private extension Unicode.Scalar {
    var utf8ByteCount: Int {
        switch value {
        case 0 ... 0x7f: 1
        case 0x80 ... 0x7ff: 2
        case 0x800 ... 0xffff: 3
        default: 4
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
