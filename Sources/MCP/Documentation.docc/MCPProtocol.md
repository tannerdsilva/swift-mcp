# MCP Protocol Support

This document describes the MCP (Model Context Protocol) methods supported by swift-mcp.

## Protocol Version

The server negotiates its protocol version from the client's `initialize` request:
it supports `2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25`, and
echoes the client's requested version when it is in that set — otherwise it
answers with its newest supported version (`2025-11-25`).

## Message Format

All messages use JSON-RPC 2.0 with newline-delimited framing.

### Request

```json
{"jsonrpc":"2.0","id":1,"method":"tools/list"}
```

### Response

```json
{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
```

### Notification (no response expected)

```json
{"jsonrpc":"2.0","method":"notifications/initialized"}
```

## Supported Methods

### initialize

Server capability advertisement.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {
      "name": "my-client",
      "version": "1.0.0"
    }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": {}
    },
    "serverInfo": {
      "name": "my-server",
      "version": "1.0.0"
    }
  }
}
```

### ping

Health check. Returns an empty result.

**Request:**
```json
{"jsonrpc":"2.0","id":1,"method":"ping"}
```

**Response:**
```json
{"jsonrpc":"2.0","id":1,"result":{}}
```

### tools/list

List all registered tools with their JSON Schema.

**Request:**
```json
{"jsonrpc":"2.0","id":1,"method":"tools/list"}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "name": "greet",
        "description": "Greet someone by name",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "The person to greet"
            },
            "count": {
              "type": "integer",
              "description": "Number of times"
            },
            "formal": {
              "type": "boolean",
              "description": "Use a formal greeting"
            }
          },
          "required": ["name"]
        }
      }
    ]
  }
}
```

### tools/call

Invoke a tool with arguments.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "greet",
    "arguments": {
      "name": "World",
      "count": 2,
      "formal": true
    }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Greetings, World!\nGreetings, World!"
      }
    ],
    "isError": false
  }
}
```

### notifications/initialized

Sent by the client after initialization. Acknowledged (no response) when sent as a
notification. A client that sends it with an `id` gets an empty success response —
JSON-RPC requires a response to every request, so the server never hangs a caller.

### notifications/cancelled

Sent by the client to cancel a pending request. The server routes it to the
in-flight `tools/call` invocation for that request id and cancels its task: the
tool is stopped at its next cooperative suspend point (`Task.sleep`,
SwiftSlash subprocess awaits, and other suspension-aware work) and the server
reports the outcome as an `isError` result for any listener still present.
Cancelling a finished or unknown request id is a no-op.

The `MCPClient` emits this automatically when a per-call deadline expires, so a
timed-out call does not leave the server executing the tool unbounded. Like
`notifications/initialized`, the notification form gets no response, and a
client that sends it as a request with an `id` gets an empty success response.

> Note: cooperative cancellation only — a tool that never suspends (pure CPU
> work) observes the cancellation at its next `await`, and a server handling
> messages FIFO per connection processes the notification on a parallel path so
> it is not parked behind the very call it interrupts.

## Error Codes

| Code | Meaning |
|---|---|
| -32700 | Parse error (a frame that is not valid JSON) |
| -32600 | Invalid Request (malformed frame, wrong `jsonrpc` version, invalid id value) |
| -32000 | Access denied (`tools/call` for a tool above the caller's level) |
| -32601 | Method not found |
| -32602 | Invalid params (missing tool name, unknown tool, missing or mistyped arguments) |
| -32603 | Internal error (server-side fault) |

A tool that fails while *executing* is not a JSON-RPC error: per the spec's Error
Handling section, the server returns a result with `isError: true` carrying the
error message as text content.

## Batches and Null IDs

- A top-level JSON array is a JSON-RPC batch: each element is routed like a
  single message and the non-nil responses are returned as one array in request
  order. An empty batch is an Invalid Request (`-32600`); a batch whose elements
  are all notifications gets no response.
- A request with `"id": null` is answered with `"id": null`. JSON-RPC 2.0
  discourages (but permits) null ids — an id must be a String, Number, or NULL —
  and every request must be answered, so the server never hangs such a caller.

## Content Blocks

`tools/call` results carry an array of content blocks. Text and image blocks
encode their payload directly; resource blocks use the spec's `EmbeddedResource`
shape:

```json
{
  "type": "resource",
  "resource": { "uri": "file:///x", "mimeType": "text/plain", "text": "hi" }
}
```

## Not Yet Implemented

- `resources/list`, `resources/read` — Resource exposure
- `prompts/list`, `prompts/get` — Prompt templates
- HTTP+SSE transport
- Streaming responses
- Progress notifications
