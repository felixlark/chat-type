import Testing
@testable import ChatType

@Test func liveTranscriptReplacesPartialAndIgnoresLatePartial() {
    var text = StreamingTranscript()
    text.apply(start: 0, end: 1, text: "测", final: false)
    text.apply(start: 0, end: 2, text: "测试。", final: true)
    text.apply(start: 0, end: 2, text: "旧的", final: false)
    text.apply(start: 2, end: 3, text: "下一句", final: false)
    #expect(text.text == "测试。下一句")
    #expect(text.finalText == "测试。")
    text.apply(start: 2, end: 4, text: "下一句。", final: true)
    text.apply(start: 2, end: 4, text: "下一句。", final: true)
    #expect(text.finalText == "测试。下一句。")
}

@Test func liveTranscriptOrdersAndReplacesOverlappingWindow() {
    var text = StreamingTranscript()
    text.apply(start: 3, end: 5, text: "后半句", final: false)
    text.apply(start: 2, end: 5, text: "完整后句", final: false)
    text.apply(start: 0, end: 2, text: "前句。", final: true)
    #expect(text.text == "前句。完整后句")
    #expect(!PolishResponseTransport.isCompletedEvent("data: {\"type\":\"response.output_text.delta\",\"delta\":\"response.completed\"}"))
    #expect(PolishResponseTransport.isCompletedEvent("data: {\"type\":\"response.completed\"}"))
}
