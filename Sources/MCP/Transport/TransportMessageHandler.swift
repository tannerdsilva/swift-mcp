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
}
