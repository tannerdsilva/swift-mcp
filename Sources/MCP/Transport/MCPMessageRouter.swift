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
import QuickJSON
import Synchronization

/// The byte-level JSON-RPC routing core of the framework.
///
/// Owns the tool registries and dispatcher surface and routes raw JSON-RPC
/// bytes to the matching handler (`initialize`, `ping`, `tools/list`,
/// `tools/call`, notifications), returning response bytes. Carrier-agnostic:
/// every server carrier drives it, and the in-process `LocalClientTransport`
/// drives it with no channel at all — so network-free MCP shares the exact
/// routing implementation with every networked deployment.
///
/// The frame format (newline-delimited JSON-RPC) lives in `MCPFrameCodec`;
/// this type is strictly payload-in / payload-out.
///
/// - Warning: This class uses `@unchecked Sendable` because its tool
///   registries are mutable. All registry access is serialized through an
///   internal lock; `name`, `version`, `logger`, and `toolDispatcher` are
///   `let` properties and safe for concurrent access.
final class MCPMessageRouter: @unchecked Sendable {

    private let name: String
    private let version: String
    private let logger: Logger
    /// The compile-time-known tool dispatch surface (macro-generated).
    ///
    /// Consulted before the dynamic registry for both `tools/list` and
    /// `tools/call`. `let` and `Sendable` — no synchronization needed.
    let toolDispatcher: (any MCPToolDispatcher)?

    /// Type-registered tools (name → tool type).
    private var tools: [String: any MCPTool.Type] = [:]
    /// Instance-registered tools (name → instance).
    private var toolInstances: [String: any MCPTool] = [:]
    /// Guards the tool registries.
    ///
    /// Registration is runtime-capable while the transports read the
    /// registries from the message-handling actors, so all access is
    /// serialized through this lock.
    private let toolsLock = Mutex<()>(())

    /// Creates a router.
    ///
    /// - Parameters:
    ///   - name: The server name (sent to clients during initialization).
    ///   - version: The server version (sent to clients during initialization).
    ///   - logger: The logger used for routing diagnostics.
    ///   - dispatcher: An optional compile-time-known tool dispatcher — the
    ///     macro-generated surface from `MCPApplication`. Tools it knows are
    ///     served through typed, exhaustive dispatch; tools added via
    ///     `register(_:)`/`registerInstance(_:instance:)` are served through
    ///     the dynamic registry.
    init(
        name: String,
        version: String,
        logger: Logger,
        dispatcher: (any MCPToolDispatcher)?
    ) {
        self.name = name
        self.version = version
        self.logger = logger
        self.toolDispatcher = dispatcher
    }

    // MARK: - Tool Registry

    /// Registers a tool with the router.
    ///
    /// After registration, the tool becomes available via `tools/list` and
    /// `tools/call` requests. The tool's ``MCPTool/toolName`` is used as the
    /// lookup key.
    ///
    /// - Warning: If a tool with the same name is already registered, the
    ///   existing tool is silently overwritten. Use `unregister(_:)` to
    ///   remove a tool before re-registering.
    ///
    /// Registration is safe to call while the server is running; the registry
    /// is guarded against concurrent access with the transports.
    func register<T: MCPTool>(_ tool: T) {
        let name = T.toolName
        logger.debug("Registering tool: \(name) (type: \(T.self))")
        toolsLock.withLock { _ in
            if tools[name] != nil {
                logger.warning("Tool '\(name)' is already registered and will be overwritten")
            }
            tools[name] = T.self
        }
        logger.info("Registered tool: \(name)")
    }

    /// Registers a tool instance with the router.
    ///
    /// Unlike `register(_:)` which stores the type and creates new instances
    /// for each call, this method stores the instance directly. Use this for
    /// tools with dynamic configuration that cannot be created via `init()`.
    ///
    /// - Parameter name: The name to register the tool under.
    /// - Parameter instance: The tool instance to register.
    ///
    /// Registration is safe to call while the server is running; the registry
    /// is guarded against concurrent access with the transports.
    func registerInstance(_ name: String, instance: any MCPTool) {
        logger.debug("Registering tool instance: \(name)")
        toolsLock.withLock { _ in
            if tools[name] != nil || toolInstances[name] != nil {
                logger.warning("Tool '\(name)' is already registered and will be overwritten")
            }
            toolInstances[name] = instance
        }
        logger.info("Registered tool instance: \(name)")
    }

    /// Unregisters a tool from the router by name.
    ///
    /// After unregistration, the tool is no longer available via `tools/list`
    /// or `tools/call`. Calling `unregister(_:)` with a name that has not
    /// been registered is a no-op. Both type-registered and instance-registered
    /// tools are removed.
    ///
    /// Unregistration is safe to call while the server is running; the
    /// registry is guarded against concurrent access with the transports.
    func unregister(_ name: String) {
        let removed: Bool = toolsLock.withLock { _ in
            let typeRemoved = tools.removeValue(forKey: name) != nil
            let instanceRemoved = toolInstances.removeValue(forKey: name) != nil
            return typeRemoved || instanceRemoved
        }
        guard removed else {
            logger.warning("Attempted to unregister unknown tool: \(name)")
            return
        }
        logger.info("Unregistered tool: \(name)")
    }

    // MARK: - Tool Registry Access

    /// Snapshots the type-registered tools under the registry lock.
    private func snapshotToolTypes() -> [(name: String, type: any MCPTool.Type)] {
        toolsLock.withLock { _ in tools.map { (name: $0.key, type: $0.value) } }
    }

    /// Snapshots the instance-registered tools under the registry lock.
    private func snapshotToolInstances() -> [(name: String, instance: any MCPTool)] {
        toolsLock.withLock { _ in toolInstances.map { (name: $0.key, instance: $0.value) } }
    }

    /// Looks up a type-registered tool under the registry lock.
    private func toolType(named name: String) -> (any MCPTool.Type)? {
        toolsLock.withLock { _ in tools[name] }
    }

    /// Looks up an instance-registered tool under the registry lock.
    private func toolInstance(named name: String) -> (any MCPTool)? {
        toolsLock.withLock { _ in toolInstances[name] }
    }

    // MARK: - Message Routing

    /// Routes an incoming JSON-RPC message to the appropriate handler.
    ///
    /// - Parameters:
    ///   - bytes: The raw JSON-RPC message bytes.
    ///   - caller: Information about the caller.
    /// - Returns: Response bytes, or `nil` for notifications.
    func route(_ bytes: [UInt8], caller: MCPCallerInfo) async throws -> [UInt8]? {
        // JSON-RPC batch: a top-level array of requests. Each element is
        // routed like a single message and the non-nil responses are returned
        // as one JSON array in request order. An empty batch is an Invalid
        // Request; a batch whose elements are all notifications gets no
        // response, matching the single-message rules.
        if firstNonWhitespaceByte(of: bytes) == 0x5B {  // '['
            guard let elements = try? QuickJSON.decode([AnyCodable].self, from: bytes), !elements.isEmpty else {
                logger.warning("Invalid JSON-RPC batch in: \(String(decoding: bytes, as: UTF8.self))")
                return makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
            }

            var responses: [[UInt8]] = []
            for element in elements {
                guard let elementBytes = try? QuickJSON.encode(element) else { continue }
                if let response = try await route(elementBytes, caller: caller) {
                    responses.append(response)
                }
            }

            guard !responses.isEmpty else { return nil }

            var batch: [UInt8] = Array("[".utf8)
            for (index, object) in responses.enumerated() {
                if index > 0 { batch.append(0x2C) }  // ','
                batch.append(contentsOf: object)
            }
            batch.append(0x5D)  // ']'
            return batch
        }

        let requestID: JSONRPCID
        let methodName: String
        let params: [String: AnyCodable]?

        // Peek at the envelope to distinguish requests (which carry an id) from
        // notifications (which must not). An invalid id value — a bool, array,
        // or object — still marks the frame as a request, so it gets a
        // -32600 Invalid Request error with a null id instead of a silent drop.
        //
        // A frame with `"id": null` is likewise a request, not a notification:
        // JSON-RPC 2.0 requires ids to be a String, Number, or NULL and answers
        // every request. Null ids are discouraged (they collide with the
        // unknown-id error convention) but permitted, so we echo `id: null`.
        let envelope = try? QuickJSON.decode([String: AnyCodable].self, from: bytes)
        let hasID = envelope?["id"] != nil

        // Any well-formed object frame carrying a jsonrpc value other than
        // "2.0" is an Invalid Request. JSONRPCRequest decodes the label as a
        // plain String, so the version must be validated explicitly here;
        // missing or non-string jsonrpc is caught by the decode paths below.
        if let envelope, let version = envelope["jsonrpc"]?.value as? String, version != "2.0" {
            logger.warning("Invalid jsonrpc version '\(version)' in: \(String(decoding: bytes, as: UTF8.self))")
            return makeErrorResponse(id: envelopeID(from: envelope) ?? .null, code: -32600, message: "Invalid Request")
        }

        if let request = try? QuickJSON.decode(JSONRPCRequest.self, from: bytes) {
            requestID = request.id
            methodName = request.method
            params = request.params
        } else if hasID {
            logger.warning("Invalid JSON-RPC request id in: \(String(decoding: bytes, as: UTF8.self))")
            return makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
        } else if let notification = try? QuickJSON.decode(JSONRPCNotification.self, from: bytes) {
            logger.trace("Received notification: method=\(notification.method)")
            // Notifications never produce responses.
            return nil
        } else if envelope != nil {
            // Valid JSON, but neither a decodable request nor a notification —
            // e.g. a request missing the jsonrpc field with no id. The JSON-RPC
            // spec reserves -32700 for input that is not valid JSON; anything
            // that parses but is malformed is an Invalid Request.
            logger.warning("Invalid JSON-RPC message: \(String(decoding: bytes, as: UTF8.self))")
            return makeErrorResponse(id: .null, code: -32600, message: "Invalid Request")
        } else {
            logger.warning("Unable to parse JSON-RPC message: \(String(decoding: bytes, as: UTF8.self))")
            return makeErrorResponse(id: .null, code: -32700, message: "Parse error")
        }

        guard let method = MCPMethod(rawValue: methodName) else {
            logger.warning("Unknown method: \(methodName)")
            return makeErrorResponse(id: requestID, code: -32601, message: "Method not found: \(methodName)")
        }

        logger.trace("Received request: method=\(methodName), id=\(requestID)")

        let response: [UInt8]?

        switch method {
        case .initialize:
            response = try await handleInitialize(request: params, id: requestID)
        case .ping:
            response = makeSuccessResponse(id: requestID, result: [String: AnyCodable]())
        case .shutdown:
            // cooperative shutdown (best-effort extension, not part of the MCP
            // spec): the actor processed every request before this one, so the
            // acknowledgement IS the drain guarantee — the caller then sends
            // stdin EOF and this process exits cleanly. peers that do not know
            // the method answer -32601 and both sides keep the EOF path.
            response = makeSuccessResponse(id: requestID, result: [String: AnyCodable]())
        case .toolsList:
            response = try await handleToolsList(id: requestID, caller: caller)
        case .toolsCall:
            response = try await handleToolsCall(params: params, id: requestID, caller: caller)
        case .initialized, .cancelled:
            // These methods are defined as notifications, but a client that
            // sends one with an id has made it a request — JSON-RPC requires
            // a response to every request, so acknowledge with an empty
            // success instead of silently hanging the caller.
            response = makeSuccessResponse(id: requestID, result: [String: AnyCodable]())
        case .resourcesList, .resourcesRead, .promptsList, .promptsGet:
            response = makeErrorResponse(id: requestID, code: -32601, message: "Method not found: \(methodName)")
        }

        return response
    }

    // MARK: - Initialize

    /// Negotiates the response protocol version.
    ///
    /// Echoes the client's requested version when it is supported — the MCP
    /// spec's expectation and what mainstream SDKs verify against the server's
    /// reply — otherwise answers with the newest supported version.
    private func negotiateProtocolVersion(requested: String?) -> String {
        guard let requested, MCPServer.supportedProtocolVersions.contains(requested) else {
            return MCPServer.latestProtocolVersion
        }
        return requested
    }

    /// Handles the `initialize` request.
    ///
    /// Returns server capabilities including the negotiated protocol version
    /// and available features.
    private func handleInitialize(request params: [String: AnyCodable]?, id: JSONRPCID) async throws -> [UInt8] {
        // Lenient: read the requested version straight from the params — clients
        // may omit fields the strict InitializeParams model requires, and only
        // the version string is needed for negotiation.
        let requestedProtocolVersion = params?["protocolVersion"]?.value as? String

        if let params,
           let initParams = try? QuickJSON.decode(InitializeParams.self, from: try QuickJSON.encode(params)) {
            logger.info(
                "Client initialized: \(initParams.clientInfo.name) v\(initParams.clientInfo.version) (protocol \(initParams.protocolVersion))"
            )
        }

        let result = InitializeResult(
            protocolVersion: negotiateProtocolVersion(requested: requestedProtocolVersion),
            capabilities: ServerCapabilities(tools: true),
            serverInfo: ImplementationInfo(name: name, version: version)
        )

        return makeSuccessResponse(id: id, result: result)
    }

    // MARK: - Tools List

    /// Handles the `tools/list` request.
    ///
    /// Builds a list of tool definitions with auto-generated JSON Schema
    /// for each registered tool that the caller has access to.
    private func handleToolsList(id: JSONRPCID, caller: MCPCallerInfo) async throws -> [UInt8] {
        var toolDefinitions: [MCPToolDefinition] = []

        // Dispatcher (macro-generated, typed) catalog first — the generated
        // implementation filters by the caller's access level itself.
        if let dispatcher = toolDispatcher {
            for descriptor in dispatcher.toolCatalog(for: caller.accessLevel) {
                toolDefinitions.append(toolDefinition(from: descriptor))
            }
        }

        for (_, toolType) in snapshotToolTypes() {
            let config = toolType.configuration

            // Filter by access level
            guard caller.accessLevel >= config.requiredAccess else { continue }

            let schema = JSONSchemaBuilder.buildObjectSchema(properties: toolType.discoverParameters())
            toolDefinitions.append(
                MCPToolDefinition(
                    name: toolType.toolName,
                    description: config.description.isEmpty ? nil : config.description,
                    inputSchema: schema
                )
            )
        }

        // Include instance-registered tools
        for (toolName, instance) in snapshotToolInstances() {
            let config = type(of: instance).configuration
            guard caller.accessLevel >= config.requiredAccess else { continue }

            let schema = JSONSchemaBuilder.buildObjectSchema(properties: type(of: instance).discoverParameters())
            toolDefinitions.append(
                MCPToolDefinition(
                    name: toolName,
                    description: config.description.isEmpty ? nil : config.description,
                    inputSchema: schema
                )
            )
        }

        return makeSuccessResponse(id: id, result: ToolsListResult(tools: toolDefinitions))
    }

    /// Converts a compile-time-known tool descriptor into a wire definition.
    private func toolDefinition(from descriptor: MCPToolDescriptor) -> MCPToolDefinition {
        MCPToolDefinition(
            name: descriptor.name,
            description: descriptor.description.isEmpty ? nil : descriptor.description,
            inputSchema: JSONSchemaBuilder.buildObjectSchema(properties: descriptor.parameters)
        )
    }

    // MARK: - Tools Call

    /// Handles the `tools/call` request.
    ///
    /// Finds the requested tool, checks access level, applies the provided
    /// arguments, invokes the tool, and returns the result.
    private func handleToolsCall(
        params: [String: AnyCodable]?,
        id: JSONRPCID,
        caller: MCPCallerInfo
    ) async throws -> [UInt8] {
        guard let params, let toolName = params["name"]?.value as? String else {
            return makeErrorResponse(id: id, code: -32602, message: "Invalid params: missing tool name")
        }

        let arguments = (params["arguments"]?.value as? [String: Any]) ?? [:]

        // Dispatcher (macro-generated, typed) path first: the server keeps
        // authorization policy in one place by reading the tool's required
        // access from the dispatcher, then drops into the exhaustive typed
        // switch for the invocation itself.
        if let dispatcher = toolDispatcher {
            guard let requiredAccess = dispatcher.requiredAccess(named: toolName) else {
                // Unknown to the dispatcher — fall through to the dynamic
                // registry so hybrid servers keep hand-registered tools.
                return await handleToolsCallFromRegistry(
                    id: id, toolName: toolName, arguments: arguments, caller: caller
                )
            }
            guard caller.accessLevel >= requiredAccess else {
                logger.warning("Access denied for tool: \(toolName) (caller level \(caller.accessLevel.rawValue))")
                return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
            }

            return await invokeTool(id: id, toolName: toolName, arguments: arguments, caller: caller) {
                guard let result = try await dispatcher.callTool(
                    named: toolName,
                    arguments: arguments,
                    context: MCPContext(arguments: arguments, callerInfo: caller)
                ) else {
                    throw MCPError.toolNotFound(toolName)
                }
                return result
            }
        }

        return await handleToolsCallFromRegistry(id: id, toolName: toolName, arguments: arguments, caller: caller)
    }

    /// Resolves a tool through the dynamic registry (type- or instance-path).
    private func handleToolsCallFromRegistry(
        id: JSONRPCID,
        toolName: String,
        arguments: [String: Any],
        caller: MCPCallerInfo
    ) async -> [UInt8] {
        if let toolType = toolType(named: toolName) {
            guard caller.accessLevel >= toolType.configuration.requiredAccess else {
                logger.warning("Access denied for tool: \(toolName) (caller level \(caller.accessLevel.rawValue))")
                return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
            }

            return await invokeTool(id: id, toolName: toolName, arguments: arguments, caller: caller) {
                var tool = toolType.init()
                try tool.apply(arguments: arguments)
                let context = MCPContext(arguments: arguments, callerInfo: caller)
                return try await tool.invoke(context: context)
            }
        } else if let instance = toolInstance(named: toolName) {
            guard caller.accessLevel >= type(of: instance).configuration.requiredAccess else {
                logger.warning("Access denied for instance tool: \(toolName) (caller level \(caller.accessLevel.rawValue))")
                return makeErrorResponse(id: id, code: -32000, message: "Access denied: \(toolName)")
            }

            return await invokeTool(id: id, toolName: toolName, arguments: arguments, caller: caller) {
                var mutableInstance = instance
                try mutableInstance.apply(arguments: arguments)
                let context = MCPContext(arguments: arguments, callerInfo: caller)
                return try await mutableInstance.invoke(context: context)
            }
        } else {
            return makeErrorResponse(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
    }

    /// Applies arguments, invokes a tool, and maps the outcome to a response.
    ///
    /// Client faults — missing or mistyped arguments — are protocol errors
    /// (`-32602` Invalid params). Failure inside the tool's own execution,
    /// however, is reported as a result with `isError: true` per the MCP
    /// spec's Error Handling section, not as a JSON-RPC error.
    private func invokeTool(
        id: JSONRPCID,
        toolName: String,
        arguments: [String: Any],
        caller: MCPCallerInfo,
        invocation: () async throws -> MCPToolResult
    ) async -> [UInt8] {
        do {
            let result = try await invocation()
            return makeSuccessResponse(id: id, result: ToolsCallResult(content: result.content, isError: result.isError))
        } catch let error as MCPError {
            switch error {
            case .missingArgument, .typeMismatch, .toolNotFound:
                logger.warning("Tool \(toolName) rejected arguments: \(error.description)")
                return makeErrorResponse(id: id, code: -32602, message: error.description)
            default:
                logger.warning("Tool \(toolName) failed: \(error.description)")
                return makeErrorResponse(id: id, code: -32603, message: error.description)
            }
        } catch {
            let message = readableErrorDescription(error)
            logger.warning("Tool \(toolName) execution error: \(message)")
            return makeSuccessResponse(
                id: id,
                result: ToolsCallResult(content: [.text(message)], isError: true)
            )
        }
    }

    // MARK: - Helpers

    /// The first byte of `bytes`, skipping ASCII whitespace, or `nil` if the
    /// payload is empty or only whitespace. Used to classify the top-level
    /// JSON shape (object vs array) without a full decode.
    private func firstNonWhitespaceByte(of bytes: [UInt8]) -> UInt8? {
        for byte in bytes {
            if byte != 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D {
                return byte
            }
        }
        return nil
    }

    /// Extracts the request id from a decoded object envelope so an error
    /// response can echo a valid string/number id. Returns `nil` when the id
    /// is absent or is not a legal JSON-RPC id (bool, array, object).
    private func envelopeID(from envelope: [String: AnyCodable]) -> JSONRPCID? {
        guard let id = envelope["id"] else { return nil }
        guard let encoded = try? QuickJSON.encode(id) else { return nil }
        return try? QuickJSON.decode(JSONRPCID.self, from: encoded)
    }

    /// Encodes a JSON-RPC success response.
    private func makeSuccessResponse<Result: Encodable & Sendable>(id: JSONRPCID, result: Result) -> [UInt8] {
        do {
            return try QuickJSON.encode(JSONRPCResponse(id: id, result: result))
        } catch {
            logger.error("Failed to encode success response: \(error)")
            return makeErrorResponse(id: id, code: -32603, message: "Internal error: failed to encode response")
        }
    }

    /// Encodes a JSON-RPC error response.
    private func makeErrorResponse(id: JSONRPCID, code: Int, message: String) -> [UInt8] {
        do {
            return try QuickJSON.encode(JSONRPCErrorResponse(id: id, code: code, message: message))
        } catch {
            // A fixed-shape error frame cannot realistically fail to encode.
            logger.critical("Failed to encode error response: \(error)")
            return []
        }
    }
}
