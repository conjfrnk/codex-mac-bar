import CoreFoundation
import Foundation

public enum UsageDecoding {
    /// Source-compatible value decoder access. Foundation's generic decoder
    /// cannot expose raw number-token provenance after it rounds a value; use
    /// `decodeUsageData(_:)` for strict server-payload decoding.
    /// A fresh instance prevents callers from mutating shared process-wide state.
    public static var decoder: JSONDecoder { JSONDecoder() }

    /// Strictly decodes a raw usage payload while its integer-versus-floating
    /// JSON number provenance is still observable.
    public static func decodeUsageData(_ data: Data) throws -> AccountTokenUsageResponse {
        try decodeUsageResult(from: jsonObject(from: data))
    }

    /// Strictly decodes a raw rate-limit payload, preserving lossy field-quality
    /// reporting for integer fields whose JSON representation is invalid.
    public static func decodeRateLimitsData(_ data: Data) throws -> AccountRateLimitsResponse {
        try decodeRateLimitsResult(from: jsonObject(from: data))
    }

    public static func decodeUsageResult(from result: Any) throws -> AccountTokenUsageResponse {
        try validateContainerGraph(result)
        try validateUsageIntegerRepresentations(result)
        return try decodePrevalidated(AccountTokenUsageResponse.self, from: result)
    }

    public static func decodeRateLimitsResult(from result: Any) throws -> AccountRateLimitsResponse {
        try validateContainerGraph(result)
        return try decodePrevalidated(
            AccountRateLimitsResponse.self,
            from: sanitizingRateIntegerRepresentations(result)
        )
    }

    public static func decode<T: Decodable>(_ type: T.Type, from result: Any) throws -> T {
        try validateContainerGraph(result)
        return try decodePrevalidated(type, from: result)
    }

    private static func decodePrevalidated<T: Decodable>(_ type: T.Type, from result: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }

    private static func jsonObject(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Darwin Foundation traps rather than throwing for cyclic containers and
    /// several invalid scalar objects. Wrapping the value makes the validator
    /// cover scalar fragments too without rejecting valid String/number/bool/null
    /// fragments that the serializer below intentionally supports.
    private static func validateContainerGraph(_ result: Any) throws {
        guard JSONSerialization.isValidJSONObject([result]) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Expected an acyclic JSON-compatible object graph."
                )
            )
        }
    }

    /// JSONSerialization exposes whether a parsed number came from an integer or
    /// floating-point JSON token. Preserve that provenance for required usage
    /// counts before reserializing the Any graph, because reserialization could
    /// otherwise turn a rounded fractional Double into an apparently valid Int64.
    private static func validateUsageIntegerRepresentations(_ result: Any) throws {
        guard let object = result as? [String: Any] else { return }

        if let summary = object["summary"] as? [String: Any] {
            for key in [
                "lifetimeTokens", "peakDailyTokens", "longestRunningTurnSec",
                "currentStreakDays", "longestStreakDays"
            ] {
                if let value = summary[key], !(value is NSNull) {
                    try validateRawInteger(value, path: "summary.\(key)")
                }
            }
        }

        if let buckets = object["dailyUsageBuckets"] as? [Any] {
            for (index, value) in buckets.enumerated() {
                guard let bucket = value as? [String: Any],
                      let tokens = bucket["tokens"],
                      !(tokens is NSNull) else { continue }
                try validateRawInteger(tokens, path: "dailyUsageBuckets[\(index)].tokens")
            }
        }
    }

    private static func validateRawInteger(_ value: Any, path: String) throws {
        guard let number = value as? NSNumber else { return }
        guard CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Expected an integer JSON value at \(path)."
                )
            )
        }
    }

    /// Optional rate-limit fields decode lossily so one malformed field does not
    /// discard valid siblings. Replace float-typed integer fields with a JSON
    /// value that their model decoder will reject, preserving that lossy behavior
    /// without allowing Any -> JSON reserialization to erase a fractional token.
    private static func sanitizingRateIntegerRepresentations(_ result: Any) -> Any {
        guard var object = result as? [String: Any] else { return result }

        if let snapshot = object["rateLimits"] {
            object["rateLimits"] = sanitizingRateSnapshot(snapshot)
        }
        if let rawLimits = object["rateLimitsByLimitId"] as? [String: Any] {
            object["rateLimitsByLimitId"] = rawLimits.mapValues(sanitizingRateSnapshot)
        }
        if var resetCredits = object["rateLimitResetCredits"] as? [String: Any] {
            sanitizeIntegerField("availableCount", in: &resetCredits)
            object["rateLimitResetCredits"] = resetCredits
        }
        return object
    }

    private static func sanitizingRateSnapshot(_ value: Any) -> Any {
        guard var snapshot = value as? [String: Any] else { return value }
        for key in ["primary", "secondary"] {
            guard var window = snapshot[key] as? [String: Any] else { continue }
            sanitizeIntegerField("windowDurationMins", in: &window)
            snapshot[key] = window
        }
        if var individual = snapshot["individualLimit"] as? [String: Any] {
            sanitizeIntegerField("remainingPercent", in: &individual)
            snapshot["individualLimit"] = individual
        }
        return snapshot
    }

    private static func sanitizeIntegerField(_ key: String, in object: inout [String: Any]) {
        guard let value = object[key], let number = value as? NSNumber else { return }
        if CFGetTypeID(number) == CFBooleanGetTypeID() || CFNumberIsFloatType(number) {
            object[key] = ["invalidIntegerRepresentation": true]
        }
    }
}
