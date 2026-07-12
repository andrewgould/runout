import AVFoundation
import Foundation

/// Funnels tapped audio buffers from the real-time thread to an async consumer **strictly in
/// yield order** — see docs/IMPROVEMENT_PLAN.md P0-1.
///
/// The previous approach (one unstructured `Task { await writer.append(copy) }` per buffer) had
/// two silent-corruption paths: Swift makes no ordering guarantee between separate tasks, so two
/// pending appends could execute out of order under CPU pressure; and stopping the writer could
/// race ahead of in-flight appends, dropping the recording's final buffers. An `AsyncStream`
/// preserves yield order by construction, and a single long-lived consumer means "drain
/// everything, then close the file" is expressible as awaiting one task.
///
/// `yield(_:)` is safe to call from the real-time tap callback (it's synchronous and cheap; the
/// buffer must already be a copy the tap is allowed to retain — see `AVAudioPCMBuffer.copy()`).
/// A throwing append stops consumption immediately and reports through `onFailure` exactly once;
/// buffers yielded after a failure are discarded.
final class OrderedBufferFeed {
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let drainTask: Task<Void, Never>

    init(
        append: @escaping (AVAudioPCMBuffer) async throws -> Void,
        onFailure: @escaping (Error) async -> Void
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        self.continuation = continuation
        drainTask = Task.detached(priority: .userInitiated) {
            do {
                for await buffer in stream {
                    try await append(buffer)
                }
            } catch {
                // Stop accepting further buffers so a dead recording doesn't accumulate
                // unconsumed copies in the stream's buffer until the user hits Stop.
                continuation.finish()
                await onFailure(error)
            }
        }
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(buffer)
    }

    /// Stops accepting new buffers and waits until every already-yielded buffer has been
    /// appended (or a failure ended consumption early). Only after this returns is it safe to
    /// close the underlying file without losing the recording's tail.
    func finishAndDrain() async {
        continuation.finish()
        await drainTask.value
    }
}
