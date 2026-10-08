# Tool Packs

Author a fleet of one-shot tools as one binary, and install it where a harness
finds it by name.

## Overview

A **pack** is a single `@MCPApplication(interface: .oneShot)` binary that
exposes N tools. The harness spawns that one binary, passes a
``MCPPluginDialect`` envelope naming the tool, and reads a result — no
interpreter, no per-tool process, no Python in the path.

The economics are the point. A process-per-call harness spawns a process for
every invocation, so one binary per tool means N binaries to build, install,
register, and keep current — and N manifests that drift from their binaries
independently. A pack pays that once:

| per tool | per pack |
|---|---|
| one declaration (`@MCPCommand` struct or `@FuncTool` function) and one `@Tool` property | one executable target |
| — | one install (copy, manifest, registration) |

Twelve tools cost about twelve declarations, not twelve targets. See
<doc:StdinTools> for the tool-binary protocol itself — this article is about
authoring and deploying several of them as one unit.

> The repository ships two compiled reference packs: `MCPToolPack` (twelve
> tools spanning every return shape the facade supports) and `MCPTwoFilePack`
> (the two-file layout with an argv front door). Both are driven as real
> spawned processes by the test suite, so the patterns below are
> regression-tested rather than aspirational.

## A pack's shape

The single-file pack is the default, and it is short:

```swift
import MCP

@MCPCommand(description: "Count characters, words, and lines", name: "text_stats")
struct TextStats {
    @Argument(description: "The text to measure")
    var text: String = ""

    // Any `Encodable` return renders as compact JSON; `String` stays verbatim.
    func run() async throws -> TextStatsResult { … }
}

@main
@MCPApplication(
    name: "my-pack",
    version: "1.0.0",
    description: "Reference tool pack: twelve tools in one shim-less one-shot binary",
    interface: .oneShot
)
struct MyPack {
    @Tool var textStats = TextStats()
    @Tool var echo = Echo()
    // … N tools, one line each …
}
```

`interface: .oneShot` makes the generated `main()` an ``MCPStdinHost``: the
process answers harness frames, serves its own self-description, and exits.
The macro generates the `ToolID` enum, the exhaustive switch, the catalog
entry, and the access gate for every `@Tool` property at compile time.

### When the entry is not the binary root

If the one-shot entry sits behind a subcommand — `<bin> plugin` — the harness
invokes the binary with that argument, and the manifest has to say so. The
`@MCPApplication` attribute carries it:

```swift
@MCPApplication(
    name: "my-pack",
    version: "1.0.0",
    interface: .oneShot,
    manifestInvocationArguments: ["plugin"]   // harness spawns `<bin> plugin`
)
```

Without it, the generated manifest advertises `args: []` and a harness calls
the binary bare, where the subcommand is missing. The value is baked into the
generated `main()`'s host configuration, so it stays a compile-time fact rather
than a hand-maintained manifest.

Only hand-write `main` when the pack really is a CLI — see the two-file layout
below, whose `PackCLI` root owns the front door and hands the host its
arguments. In that shape the `@MCPApplication` struct carries **no** `@main`
and no `interface:`; the macro still generates the whole dispatch surface, and
only the generated `main()` goes unused.

## The two-file rule

`import MCP` and `import ArgumentParser` both declare `@Argument`, `@Option`,
`@Flag`, and `@OptionGroup`. A file that imports both fails to compile —
`'Argument' is ambiguous for type lookup in this context` — and the error
cascades into `does not conform to protocol 'ParsableCommand'` on every
command. So a pack that wants an argv front door splits:

| file | holds | imports |
|---|---|---|
| `PackTools.swift` | the `@MCPCommand` tool structs and the `@MCPApplication` dispatcher surface | `MCP` |
| `PackEntry.swift` | the `AsyncParsableCommand` root, the `plugin` subcommand, the hand-wired host | `ArgumentParser` + a **selective** MCP import |

Name only what the entry file needs:

```swift
import ArgumentParser
import struct MCP.MCPStdinHost
```

The `plugin` subcommand must capture its trailing tokens rather than reject
them, because the host's introspection flags (`--mcp-list`,
`--mcp-manifest <fmt>`) still have to reach ``MCPStdinHost``:

```swift
@Argument(parsing: .captureForPassthrough)
var hostArguments: [String] = []
```

and its `run()` reconstructs `argv[0]` as the **real executable path**, because
the manifest resolves `command` from it — an absolute path is kept verbatim, a
bare name is searched along `PATH` and may not be found:

```swift
let arguments = [CommandLine.arguments.first ?? "my-pack"] + hostArguments
await MCPStdinHost(
    name: "my-pack", version: "1.0.0",
    dispatcher: PackTools(),
    configuration: .init(arguments: arguments, manifestInvocationArguments: ["plugin"])
).runMain()
```

Two CLI rules are load-bearing, not stylistic. The root must be
`AsyncParsableCommand`: an async subcommand under a **synchronous** root is
refused at runtime and its `run()` is silently never called. And every
introspection flag must reach the host — a root that parses them itself turns
`--mcp-list` into an unknown-option error.

## Install contract

The framework ships no installer. What it guarantees is that a correctly
installed pack describes itself correctly; the recipe a pack's own install
script must follow has three steps, and each one has a failure mode it exists
to prevent.

```bash
PACK=my-pack
BIN_DIR="$HOME/.hermes/profiles/<profile>/bin"   # a profile's own bin/, on that profile's PATH

# 1. build, then COPY the binary (never symlink)
swift build -c release
install -m 755 ".build/release/$PACK" "$BIN_DIR/$PACK"

# 2. generate the manifest from the INSTALLED binary, not the build product
mkdir -p "$HOME/.arc/plugins/$PACK"
"$BIN_DIR/$PACK" --mcp-manifest arc > "$HOME/.arc/plugins/$PACK/manifest.json"

# 3. register it with the harness (config-driven; a directory is not enough)
hermes plugins enable "$PACK"
```

**Copy, never symlink.** A symlink into `.build/` dies with the next clean
build or source move, and `install`/`cp` write *through* an existing symlink at
the destination, so a "copy" install silently stays a symlink unless the
destination is removed first.

**Generate the manifest from the installed binary.** Every entry's `command`
field is the absolute path of the process that emitted it (resolved from
`argv[0]`), and `args` comes from the host's `manifestInvocationArguments`. So
running the build product produces a manifest pointing at `.build/` — a path
that will not exist for the harness. Run the installed copy, and the manifest
is correct by construction.

**Register per profile.** A named harness profile owns its own `bin/` and
`plugins/` directories, and only the active profile's are on its `PATH`.
Install into each profile that should see the pack. Registration is
config-driven: dropping a directory into `plugins/` does not enable anything,
and a newly enabled plugin takes effect on the **next** session — there is no
live reload.

Two pitfalls worth stating plainly, both verified the hard way:
`[ ! -w "$DIR" ]` is *true* for a **missing** directory, so a naive installer
escalates to `sudo` on a fresh machine and then fails non-interactively; and an
uninstaller that sweeps canonical directories in addition to its `--prefix`
will delete a real install during a sandboxed test — sandbox `HOME`, not just
the prefix.

## One-shot or session?

The one-shot facade is the right shape for a **stateless, bounded** call: one
frame in, one result out, process exits. A harness caps a spawn (arc's is 60
seconds), and ``MCPPluginDialect`` deliberately completes after the first
request so a stdin-holding caller cannot hang the invocation.

Anything long-running, stateful, or multi-call belongs in a **session** server
(``MCPServer`` via a `ServiceGroup`) that the harness reaches through a client
(``MCPClient``). Pushing a session-shaped tool into a one-shot binary produces
a process that outlives its useful answer or gets killed mid-work.

There is one stall the facade will not diagnose by itself: a producer that
never terminates its frame with a newline never delivers a frame, and an open
stream is never observed as EOF — so the process waits with nothing on either
stream. Set `MCPStdinHost.Configuration.firstFrameTimeout` to bound it; the
host then records ``MCPStdinHostError/noFrameWithinDeadline`` and exits `1`
with a diagnostic instead of hanging.

## Verification ladder

A pack is verified at four levels, cheapest first. The spawn harness these
tests share is exported as the **MCPToolTestKit** library target
(`SpawnedTool.spawn(path:arguments:environment:)`, a `ToolExit`, `drain(fd:)`,
`pluginFrame(tool:args:)`), so a pack's spawned end-to-end test is about ten
lines instead of a re-copied hundred.

1. **Tool unit tests** — call `run()` directly; the declaration's surface is
   already compile-checked by the macro.
2. **Spawned end-to-end** — spawn the built binary and drive a real envelope
   through it. This is the level that catches what an in-process call cannot:
   framing, the exit contract, and the preflight.
3. **Manifest determinism** — run `--mcp-manifest arc` twice and compare bytes;
   canonical output makes this an exact assertion rather than a normalization
   step.
4. **Id pairing** — for pipelined JSON-RPC frames, assert each response carries
   its request's id. Pipelined frames enter the engine as independent tasks in
   arbitrary order; the id is the only thing pairing them.

## Platform floor

The facade requires **macOS 15**. The core is Foundation-free and the
concurrency primitives (`Synchronization.Mutex`) set the floor; Linux is
supported with no platform-specific code in the pack path. Standard streams
must be pipes — the NIO pipe channel rejects regular files, so `my-pack >
out.json` fails at transport setup with a named diagnostic
(``MCPStdinHostError/standardStreamIsNotAPipe(stream:descriptor:)``), while the
introspection flags bypass the transport and redirect freely.

## Topics

- ``MCPInterface``
- ``MCPStdinHost``
- ``MCPStdinHostError``
- ``MCPToolCatalog``
- ``MCPToolManifestFormat``
- ``MCPManifestContext``
- ``ArcPluginManifest``