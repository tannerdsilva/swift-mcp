# One-Shot Stdin Tools

Ship a tool binary whose harness protocol is as easy to declare as an argv CLI.

## Overview

An argv tool declares its surface with `swift-argument-parser`; a stdin tool
declares exactly the same surface with swift-mcp — the same property wrappers
(`@Argument`, `@Option`, `@Flag`, `@OptionGroup`), the same JSON Schema
generation, and the same typed dispatch, all compile-time.

The difference is only the binary's *shape*. Pass `interface: .oneShot` to
`@MCPApplication` and the generated `main()` becomes an ``MCPStdinHost``: the
process answers harness frames over stdin/stdout, serves its own
self-description, and exits — no session, no handshake.

```swift
import MCP

@MCPApplication(description: "Greet someone by name", name: "greet")
struct Greet {
    @Argument(description: "The name of the person to greet")
    var name: String = ""

    func run() async throws -> String {
        "Hello, \(name)!"
    }
}

@main
@MCPApplication(name: "my-tool", version: "1.0.0", interface: .oneShot)
struct MyTool {
    @Tool var greet = Greet()
}
```

One declaration. The binary then serves all three faces below, and describes
itself, with no hand-written envelope, dispatch table, or manifest code.

> The repository's compiled end-to-end fixture (`MCPFixtureTool`) is exactly
> this shape; the test suite drives every face on this page against it as a
> real spawned process.

## The faces

### The plugin envelope

Harnesses that spawn one process per call drive the binary with a single JSON
object; the result is a single JSON object. This is the ``MCPPluginDialect``:

```jsonc
// stdin:  {"tool":"greet","args":{"name":"Ada"}}
// stdout: {"result":"Hello, Ada!"}
```

Tool failures arrive as text, never as exit codes — the harness contract has
no error envelope:

```jsonc
// stdin:  {"tool":"greet","args":{}}        (with a required argument missing)
// stdout: {"result":"Error: missing required argument 'name'"}
```

The plugin dialect **completes after the first request**: the process answers
and exits even if the harness holds stdin open, so a stdin-holding caller can
never hang the invocation.

### JSON-RPC

The same binary is an MCP endpoint over the engine's native wire
(``MCPJSONRPCDialect``). Requests are answered as they arrive; the session
ends at stdin EOF:

```jsonc
// stdin:  {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Ada"}}}
// stdout: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Hello, Ada!"}],"isError":false}}
```

No `initialize` is required — stateless `tools/call` is served directly — and
the routing, error classification, and access gates are byte-for-byte the
session server's, because both drive the one `MCPMessageRouter`.

### Introspection

The binary describes itself from its compiled surface, without reading stdin:

```bash
$ my-tool --mcp-list
{"description":"…","name":"my-tool","tools":[{"description":"…","inputSchema":{…},"name":"greet"}],"version":"1.0.0"}

$ my-tool --mcp-manifest arc
{"description":"…","name":"my-tool","tools":[{"args":[],"command":"/usr/local/bin/my-tool","description":"…","name":"greet","schema":{…},"toolset":"my-tool"}],"version":"1.0.0"}

$ my-tool --mcp-manifest arc-pretty
{
  "description" : "…",
  "name" : "my-tool",
  "tools" : [ { "args" : [], "command" : "/usr/local/bin/my-tool", … } ],
  "version" : "1.0.0"
}

$ my-tool --mcp-describe greet
{"description":"…","inputSchema":{…},"name":"greet"}

$ my-tool --version
{"version":"1.0.0"}
```

`--mcp-list` emits the ``MCPToolCatalog``; `--mcp-describe <tool>` emits that one
tool's ``MCPToolCatalog/Tool`` object, so an agent fetches a single schema
instead of the whole catalog; `--version` emits the binary's version.
`--mcp-manifest <name>` renders the catalog
through a ``MCPToolManifestFormat`` — the arc format (``ArcPluginManifest``)
ships first, and a consumer with its own harness adds a conformance instead of
patching the framework.

Manifests are deterministic and **compact**: sorted keys at every depth and no
insignificant whitespace, because a harness reads these bytes on every load, so
their size is a token cost. The two-space pretty form a human reviews is the
same format under its own name, ``ArcPluginManifest/Pretty``
(`--mcp-manifest arc-pretty`); the name **is** the opt-in, and the two spellings
decode to the same document.

Every introspection flag bypasses the transport entirely and reads no stdin, so
they work even when the standard streams are redirected to files. A request
that cannot be served — `--mcp-manifest` naming an unserved format,
`--mcp-describe` naming a tool the compiled surface does not carry — exits `1`
with one diagnostic line on stderr and nothing on stdout.

## Results

A tool's return value is rendered by its shape, resolved at compile time:

- `String` — verbatim. A JSON document you return stays a JSON document rather
  than becoming a quoted string.
- any `Encodable` type — compact canonical JSON, so a structured return arrives
  as a document the caller can decode.
- anything else — `String(describing:)`.

The plugin envelope places it under `result`; JSON-RPC wraps it in the standard
`content` array with `isError`.

## Dialects

A dialect is a **pure byte transcoder** (``MCPStdinDialect``): it recognizes a
harness frame, rewrites it to JSON-RPC for the one router, and rewrites the
response back. Dialects never interpret call semantics — so the facade and the
server cannot drift.

- ``MCPPluginDialect`` — the `{"tool","args"}` envelope; completes after the
  first request.
- ``MCPJSONRPCDialect`` — byte identity; the router classifies every frame
  (including malformed bytes), exactly like the session server.

The first frame pins the dialect in detection order (plugin first, JSON-RPC
second, by default); later frames the pinned dialect does not recognize still
reach the router. Custom dialects plug in through the protocol.

## The exit contract

| exit | meaning |
|---|---|
| `0` | a response was written for every request, or introspection was emitted |
| `1` | no dialect recognized the first frame, stdin was empty, a frame failed to transcode, or an introspection request could not be served — one diagnostic line on stderr, nothing on stdout |

Tool-level failures are *results* (`isError`, `Error: …` text), never exit
codes: harnesses read stdout, not status. ``MCPStdinHost/runMain()`` maps the
contract onto the process, which is what the generated `main()` calls.

## Requirements and limits

- **Standard streams must be pipes.** The NIO pipe channel that carries stdin
  rejects regular files, so `my-tool > out.json` fails *before* the transport
  starts: exit `1`, nothing on stdout, and one stderr line naming the offending
  stream and descriptor
  (``MCPStdinHostError/standardStreamIsNotAPipe(stream:descriptor:)``).
  Harnesses always spawn with pipes, and the introspection flags bypass the
  transport entirely (redirect them freely).
- **An unterminated frame is invisible.** The transport hands over complete
  frames only: a producer that never writes the terminating newline never
  delivers a frame, and an open stream is never observed as EOF, so the process
  waits with nothing on either stream. `MCPStdinHost.Configuration.firstFrameTimeout`
  bounds that wait — exit `1` with ``MCPStdinHostError/noFrameWithinDeadline``.
  The default (`nil`) waits indefinitely, because a session-shaped peer may
  legitimately idle.
- **One frame per spawn is the convention.** Pipelined frames enter the engine
  in arbitrary order (they are independent tasks, paired by JSON-RPC id) — the
  same contract the session server documents.
- **Mixed imports.** `import MCP` and `import ArgumentParser` in one file
  collide on the wrapper names (`@Argument`, `@Option`, `@Flag`,
  `@OptionGroup`). Declare one-tool-two-languages binaries in separate files,
  importing each framework where it is used.

## Topics

### Authoring a fleet

- <doc:ToolPacks>

### Declaring a tool binary

- ``MCPInterface``
- ``MCPStdinHost``
- ``MCPStdinHostError``

### Wire dialects

- ``MCPStdinDialect``
- ``MCPPluginDialect``
- ``MCPJSONRPCDialect``

### Self-description

- ``MCPToolCatalog``
- ``MCPToolManifestFormat``
- ``MCPManifestContext``
- ``ArcPluginManifest``