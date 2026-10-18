import Foundation

enum ExpectationFailure: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw ExpectationFailure.failed(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw ExpectationFailure.failed("\(message) (expected \(expected), got \(actual))")
    }
}

func expectNil<T>(_ value: T?, _ message: String) throws {
    if value != nil {
        throw ExpectationFailure.failed(message)
    }
}

func expectNotNil<T>(_ value: T?, _ message: String) throws {
    if value == nil {
        throw ExpectationFailure.failed(message)
    }
}

final class TestSuite {
    let name: String
    private var tests: [(name: String, body: () throws -> Void)] = []

    init(name: String) {
        self.name = name
    }

    func test(_ name: String, body: @escaping () throws -> Void) {
        tests.append((name: name, body: body))
    }

    func run() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0
        for item in tests {
            do {
                try item.body()
                passed += 1
            } catch {
                failed += 1
                fputs("FAIL \(name).\(item.name): \(error.localizedDescription)\n", stderr)
            }
        }
        let mark = failed == 0 ? "ok" : "FAILED"
        fputs("  \(name)  \(passed) passed, \(failed) failed  \(mark)\n", stdout)
        return (passed, failed)
    }
}

@main
struct LumosTests {
    static func main() {
        let suites = [
            queryParserSuite(),
            formatterSuite(),
            privacySuite(),
            indexDataSuite(),
            searchSuite(),
            trigramSuite(),
            scannerSuite(),
            snapshotSuite(),
            querySuite(),
            mcpSuite(),
            specialCharacterSuite()
        ]
        var passed = 0
        var failed = 0
        fputs("Lumos unit tests\n", stdout)
        for suite in suites {
            let result = suite.run()
            passed += result.passed
            failed += result.failed
        }
        fputs("\(passed) passed, \(failed) failed\n", stdout)
        if failed == 0 {
            exit(0)
        }
        exit(1)
    }
}
