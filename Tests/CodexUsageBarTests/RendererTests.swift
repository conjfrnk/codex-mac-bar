import Foundation
import CodexUsageCore
import Testing
@testable import CodexUsageBar

@MainActor
@Suite
struct RendererTests {
    @Test
    func testParserReturnsNilWithoutRenderCommand() throws {
        #expect(try UsagePopoverRenderer.parse(arguments: ["app"]) == nil)
    }

    @Test
    func testParserUsesDeterministicDefaults() throws {
        let options = try #require(try UsagePopoverRenderer.parse(arguments: [
            "app", "--render-popover", "/tmp/popover.png"
        ]))
        #expect(
            options == PopoverRenderOptions(
                outputPath: "/tmp/popover.png",
                appearance: .light,
                timeframe: .thirty,
                fixture: .success,
                textSize: .standard,
                width: 300,
                height: 560
            )
        )
    }

    @Test
    func testParserConsumesEveryExplicitOption() throws {
        let options = try #require(try UsagePopoverRenderer.parse(arguments: [
            "app",
            "--height", "1400",
            "--timeframe", "all",
            "--render-popover", "/tmp/popover.png",
            "--width", "260",
            "--fixture", "login-approval",
            "--text-size", "accessibility",
            "--appearance", "dark"
        ]))
        #expect(options.appearance == .dark)
        #expect(options.timeframe == .all)
        #expect(options.fixture == .loginApproval)
        #expect(options.textSize == .accessibility)
        #expect(options.width == 260)
        #expect(options.height == 1_400)
    }

    @Test
    func testParserRejectsMissingAndFlagShapedOperands() {
        for arguments in [
            ["app", "--render-popover"],
            ["app", "--render-popover", "--appearance", "dark"],
            ["app", "--render-popover", "/tmp/a.png", "--appearance"],
            ["app", "--render-popover", "/tmp/a.png", "--width", "--height", "300"]
        ] {
            #expect(throws: (any Error).self, "\(arguments)") {
                try UsagePopoverRenderer.parse(arguments: arguments)
            }
        }
    }

    @Test
    func testParserRejectsUnknownDuplicateAndInvalidValues() {
        for tail in [
            ["--wat", "value"],
            ["--appearance", "light", "--appearance", "dark"],
            ["--appearance", "sepia"],
            ["--timeframe", "year"],
            ["--fixture", "unknown"],
            ["--text-size", "huge"],
            ["--text-size", "standard", "--text-size", "accessibility"],
            ["--width", "260.5"],
            ["--width", "219"],
            ["--width", "259"],
            ["--height", "559"],
            ["--height", "2001"]
        ] {
            #expect(throws: (any Error).self, "\(tail)") {
                try UsagePopoverRenderer.parse(
                    arguments: ["app", "--render-popover", "/tmp/a.png"] + tail
                )
            }
        }
    }

    @Test
    func testParserAcceptsEveryVisualFixture() throws {
        for fixture in PopoverRenderOptions.Fixture.allCases {
            let options = try #require(try UsagePopoverRenderer.parse(arguments: [
                "app", "--render-popover", "/tmp/a.png", "--fixture", fixture.rawValue
            ]))
            #expect(options.fixture == fixture)
        }
    }

    @Test
    func testParserAcceptsEveryLandmarkValidationHeightBoundary() throws {
        for height in [560, 999, 1_000, 1_200, 2_000] {
            let options = try #require(try UsagePopoverRenderer.parse(arguments: [
                "app", "--render-popover", "/tmp/a.png", "--height", String(height)
            ]))
            #expect(options.height == height)
        }
    }

    @Test
    func testAccessibilityTextRenderKeepsLiveHeightFooterVisible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-large-text-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("popover.png")

        #expect(try UsagePopoverRenderer.runIfRequested(arguments: [
            "app",
            "--render-popover", output.path,
            "--fixture", "success",
            "--text-size", "accessibility",
            "--width", "300",
            "--height", "560"
        ]))

        let data = try Data(contentsOf: output)
        #expect(data.count > 10_000)
    }
}
