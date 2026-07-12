import AVFoundation
import XCTest
@testable import Runout

final class OrderedBufferFeedTests: XCTestCase {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!

    /// A 1-frame buffer whose single sample carries `sequenceNumber`, so the consumer can
    /// reconstruct the order buffers actually arrived in.
    private func stampedBuffer(_ sequenceNumber: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = Float(sequenceNumber)
        return buffer
    }

    private func sequenceNumber(of buffer: AVAudioPCMBuffer) -> Int {
        Int(buffer.floatChannelData![0][0])
    }

    /// The regression this type exists to prevent (docs/IMPROVEMENT_PLAN.md P0-1): the old
    /// Task-per-buffer handoff had no ordering guarantee. Jittered append delays simulate the
    /// scheduler pressure that would have reordered independent tasks — order must hold anyway.
    func testBuffersAreAppendedInYieldOrderUnderJitteredConsumerDelays() async {
        let recorder = OrderRecorder()
        let feed = OrderedBufferFeed(
            append: { [self] buffer in
                try? await Task.sleep(nanoseconds: UInt64.random(in: 0...200_000))
                await recorder.record(sequenceNumber(of: buffer))
            },
            onFailure: { _ in XCTFail("no failure expected") }
        )

        let total = 500
        for i in 0..<total {
            feed.yield(stampedBuffer(i))
        }
        await feed.finishAndDrain()

        let received = await recorder.values
        XCTAssertEqual(received, Array(0..<total), "buffers must be appended in exactly the order they were yielded")
    }

    /// The second old bug: stopping the writer could race ahead of in-flight appends, dropping
    /// the recording's tail. Everything yielded before finishAndDrain must be appended by the
    /// time it returns.
    func testFinishAndDrainDeliversEverythingYieldedBeforeIt() async {
        let recorder = OrderRecorder()
        let feed = OrderedBufferFeed(
            append: { [self] buffer in await recorder.record(sequenceNumber(of: buffer)) },
            onFailure: { _ in XCTFail("no failure expected") }
        )

        for i in 0..<100 {
            feed.yield(stampedBuffer(i))
        }
        await feed.finishAndDrain()

        let received = await recorder.values
        XCTAssertEqual(received.count, 100, "no yielded buffer may be dropped by stopping")
    }

    func testAppendErrorReportsFailureOnceAndStopsConsuming() async {
        struct DiskFullError: Error {}
        let recorder = OrderRecorder()
        let failureCount = OrderRecorder()

        let feed = OrderedBufferFeed(
            append: { [self] buffer in
                let sequence = sequenceNumber(of: buffer)
                if sequence == 3 { throw DiskFullError() }
                await recorder.record(sequence)
            },
            onFailure: { _ in await failureCount.record(1) }
        )

        for i in 0..<50 {
            feed.yield(stampedBuffer(i))
        }
        await feed.finishAndDrain()

        let received = await recorder.values
        let failures = await failureCount.values
        XCTAssertEqual(received, [0, 1, 2], "consumption must stop at the failing buffer")
        XCTAssertEqual(failures.count, 1, "failure must be reported exactly once")
    }
}

private actor OrderRecorder {
    private(set) var values: [Int] = []
    func record(_ value: Int) {
        values.append(value)
    }
}
