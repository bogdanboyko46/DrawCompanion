import XCTest
@testable import DrawCore

final class PhraseEndpointerTests: XCTestCase {
    func testNothingHeardNeverEnds() {
        let p = PhraseEndpointer()
        XCTAssertNil(p.deadline)
        XCTAssertFalse(p.isFinished(at: 100))
    }

    func testCompletePhraseEndsAfterBasePause() {
        var p = PhraseEndpointer()
        p.update("Add a cat", at: 0)
        p.update("Add a cat on the windowsill.", at: 0.8)
        XCTAssertFalse(p.isFinished(at: 1.7))
        XCTAssertTrue(p.isFinished(at: 1.8))
        XCTAssertEqual(p.finish(), "Add a cat on the windowsill.")
        XCTAssertNil(p.deadline) // reset for the next phrase
    }

    func testTrailingWordWaitsLonger() {
        var p = PhraseEndpointer()
        p.update("maybe a cat on the", at: 0)
        XCTAssertFalse(p.isFinished(at: 1.5))
        XCTAssertTrue(p.isFinished(at: 2.0))
    }

    func testNewWordsRestartThePause() {
        var p = PhraseEndpointer()
        p.update("I'm stuck", at: 0)
        p.update("I'm stuck maybe a dog", at: 0.9)
        XCTAssertFalse(p.isFinished(at: 1.5))
        XCTAssertTrue(p.isFinished(at: 1.9))
        XCTAssertEqual(p.longestGap, 0.9, accuracy: 1e-9)
    }

    func testSameTranscriptDoesNotRestart() {
        var p = PhraseEndpointer()
        p.update("bigger", at: 0)
        p.update("bigger", at: 0.9)
        XCTAssertTrue(p.isFinished(at: 1.0))
    }

    func testLongSpeechIsCutBeforeTheRecognizerLimit() {
        var p = PhraseEndpointer()
        var t = 0.0
        while t < 45 { p.update("word \(Int(t))", at: t); t += 0.5 }
        XCTAssertTrue(p.isFinished(at: 40))
    }

    func testFillerOnlyIsDropped() {
        var p = PhraseEndpointer()
        p.update("Um.", at: 0)
        XCTAssertTrue(PhraseEndpointer.soundsUnfinished("Um."))
        XCTAssertNil(p.finish())
        XCTAssertNil(PhraseEndpointer.cleaned("  uh, hmm  "))
        XCTAssertEqual(PhraseEndpointer.cleaned(" um, a tree "), "um, a tree")
    }

    func testUnfinishedRules() {
        XCTAssertTrue(PhraseEndpointer.soundsUnfinished("put a flower next to the"))
        XCTAssertTrue(PhraseEndpointer.soundsUnfinished("a house,"))
        XCTAssertTrue(PhraseEndpointer.soundsUnfinished("Can you draw a."))
        XCTAssertFalse(PhraseEndpointer.soundsUnfinished("Clear it."))
        XCTAssertFalse(PhraseEndpointer.soundsUnfinished("bigger"))
        XCTAssertFalse(PhraseEndpointer.soundsUnfinished("a pine tree?"))
    }
}
