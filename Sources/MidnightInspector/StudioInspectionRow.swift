/// Semantic styling stays separate from terminal escape sequences and transport data.
struct StudioInspectionRow: Sendable, ExpressibleByStringLiteral {
    enum Tone: Sendable {
        case text, muted, heading, spine, attention, convolution, experts, feedForward
    }

    struct Segment: Sendable {
        let text: String
        let tone: Tone
        let intensity: Double?

        init(text: String, tone: Tone, intensity: Double? = nil) {
            self.text = text
            self.tone = tone
            self.intensity = intensity
        }
    }

    let segments: [Segment]
    var text: String { segments.map(\.text).joined() }

    init(_ text: String, tone: Tone = .text) {
        segments = [Segment(text: text, tone: tone)]
    }

    init(segments: [Segment]) { self.segments = segments }
    init(stringLiteral value: String) { self.init(value) }
}
