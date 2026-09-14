import XCTest
@testable import LiveCaptions

final class LiveCaptionsTests: XCTestCase {
    func testSentenceCut() {
        let s = "Hello there. How are you doing"
        let cut = Captioner.sentenceCut(in: s)!
        XCTAssertEqual(String(s[..<cut]).trimmingCharacters(in: .whitespaces), "Hello there.")
        XCTAssertNil(Captioner.sentenceCut(in: "No terminator yet"))
        XCTAssertNil(Captioner.sentenceCut(in: "Dr. Who"))
        let two = "One. Two! Three?"
        XCTAssertEqual(Captioner.sentenceCut(in: two), two.endIndex)
    }
}
