import CoreGraphics
import Testing
@testable import ChatType

@Test func sublimeCompositionConvertsScaledClientCoordinatesAndNativeTitleBar() {
    let geometry = EditorCompositionGeometry(window: CGRect(x: 2023, y: -1083, width: 756, height: 876),
                                             scale: 1.2, titleBarHeight: 32)
    let caret = geometry.rect(x: 62.5, y: 71.66666666666667, width: 1 / 1.2, height: 19.166666666666668)
    #expect(abs(caret.minX - 2098) < 0.01)
    #expect(abs(caret.minY - -965) < 0.01)
    #expect(abs(caret.height - 23) < 0.01)
    #expect(abs(caret.width - 1) < 0.01)
}

@Test func compositionStartsBelowRightOfCaretAndStaysOnScreenWhenWrapped() {
    let available = CGRect(x: 8, y: 8, width: 1000, height: 800)
    let caret = CGRect(x: 100, y: 600, width: 1, height: 23)
    let short = InputCompositionLayout.frame(caret: caret, size: CGSize(width: 150, height: 35), available: available)
    let wrapped = InputCompositionLayout.frame(caret: caret, size: CGSize(width: 360, height: 150), available: available)
    #expect(short.minX == caret.maxX + 6)
    #expect(short.maxY == caret.minY - 6)
    #expect(wrapped.minX == short.minX)
    #expect(wrapped.maxY == short.maxY)
    let edge = InputCompositionLayout.frame(caret: CGRect(x: 990, y: 12, width: 1, height: 23),
                                             size: CGSize(width: 360, height: 150), available: available)
    #expect(available.contains(edge))
}
