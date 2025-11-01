import XCTest
@testable import AnkiVoice

final class IntentParserTests: XCTestCase {
    
    func testGrades() {
        XCTAssertEqual(grade("again"), 1)
        XCTAssertEqual(grade("mark it hard"), 2)
        XCTAssertEqual(grade("grade 3"), 3)
        XCTAssertEqual(grade("give it a four"), 4)
        XCTAssertEqual(grade("wrong"), 1)
        XCTAssertEqual(grade("difficult"), 2)
        XCTAssertEqual(grade("good"), 3)
        XCTAssertEqual(grade("easy"), 4)
        XCTAssertEqual(grade("ok"), 3)
        XCTAssertEqual(grade("okay"), 3)
        XCTAssertEqual(grade("correct"), 3)
        XCTAssertEqual(grade("simple"), 4)
        XCTAssertEqual(grade("trivial"), 4)
    }
    
    func testQuestions() {
        XCTAssertTrue(isQuestion("why is urllc important"))
        XCTAssertTrue(isQuestion("explain more about embb"))
        XCTAssertTrue(isQuestion("what does that mean?"))
        XCTAssertTrue(isQuestion("how does this work"))
        XCTAssertTrue(isQuestion("tell me more"))
        XCTAssertTrue(isQuestion("can you explain"))
        XCTAssertTrue(isQuestion("i don't understand"))
        XCTAssertTrue(isQuestion("not clear"))
        XCTAssertTrue(isQuestion("what does NEF mean"))
    }
    
    func testAmbiguous() {
        XCTAssertEqual(parse("okay"), .ambiguous)
        XCTAssertEqual(parse("hmm"), .ambiguous)
        XCTAssertEqual(parse("uh"), .ambiguous)
        XCTAssertEqual(parse(""), .ambiguous)
        XCTAssertEqual(parse("a"), .ambiguous)
    }
    
    func testEdgeCases() {
        // Grade wins if at beginning
        XCTAssertEqual(grade("good but why is it important"), 3)
        
        // Question if grade not at beginning
        XCTAssertTrue(isQuestion("that was good but why is it important"))
        
        // Explicit grade commands
        XCTAssertEqual(grade("grade it 2"), 2)
        XCTAssertEqual(grade("mark as hard"), 2)
        XCTAssertEqual(grade("set to easy"), 4)
        XCTAssertEqual(grade("make it good"), 3)
        
        // Number words
        XCTAssertEqual(grade("grade one"), 1)
        XCTAssertEqual(grade("mark two"), 2)
        XCTAssertEqual(grade("three"), 3)
        XCTAssertEqual(grade("four"), 4)
    }
    
    // Helper functions
    private func grade(_ s: String) -> Int {
        if case .grade(let e, _, _) = IntentParser.parse(s) { return e }
        XCTFail("Expected grade, got: \(IntentParser.parse(s))")
        return -1
    }
    
    private func isQuestion(_ s: String) -> Bool {
        if case .question(_) = IntentParser.parse(s) { return true }
        return false
    }
    
    private func parse(_ s: String) -> UserIntent {
        return IntentParser.parse(s)
    }
}

