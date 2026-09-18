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

import Logging
import NIOCore

/// The frame→producer bridge for client carriers: yields each framed payload
/// to the carrier's backpressured ``ClientFrameSequence`` and drives channel
/// reads by demand (the `NIOAsyncChannel` pattern).
///
/// With the channel's `autoRead` disabled by the carrier bootstraps, reads are
/// armed here (`channelActive`) and by the producer's `produceMore` demand — a
/// slow consumer naturally pauses the peer instead of growing memory, and
/// frames are never dropped.
///
/// - Note: `Sendable` because `addHandlers` requires it; every stored property
///   is immutable and `Sendable`.
final class ClientFrameBridge: ChannelInboundHandler, Sendable {
    typealias InboundIn = [UInt8]

    private let source: ClientFramesProducer.Source
    private let demand: FrameDemand
    private let logger: Logger?

    init(
        source: ClientFramesProducer.Source,
        demand: FrameDemand,
        logger: Logger?
    ) {
        self.source = source
        self.demand = demand
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        demand.attach(context.channel)
        // autoRead is disabled at the carrier bootstraps; this arms the first
        // read. subsequent reads are demand-driven through yield()/produceMore.
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch source.yield(frame) {
        case .produceMore:
            // demand holds: keep reading.
            context.read()
        case .stopProducing, .dropped:
            // backpressured (or terminated): pause; produceMore() re-arms.
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        demand.detach()
        source.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger?.warning("client channel error: \(error)")
        demand.detach()
        source.finish()
        context.close(promise: nil)
    }
}
