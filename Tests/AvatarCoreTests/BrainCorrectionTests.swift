import AvatarCore
import Testing

@Suite("Brain correction request shape")
struct BrainCorrectionTests {
    @Test("Equivalent casing punctuation and spacing share one shape")
    func canonicalizesRequestShape() {
        #expect(
            BrainRequestShape.canonical("  PLAY—some   MUSIC!!! ")
                == "play some music"
        )
        #expect(
            BrainRequestShape.canonical("play\u{0007}some\nMUSIC")
                == "play some music"
        )
    }

    @Test("Empty shapes are refused and persisted shapes are bounded")
    func boundsRequestShape() {
        #expect(BrainRequestShape.canonical(" \n\t ") == nil)
        let shape = BrainRequestShape.canonical(
            String(repeating: "a", count: 300)
        )
        #expect(shape?.unicodeScalars.count == 160)
    }
}
