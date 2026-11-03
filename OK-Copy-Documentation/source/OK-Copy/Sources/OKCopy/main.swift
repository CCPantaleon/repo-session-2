import Foundation
import IngestCore
import Darwin

if CommandLine.arguments.contains("--self-test") {
    do {
        let result = try SafetyCheck.run()
        print("OK, Copy safety check: \(result.checks.count) passed")
        for check in result.checks { print("PASS  \(check)") }
        exit(0)
    } catch {
        fputs("Safety check failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    OKCopyApp.main()
}
