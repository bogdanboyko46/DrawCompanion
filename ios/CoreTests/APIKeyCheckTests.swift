import XCTest
@testable import DrawCore

final class APIKeyCheckTests: XCTestCase {
    let good = "sk-ant-api03-" + String(repeating: "x", count: 80)

    func testNormalizesPastedKeys() {
        XCTAssertEqual(APIKeyCheck.normalized("  \"\(good)\"\n"), good)
        XCTAssertEqual(APIKeyCheck.normalized("“\(good)”"), good)
    }

    func testFormat() {
        XCTAssertNil(APIKeyCheck.formatProblem(good))
        XCTAssertNotNil(APIKeyCheck.formatProblem(""))
        XCTAssertNotNil(APIKeyCheck.formatProblem("sk-proj-abc"))
        XCTAssertNotNil(APIKeyCheck.formatProblem("sk-ant-short"))
    }

    func testRequestIsTheFreeModelsList() {
        let req = APIKeyCheck.request(key: good)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), good)
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testInterpretsAnswers() {
        XCTAssertEqual(APIKeyCheck.interpret(status: 200), .valid)
        XCTAssertEqual(APIKeyCheck.interpret(status: 401), .rejected)
        XCTAssertEqual(APIKeyCheck.interpret(status: 403), .rejected)
        if case .problem = APIKeyCheck.interpret(status: 529) {} else { XCTFail() }
        XCTAssertEqual(APIKeyCheck.interpret(error: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(APIKeyCheck.interpret(error: URLError(.timedOut)), .offline)
    }
}
