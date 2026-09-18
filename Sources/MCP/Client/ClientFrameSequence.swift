//===----------------------------------------------------------------------===//
//
// This source file is part of the MCP open source project
//
// Copyright (c) 2024 and the MCP project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import NIOCore
import Synchronization

/// The concrete backpressured producer family every client carrier uses.
typealias ClientFramesProducer = NIOAsyncSequenceProducer<
    [UInt8],
    NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
    FrameDemandDelegate
>

/// A backpressure-aware, `Sendable` sequence of MCP frames for client carriers.
///
/// Wraps NIO's `NIOAsyncSequenceProducer` with high/low watermark demand: while
/// the consumer keeps up, reads stay armed; once the buffer reaches the high
/// watermark, the networked carriers stop reading (real backpressure into the
/// pipe or socket), and demand resumes below the low watermark. Frames are
/// never dropped — demand pauses the producer instead.
public struct ClientFrameSequence: AsyncSequence, Sendable {
    /// One complete, newline-delimited JSON-RPC frame.
    public typealias Element = [UInt8]
    /// The iterator (non-throwing).
    public typealias AsyncIterator = ClientFrameIterator

    private let producer: ClientFramesProducer

    /// Creates the consumer half from a producer.
    /// - Parameter producer: The producer's sequence half.
    init(producer: ClientFramesProducer) {
        self.producer = producer
    }

    /// Iterates the frames, in arrival order, until EOF or stop.
    public func makeAsyncIterator() -> AsyncIterator {
        ClientFrameIterator(underlying: producer.makeAsyncIterator())
    }
}

/// The iterator half of ``ClientFrameSequence`` (publicly named so consumers
/// do not need the internal producer family).
///
/// - Warning: `@unchecked Sendable` because NIO's producer iterator is not
///   declared `Sendable`; this wrapper adds no additional mutable state and is
///   consumed from the client's single read-loop task.
public struct ClientFrameIterator: AsyncIteratorProtocol, @unchecked Sendable {
    /// The NIO iterator; this wrapper keeps NIO internals out of the public type.
    private var underlying: ClientFramesProducer.AsyncIterator

    init(underlying: ClientFramesProducer.AsyncIterator) {
        self.underlying = underlying
    }

    /// Advances to the next frame, or `nil` at EOF.
    public mutating func next() async -> [UInt8]? {
        await underlying.next()
    }
}

/// The backpressure watermarks, in frames.
enum ClientFramesWatermarks {
    /// Demand resumes below this many buffered frames.
    static let low = 64
    /// The carrier pauses reads past this many buffered frames.
    static let high = 256
}

/// Owns the producer half of a carrier's frame stream and its demand wiring.
///
/// The carrier retains the ``source`` for `yield`/`finish`; the consumer half
/// is exposed via ``sequence`` (returned by `ClientTransport.frames()`). The
/// ``demand`` is attached to the channel when it activates, so the producer's
/// `produceMore` re-arms reads exactly when the consumer drains the buffer.
final class ClientFrames: Sendable {
    /// The producer half (yield/finish).
    let source: ClientFramesProducer.Source
    /// The consumer half.
    let sequence: ClientFrameSequence
    /// Channel-read demand driver.
    let demand: FrameDemand

    init() {
        let demand = FrameDemand()
        let made = ClientFramesProducer.makeSequence(
            elementType: [UInt8].self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: ClientFramesWatermarks.low,
                highWatermark: ClientFramesWatermarks.high
            ),
            // teardown guarantee: whatever path ends the transport — close(),
            // a failed start() with no channel, or the object simply being
            // dropped — the source's deinit finishes the stream. NIO traps
            // (explicitly) when a source deinits without finish().
            finishOnDeinit: true,
            delegate: FrameDemandDelegate(demand: demand)
        )
        self.demand = demand
        self.source = made.source
        self.sequence = ClientFrameSequence(producer: made.sequence)
    }
}

/// The producer's demand delegate: re-arms channel reads once the consumer
/// drains below the low watermark.
final class FrameDemandDelegate: NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
    private let demand: FrameDemand

    init(demand: FrameDemand) {
        self.demand = demand
    }

    func produceMore() {
        demand.readIfAttached()
    }

    func didTerminate() {}
}

/// Attaches the transport's channel to the demand driver.
final class FrameDemand: @unchecked Sendable {
    private let lock = Mutex<Channel?>(nil)

    /// Binds the channel this carrier reads from.
    func attach(_ channel: Channel) {
        lock.withLock { slot in slot = channel }
    }

    /// Re-arms a read if a channel is attached (demand from the consumer).
    func readIfAttached() {
        if let channel = lock.withLock({ $0 }) {
            channel.read()
        }
    }

    /// Clears the binding (teardown).
    func detach() {
        lock.withLock { slot in slot = nil }
    }
}
