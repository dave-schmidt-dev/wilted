import Foundation
import Testing
@testable import SpikeCloudKit

@Test("chunk plan splits 120 MB into 45 MB chunks with a short tail")
func chunkPlanSplitsWithTail() {
    let mb: Int64 = 1_048_576
    let plan = ChunkPlan(byteCount: 120 * mb)
    #expect(plan.chunks.map(\.length) == [45 * mb, 45 * mb, 30 * mb])
    #expect(plan.chunks.map(\.offset) == [0, 45 * mb, 90 * mb])
    #expect(plan.chunks.map(\.index) == [0, 1, 2])
    #expect(plan.chunks.reduce(0) { $0 + $1.length } == 120 * mb)
}

@Test("chunk plan edge cases: exact multiple, smaller than a chunk, empty, bad chunk size")
func chunkPlanEdges() {
    let mb: Int64 = 1_048_576
    #expect(ChunkPlan(byteCount: 90 * mb).chunks.count == 2)
    #expect(ChunkPlan(byteCount: 250 * mb).chunks.count == 6)
    let small = ChunkPlan(byteCount: 20 * mb)
    #expect(small.chunks == [ChunkPlan.Chunk(index: 0, offset: 0, length: 20 * mb)])
    #expect(ChunkPlan(byteCount: 0).chunks.isEmpty)
    #expect(ChunkPlan(byteCount: 3, chunkBytes: 0).chunks.count == 3)
}

@Test("record names and types carry the Spike prefix and sort in chunk order")
func recordNames() {
    #expect(SpikeNames.zoneName == "SpikeZone")
    for type in [SpikeNames.singleRecordType, SpikeNames.chunkRecordType, SpikeNames.handoffRecordType] {
        #expect(type.hasPrefix("Spike"))
    }
    #expect(SpikeNames.singleRecordName(transferID: "abc") == "SpikeSingle-abc")
    let transfer = SpikeNames.chunkedTransferID("abc")
    #expect(transfer == "SpikeChunked-abc")
    #expect(SpikeNames.chunkRecordName(chunkedTransferID: transfer, index: 7) == "SpikeChunked-abc-c0007")
    #expect(SpikeNames.chunkRecordName(chunkedTransferID: transfer, index: 12345) == "SpikeChunked-abc-c12345")
    let names = (0 ..< 12).map { SpikeNames.chunkRecordName(chunkedTransferID: transfer, index: $0) }
    #expect(names == names.sorted())
    #expect(Set(names).count == names.count)
    #expect(SpikeNames.handoffSubscriptionID.hasPrefix(SpikeNames.subscriptionPrefix))
    #expect(SpikeNames.handoffRecordName.hasPrefix("Spike"))
}

@Test("building strategies and the context does not touch CloudKit")
func constructionIsOffline() {
    let context = SpikeCloudKitContext()
    #expect(context.zoneID.zoneName == "SpikeZone")
    #expect(context.recordID(named: "SpikeSingle-x").zoneID == context.zoneID)
    #expect(SingleAssetStrategy(context: context).name == "cloudkit-single-asset")
    #expect(ChunkedAssetStrategy(context: context).name == "cloudkit-chunked-asset-45mb")
    #expect(UbiquityDriveStrategy().name == "icloud-drive-ubiquity")
    #expect(UbiquityDriveStrategy.directoryName == "SpikeZone")
    let container = URL(fileURLWithPath: "/tmp/container")
    #expect(UbiquityDriveStrategy.spikeDirectory(in: container).path == "/tmp/container/Documents/SpikeZone")
}
