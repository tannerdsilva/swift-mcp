# MCP Protocol Support

This document describes the MCP (Model Context Protocol) methods supported by swift-mcp.

## Protocol Version

The server advertises protocol version `2025-06-18`.

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

Sent by the client after initialization. Acknowledged (no response).

### notifications/cancelled

Sent by the client to cancel a pending request. Acknowledged (no response).

## Error Codes

| Code | Meaning |
|---|---|
| -32700 | Parse error (a frame that is not valid JSON-RPC) |
| -32000 | Access denied (`tools/call` for a tool above the caller's level) |
| -32601 | Method not found |
| -32602 | Invalid params (missing tool name, unknown tool) |
| -32603 | Internal error (tool execution failure, argument type mismatch) |

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
