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
import NIO

/// newline-delimited JSON-RPC framing for any NIO channel.
///
/// mcp stdio framing is one complete JSON-RPC message per physical line,
/// `0x0A`-terminated. json string literals escape newlines, so a literal
/// `0x0A` byte can only be a frame boundary and a partially-received buffer
/// is never mistaken for a frame.
///
/// this is the single framing implementation for every carrier — server tcp,
/// server stdio (phase 1), client tcp, and the swift-slash subprocess client —
/// so the frame format and the size cap cannot drift between deployments:
///
/// - inbound: `ByteBuffer` → complete `[UInt8]` frames; partial reads are
///   buffered on the event loop; a remainder larger than `maxMessageSize` is
///   rejected with a `-32700 Message too large` frame and the channel closes.
/// - outbound: `[UInt8]` payloads → `ByteBuffer` with a trailing `0x0A`.
///
/// - Warning: This class uses `@unchecked Sendable` because its framing buffer
///   is mutable. All handler methods run on the channel's event loop; the
///   `buffer` property is never touched outside it.
final class MCPFrameCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = [UInt8]
    typealias OutboundIn = [UInt8]
    typealias OutboundOut = ByteBuffer

    /// Leftover partial frames from a previous read, event-loop-confined.
    private var buffer: ByteBuffer?
    /// The maximum size of a single newline-delimited JSON-RPC message.
    private let maxMessageSize: Int
    /// Pre-encoded `-32700 Message too large` error frame (no newline; the
    /// reject path writes it framed directly).
    private let oversizeErrorFrame: [UInt8]

    /// Creates a new frame codec.
    ///
    /// - Parameters:
    ///   - maxMessageSize: The maximum size in bytes of a single frame. A
    ///     frame larger than this is rejected and the channel is closed,
    ///     bounding per-connection memory regardless of peer behavior.
    ///   - oversizeErrorFrame: Pre-encoded JSON-RPC error frame written when
    ///     the cap is exceeded, before the channel closes.
    init(maxMessageSize: Int, oversizeErrorFrame: [UInt8]) {
        self.maxMessageSize = maxMessageSize
        self.oversizeErrorFrame = oversizeErrorFrame
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)

        // prepend any leftover partial frame from a previous read
        if var existing = buffer {
            existing.writeBuffer(&inbound)
            inbound = existing
            buffer = nil
        }

        // emit every complete line as its own frame
        while let lineEnd = inbound.readableBytesOfNewline() {
            // a complete frame may itself exceed the cap (a single oversized
            // line): the size limit applies per frame, so reject it rather
            // than emitting it — otherwise a peer can pass any single line
            // through the cap.
            if lineEnd > maxMessageSize {
                rejectOversize(context: context)
                return
            }
            guard let frame = inbound.readBytes(length: lineEnd) else { continue }
            inbound.moveReaderIndex(forwardBy: 1)
            context.fireChannelRead(wrapInboundOut(frame))
        }

        // a remaining partial frame larger than the cap is a single unbounded
        // message. reject it and close the connection so memory stays bounded
        // no matter what the peer streams.
        if inbound.readableBytes > maxMessageSize {
            rejectOversize(context: context)
            return
        }

        // store the remainder for the next read
        if inbound.readableBytes > 0 {
            buffer = inbound
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let payload = unwrapOutboundIn(data)
        var out = context.channel.allocator.buffer(capacity: payload.count + 1)
        out.writeBytes(payload)
        out.writeInteger(UInt8(0x0A))
        context.write(wrapOutboundOut(out), promise: promise)
    }

    /// writes the pre-encoded error frame (framed), then closes the channel.
    ///
    /// the buffer is already framed (payload + trailing newline), so it is
    /// fired past this handler toward the socket — routing it through the
    /// codec's own outbound `write` (which expects an unframed `[UInt8]`
    /// payload) would trap on `unwrapOutboundIn`.
    private func rejectOversize(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: oversizeErrorFrame.count + 1)
        out.writeBytes(oversizeErrorFrame)
        out.writeInteger(UInt8(0x0A))
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        buffer = nil
        context.close(promise: nil)
    }
}

extension ByteBuffer {
    /// Returns the number of readable bytes up to and including the first
    /// newline character (0x0A), or `nil` if no newline is found.
    ///
    /// the returned value is the 0-based index of the newline byte, so frames
    /// are extracted by reading `length == index` bytes (which excludes the
    /// newline) and then advancing one further byte to consume it.
    func readableBytesOfNewline() -> Int? {
        let readable = self.withUnsafeReadableBytes { ptr in
            ptr.firstIndex(of: 0x0A)
        }
        return readable
    }
}
