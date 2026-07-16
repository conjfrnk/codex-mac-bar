import Foundation
import Testing
@testable import CodexUsageCore

extension DataAndChartTests {
    @Test
    func testAppServerDevelopmentVersionDoesNotDuplicateReleaseMetadata() {
        #expect(CodexAppServerClient.appServerClientVersion(bundleVersion: nil) == "development")
        #expect(CodexAppServerClient.appServerClientVersion(bundleVersion: "  ") == "development")
        #expect(CodexAppServerClient.appServerClientVersion(bundleVersion: "2.3.4") == "2.3.4")
    }

    @Test
    func testSharedRateLimitContractCorpus() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Protocol/rate-limit-contracts.json")
        let data = try Data(contentsOf: fixtureURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect((root["schemaVersion"] as? NSNumber)?.intValue == 1)
        let cases = try #require(root["rateLimitCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)

        for fixture in cases {
            let name = try #require(fixture["name"] as? String)
            let source = try #require(fixture["source"] as? [String: Any])
            let sourceKind = try #require(source["kind"] as? String)
            let sourceValue = try #require(source["value"])
            let expected = try #require(fixture["expected"] as? [String: Any])

            let response: AccountRateLimitsResponse
            switch sourceKind {
            case "result":
                do {
                    response = try UsageDecoding.decodeRateLimitsResult(from: sourceValue)
                } catch {
                    response = .malformedOuterResponse()
                }
            case "jsonRpcError":
                response = .failedOptionalRequest()
            default:
                Issue.record("Unknown shared fixture source kind \(sourceKind) in \(name)")
                continue
            }

            let selected = response.preferredCodexLimit
            #expect(selected?.limitId == expected["selectedLimitId"] as? String, "\(name)")
            #expect(
                response.hasMeaningfulData == (expected["hasMeaningfulData"] as? NSNumber)?.boolValue,
                "\(name)"
            )
            #expect(
                selected?.primary?.usedPercent == (expected["primaryUsedPercent"] as? NSNumber)?.doubleValue,
                "\(name)"
            )
            #expect(
                selected?.primary?.windowDurationMins
                    == (expected["primaryWindowDurationMins"] as? NSNumber)?.intValue,
                "\(name)"
            )
            #expect(
                selected?.individualLimit?.usedPercent
                    == (expected["individualUsedPercent"] as? NSNumber)?.doubleValue,
                "\(name)"
            )
            #expect(selected?.planType == expected["planType"] as? String, "\(name)")
            #expect(
                response.rateLimitResetCredits?.availableCount
                    == (expected["resetCreditCount"] as? NSNumber)?.int64Value,
                "\(name)"
            )

            let warningPaths = response.decodingIssues.map {
                String($0.split(separator: ":", maxSplits: 1)[0])
            }
            #expect(warningPaths == expected["warningPaths"] as? [String], "\(name)")
            if let exactWarnings = expected["exactWarnings"] as? [String] {
                #expect(response.decodingIssues == exactWarnings, "\(name)")
            }
        }
    }
}
