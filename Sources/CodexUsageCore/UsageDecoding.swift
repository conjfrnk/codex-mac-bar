import Foundation

public enum UsageDecoding {
    public static let decoder: JSONDecoder = JSONDecoder()

    public static func decodeUsageResult(from result: Any) throws -> AccountTokenUsageResponse {
        try decode(AccountTokenUsageResponse.self, from: result)
    }

    public static func decodeRateLimitsResult(from result: Any) throws -> AccountRateLimitsResponse {
        try decode(AccountRateLimitsResponse.self, from: result)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from result: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        return try decoder.decode(type, from: data)
    }
}
