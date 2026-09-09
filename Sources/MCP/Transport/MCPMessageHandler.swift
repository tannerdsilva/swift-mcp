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
import QuickJSON

/// A channel handler that forwards newline-delimited JSON-RPC frames — already
/// framed by `MCPFrameCodec` — to the MCP message handler via an actor for
/// serialized processing.
///
/// Shared by every server carrier (TCP connections and the stdio pipe channel):
/// each channel builds its `TransportMessageHandler` when it becomes active,
/// with a write closure that routes response payloads back through the codec's
/// outbound framing (which appends the trailing newline).
///
/// The pending-frame bookkeeping exists for the stdio drain-then-close
/// contract: when the carrier sets `closeOnInputClosed`, an input half-close
/// (client EOF on stdin) is answered by flushing all already-dispatched
/// responses before the channel closes, so a client that writes requests and
/// then closes its pipe still receives every reply. TCP carriers leave it
/// `false` and the half-close path is inert — their connections close exactly
/// as before.
///
/// - Note: marked `Sendable` because NIO's `channelInitializer` closures are
///   `@Sendable`; all mutable state stays on the event loop.
final class MCPMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = [UInt8]

    private let handler: @Sendable ([UInt8], MCPCallerInfo) async throws -> [UInt8]?
    private let caller: MCPCallerInfo
    private let logger: Logger?
    /// When `true`, an input half-close drains pending responses and then
    /// closes the channel (stdio contract). When `false`, input half-close is
    /// inert (TCP contract).
    private let closeOnInputClosed: Bool
    /// The maximum frames queued for processing at once. A peer that outruns
    /// the processing loop beyond this is disconnected (flood defense), which
    /// bounds the dispatcher's task queue and buffered memory.
    static let maxPendingFrames = 128
    private var actor: TransportMessageHandler?
    /// Frames dispatched to the actor but not yet processed, event-loop-confined.
    private var pendingFrames = 0
    /// Whether the peer has signaled end-of-input, event-loop-confined.
    private var inputClosed = false

    init(
        handler: @escaping @Sendable ([UInt8], MCPCallerInfo) async throws -> [UInt8]?,
        caller: MCPCallerInfo,
        logger: Logger? = nil,
        closeOnInputClosed: Bool = false
    ) {
        self.handler = handler
        self.caller = caller
        self.logger = logger
        self.closeOnInputClosed = closeOnInputClosed
    }

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        let handler = self.handler
        let caller = self.caller
        let logger = self.logger
        self.actor = TransportMessageHandler(
            handler: handler,
            caller: caller,
            write: { bytes in
                // the frame codec appends the trailing newline on outbound.
                channel.writeAndFlush(bytes, promise: nil)
            },
            makeError: { requestBytes, error in
                guard let request = try? QuickJSON.decode(JSONRPCRequest.self, from: requestBytes) else {
                    // Without an id there is no frame to reply to.
                    return nil
                }
                do {
                    let response = JSONRPCErrorResponse(
                        id: request.id,
                        code: -32603,
                        message: "Internal error: \(readableErrorDescription(error))"
                    )
                    return try QuickJSON.encode(response)
                } catch {
                    // A fixed-shape error frame cannot realistically fail to encode.
                    logger?.warning("Failed to encode framed error response: \(error)")
                    return nil
                }
            }
        )
        // autoRead is disabled at the bootstraps; this arms the first read.
        // Subsequent reads are demand-re-armed as the queue drains.
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task { [actor] in
            await actor?.cancel()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard let actor = self.actor else { return }
        // flood defense: cap the dispatcher queue. a peer outrunning the
        // processing loop is disconnected (bounded memory and task queue),
        // never serviced without bound.
        guard pendingFrames < Self.maxPendingFrames else {
            logger?.warning("frame queue exceeds \(Self.maxPendingFrames); closing connection")
            context.close(promise: nil)
            return
        }
        pendingFrames += 1
        // Dispatch to the actor for serialized processing; the completion hops
        // back to the event loop so the pending counter stays event-loop-confined
        // and a triggered close is ordered behind the response write the actor
        // just enqueued. only sendable values are captured across the hop.
        let eventLoop = context.eventLoop
        let channel = context.channel
        Task {
            await actor.process(frame)
            eventLoop.execute { [self, channel] in
                self.pendingFrames -= 1
                if self.pendingFrames == 0, !self.inputClosed {
                    // demand-driven reads: re-arm only once the queue drains,
                    // so real backpressure bounds how far the peer can get ahead.
                    channel.read()
                }
                self.maybeCloseAfterDrain(channel: channel)
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event as? ChannelEvent == .some(.inputClosed) {
            inputClosed = true
            maybeCloseAfterDrain(channel: context.channel)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger?.warning("Channel error: \(error)")
        context.close(promise: nil)
    }

    /// Closes the channel once input is closed and every dispatched frame has
    /// been processed (its response write enqueued on the event loop). This is
    /// what turns "client wrote requests, then closed stdin" into "server
    /// flushed every reply, then ended the session" — the responses to
    /// already-received requests are never dropped by the EOF close.
    private func maybeCloseAfterDrain(channel: Channel) {
        guard closeOnInputClosed, inputClosed, pendingFrames == 0 else { return }
        channel.close(promise: nil)
    }
}
