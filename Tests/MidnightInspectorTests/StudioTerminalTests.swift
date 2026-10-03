import Testing
import loom

@testable import MidnightInspector

struct StudioTerminalTests {
    @Test @MainActor func viewportClipsAndEscapesModelText() {
        for (width, height) in [(0, 0), (1, 1), (20, 5), (100, 24)] {
            var frame = Frame(width: width, height: height)
            StudioTerminal.render(frame: &frame, state: nil, rows: ["model\u{001B}[2J"], message: "Ready")
            #expect(frame.buffer.width == width)
            #expect(frame.buffer.height == height)
            #expect(!frame.buffer.plainText.contains("\u{001B}"))
            if height > 10 { #expect(frame.buffer.plainText.contains("midnight studio")) }
        }
    }
}
