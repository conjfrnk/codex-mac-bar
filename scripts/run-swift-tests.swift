import Darwin
import Testing

/// The standalone Apple CLT SwiftPM helper currently loads this package's test
/// bundle but discovers zero Swift Testing tests. Loading the bundle first and
/// invoking Testing's SwiftPM entry point from a tiny executable restores dynamic
/// discovery. Makefile verifies the exact declared @Test count and all four suite
/// pass sentinels, so a future partial/silent discovery regression cannot pass.
@main
struct CodexSwiftTestingRunner {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: run-swift-tests TEST_BUNDLE_BINARY\n", stderr)
            exit(64)
        }

        let bundleBinary = CommandLine.arguments[1]
        guard dlopen(bundleBinary, RTLD_NOW | RTLD_GLOBAL) != nil else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            fputs("could not load test bundle: \(message)\n", stderr)
            exit(1)
        }

        var arguments = __CommandLineArguments_v0()
        arguments.verbosity = 1
        let result: CInt = await __swiftPMEntryPoint(passing: arguments)
        exit(result)
    }
}
