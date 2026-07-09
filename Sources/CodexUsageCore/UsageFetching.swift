import Foundation

public protocol UsageFetching: Sendable {
    func fetchUsageSnapshot() async throws -> UsageSnapshot
}
