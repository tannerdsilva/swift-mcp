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

/// An actor that serializes message handling for a channel.
///
/// This provides:
/// - **Backpressure**: Only one message is processed at a time per actor instance.
/// - **Ordering**: Responses are written in the same order requests are received.
/// - **Cancellation**: A cancelled actor stops processing new messages.
///
/// - Note: **Explicit per-connection serialization contract.** Every frame is
///   handled to completion (including a long `tools/call`) before the next is
///   processed, so concurrent requests on one connection run strictly in FIFO
///   order and an in-flight call delays everything behind it — including
///   `ping` and close-time `shutdown` (which is why the shutdown ladder has a
///   grace window). This is a deliberate ordering/backpressure choice, not an
///   omission: parallel-calling harnesses should spread calls across separate
///   server processes (the spawned-tier model) or accept FIFO.
actor TransportMessageHandler {
    private let handler: @Sendable ([UInt8], MCPCallerInfo) async throws -> [UInt8]?
    private let caller: MCPCallerInfo
    private let write: @Sendable ([UInt8]) throws -> Void
    private let makeError: @Sendable ([UInt8], Error) -> [UInt8]?
    private var isCancelled = false

    public init(
        handler: @escaping @Sendable ([UInt8], MCPCallerInfo) async throws -> [UInt8]?,
        caller: MCPCallerInfo,
        write: @escaping @Sendable ([UInt8]) throws -> Void,
        makeError: @escaping @Sendable ([UInt8], Error) -> [UInt8]?
    ) {
        self.handler = handler
        self.caller = caller
        self.write = write
        self.makeError = makeError
    }

    /// Cancel further message processing.
    public func cancel() {
        isCancelled = true
    }

    /// Process a single message. Returns immediately without processing if cancelled.
    public func process(_ data: [UInt8]) async {
        guard !isCancelled else { return }
        do {
            if let response = try await handler(data, caller) {
                try write(response)
            }
        } catch {
            if let errorData = makeError(data, error) {
                try? write(errorData)
            }
        }
    }

    /// Process a notification out of band: run off the serialized request
    /// queue, so `notifications/cancelled` can interrupt an in-flight tool at
    /// its next cooperative suspend point instead of queueing behind it.
    ///
    /// The per-connection FIFO contract covers requests and their responses —
    /// notifications produce no response, so concurrent handling cannot
    /// reorder anything the peer observes. The call still resolves through the
    /// actor (its result, if any, is deliberately dropped here; the router
    /// returns `nil` for notifications anyway).
    nonisolated public func processNotification(_ data: [UInt8]) async {
        if await isCancelled { return }
        _ = try? await handler(data, caller)
    }
}
