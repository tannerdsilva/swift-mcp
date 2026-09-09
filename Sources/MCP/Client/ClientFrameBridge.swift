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

/// The frame-dispatch `ChannelInboundHandler` for client carriers: yields each
/// framed payload into the carrier's `AsyncStream` and finishes the stream on
/// channel close.
///
/// Shared by `SubprocessClientTransport` (NIO pipe channel) and
/// `TCPClientTransport` (NIO socket channel) — the client read loop consumes
/// the same stream shape regardless of carrier.
///
/// - Note: `Sendable` because `addHandlers` requires it; every stored property
///   is immutable and `Sendable`.
final class ClientFrameBridge: ChannelInboundHandler, Sendable {
    typealias InboundIn = [UInt8]

    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let logger: Logger?

    init(continuation: AsyncStream<[UInt8]>.Continuation, logger: Logger?) {
        self.continuation = continuation
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger?.warning("client channel error: \(error)")
        continuation.finish()
        context.close(promise: nil)
    }
}
