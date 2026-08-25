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

/// An address that an MCP server can bind to.
///
/// ``ServerAddress`` specifies the network address and port (or Unix domain
/// socket path) that the server should listen on. It supports IPv4, IPv6,
/// dual-stack, and Unix domain socket bindings.
///
/// ## IPv4
///
/// ```swift
/// // Bind to a specific IPv4 address
/// let addr = ServerAddress.hostname("127.0.0.1", port: 8080)
///
/// // Bind to all IPv4 interfaces
/// let addr = ServerAddress.hostname("0.0.0.0", port: 8080)
/// ```
///
/// ## IPv6
///
/// ```swift
/// // Bind to a specific IPv6 address
/// let addr = ServerAddress.hostname("::1", port: 8080)
///
/// // Bind to all IPv6 interfaces (dual-stack on supporting systems)
/// let addr = ServerAddress.hostname("::", port: 8080)
/// ```
///
/// ## Dual-Stack
///
/// On macOS and Darwin platforms, binding to `::` (all IPv6 interfaces)
/// automatically enables dual-stack mode, accepting both IPv4 and IPv6
/// connections. On Linux, you may need to explicitly disable `IPV6_V6ONLY`.
///
/// ## Unix Domain Socket
///
/// ```swift
/// let addr = ServerAddress.unixDomainSocket(path: "/tmp/mcp.sock")
/// ```
public struct ServerAddress: Sendable, Equatable {

    /// The internal representation of a server address.
    public enum Value: Sendable, Equatable {
        /// Bind to a hostname and port.
        case hostname(host: String, port: Int)
        /// Bind to a Unix domain socket path.
        case unixDomainSocket(path: String)
    }

    /// The underlying address value.
    public let value: Value

    /// Creates a server address from an internal value.
    init(_ value: Value) {
        self.value = value
    }

    /// Creates an address that binds to a hostname and port.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address. Common values:
    ///     - `"127.0.0.1"` — localhost IPv4 only
    ///     - `"0.0.0.0"` — all IPv4 interfaces
    ///     - `"::1"` — localhost IPv6 only
    ///     - `"::"` — all IPv6 interfaces (dual-stack on supporting systems)
    ///   - port: The TCP port number (0–65535).
    /// - Returns: A server address configured for TCP binding.
    public static func hostname(_ host: String, port: Int) -> ServerAddress {
        ServerAddress(.hostname(host: host, port: port))
    }

    /// Creates an address that binds to a Unix domain socket.
    ///
    /// - Parameter path: The file system path for the Unix domain socket.
    /// - Returns: A server address configured for Unix domain socket binding.
    public static func unixDomainSocket(path: String) -> ServerAddress {
        ServerAddress(.unixDomainSocket(path: path))
    }
}

// MARK: - Convenience Addresses

extension ServerAddress {
    /// Binds to localhost IPv4 only (`127.0.0.1`).
    /// - Parameter port: The port number.
    /// - Returns: A server address for localhost IPv4.
    public static func localhostIPv4(port: Int = 8080) -> ServerAddress {
        .hostname("127.0.0.1", port: port)
    }

    /// Binds to localhost IPv6 only (`::1`).
    /// - Parameter port: The port number.
    /// - Returns: A server address for localhost IPv6.
    public static func localhostIPv6(port: Int = 8080) -> ServerAddress {
        .hostname("::1", port: port)
    }

    /// Binds to all IPv4 interfaces (`0.0.0.0`).
    /// - Parameter port: The port number.
    /// - Returns: A server address for all IPv4 interfaces.
    public static func allInterfacesIPv4(port: Int = 8080) -> ServerAddress {
        .hostname("0.0.0.0", port: port)
    }

    /// Binds to all IPv6 interfaces (`::`), enabling dual-stack on supporting systems.
    /// - Parameter port: The port number.
    /// - Returns: A server address for all IPv6 interfaces (dual-stack).
    public static func allInterfacesIPv6(port: Int = 8080) -> ServerAddress {
        .hostname("::", port: port)
    }
}

// MARK: - CustomStringConvertible

extension ServerAddress: CustomStringConvertible {
    /// A human-readable description of the address.
    public var description: String {
        switch value {
        case .hostname(let host, let port):
            // Format IPv6 addresses with brackets
            if host.contains(":") {
                return "[\(host)]:\(port)"
            }
            return "\(host):\(port)"
        case .unixDomainSocket(let path):
            return "unix:\(path)"
        }
    }
}
