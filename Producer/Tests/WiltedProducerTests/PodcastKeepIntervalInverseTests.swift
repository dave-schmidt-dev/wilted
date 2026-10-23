import Testing
import WiltedDomain
@testable import WiltedProducer

/// Preparing a cut episode again walks the listener's place back from the old
/// cut to the original (`unmap`), then forward onto the new cut. The two have
/// to agree wherever the first has an answer.
@Suite("Keep interval inverse")
struct PodcastKeepIntervalInverseTests {
    /// 3.0-7.5 removed from a twelve second original.
    private let kept = [
        PodcastKeepInterval(startSeconds: 0, endSeconds: 3, outputStartSeconds: 0),
        PodcastKeepInterval(startSeconds: 7.5, endSeconds: 12, outputStartSeconds: 3),
    ]

    @Test func everyCutPositionRoundTripsThroughTheOriginal() throws {
        for cut in [0.0, 1.0, 2.9, 3.0, 4.5, 7.4] {
            let original = try #require(PodcastKeepInterval.unmap(cut, through: kept))
            #expect(PodcastKeepInterval.map(original, through: kept) == cut, "cut position \(cut)")
        }
        #expect(PodcastKeepInterval.unmap(1.0, through: kept) == 1.0)
        #expect(PodcastKeepInterval.unmap(4.5, through: kept) == 9.0)
    }

    /// A pause shortened by silence trimming leaves a gap on the original's
    /// clock that the cut file does not have.
    @Test func aGapLeftByASilenceTrimIsStepOverInBothDirections() throws {
        let trimmed = [
            PodcastKeepInterval(startSeconds: 0, endSeconds: 3, outputStartSeconds: 0),
            PodcastKeepInterval(startSeconds: 3.5, endSeconds: 6, outputStartSeconds: 3),
        ]
        #expect(PodcastKeepInterval.unmap(3.0, through: trimmed) == 3.5)
        #expect(PodcastKeepInterval.unmap(2.5, through: trimmed) == 2.5)
        #expect(PodcastKeepInterval.map(3.25, through: trimmed) == nil)
        #expect(PodcastKeepInterval.map(3.25, through: trimmed, silence: [3.0..<3.5]) == 3.0)
        #expect(PodcastKeepInterval.mapSnapping(3.25, through: trimmed) == 3.0)
    }

    @Test func aPositionInsideARemovedSpanLandsWhereTheProgrammeResumes() {
        #expect(PodcastKeepInterval.map(5.0, through: kept) == nil)
        #expect(PodcastKeepInterval.mapSnapping(5.0, through: kept) == 3.0)
        #expect(PodcastKeepInterval.mapSnapping(3.0, through: kept) == 3.0, "the start of a removed span")
        #expect(PodcastKeepInterval.mapSnapping(2.0, through: kept) == 2.0, "kept audio maps as `map` does")
    }

    @Test func positionsOutsideTheTimelineClampToItsEnds() {
        #expect(PodcastKeepInterval.unmap(100, through: kept) == 12)
        #expect(PodcastKeepInterval.mapSnapping(100, through: kept) == 7.5)
        #expect(PodcastKeepInterval.unmap(-1, through: kept) == 0)
        #expect(PodcastKeepInterval.unmap(7.5, through: kept) == 12, "exactly the end of the cut")
    }

    @Test func anEmptyTimelineHasNoAnswer() {
        #expect(PodcastKeepInterval.unmap(1, through: []) == nil)
        #expect(PodcastKeepInterval.mapSnapping(1, through: []) == nil)
    }

    @Test func aPersistedTimelineReadsAsKeepIntervals() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [],
            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 3, outputStartSeconds: 0),
                   try .init(originalStartSeconds: 7.5, originalEndSeconds: 12, outputStartSeconds: 3)]
        )
        #expect(timeline.kept.map { PodcastKeepInterval($0) } == kept)
    }
}
