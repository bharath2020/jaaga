# Developing Jaaga

## How it is put together

```
Jaaga.app  ──── JSON over a Unix domain socket ────▶  jaagad
(renderer)                                            (all the measuring)
                                                         │
     a CLI, an MCP server: same socket, same protocol ────┘  (not built yet)
```

| Target | |
|---|---|
| `JaagaProtocol` | The wire protocol and the shared data model, plus a reference client. No filesystem code |
| `JaagaCore` | Allocated-size scanning, the usual-suspects catalog, verdict rules, watched-folder history |
| `JaagaLayout` | Pure presentation maths: squarified treemap, size and date formatting |
| `JaagaDaemon` | The socket server and request router |
| `jaagad` | The daemon executable |
| `JaagaApp` | The SwiftUI window. Depends on `JaagaProtocol` and `JaagaLayout` only, so it *cannot* walk the filesystem |

`Scripts/bundle-app.sh` assembles `Jaaga.app` the way an Xcode app target would — app executable, the
daemon, the resource bundles, `Info.plist`, the LaunchAgent plist — and ad-hoc signs it. There is no
`.xcodeproj`; the whole thing is one Swift package. `--configuration debug` builds a debug bundle.

The protocol is documented in [`protocol.md`](protocol.md) — enough to write a client in any language,
including how sizes are measured and how the suspects catalog is defined.

The daemon keeps its state in `~/Library/Application Support/Jaaga/`: the socket, `watched.json` (the
starred folders and their size history), and an optional `suspects.json` of your own catalog rules.

## Running the daemon

On first run the app registers the daemon as a per-user LaunchAgent with `SMAppService`, and launchd
keeps it running from then on — which is what lets it keep watched folders up to date while the app is
closed. macOS may show it under **System Settings › General › Login Items & Extensions**; turning it
off there makes the app fall back to running the daemon itself.

`SMAppService` needs a signed bundle. If registration is refused, the app launches the bundled `jaagad`
as a child process instead and says so — everything works, but the daemon stops when the app quits.
The app connects to an already-running daemon if it finds one.

```sh
swift run jaagad                 # listens on ~/Library/Application Support/Jaaga/jaagad.sock
swift run jaagad --home /tmp/sandbox --no-fsevents   # against a throwaway tree
```

## Working against a test tree

Scanning your real home on every rebuild is slow, so both halves take a `JAAGA_HOME` override
(`NSHomeDirectory()` ignores `$HOME` for a GUI app, hence the separate variable). Keep the path short —
a Unix socket address has only 103 bytes to work with.

```sh
JAAGA_HOME=/tmp/jaaga-test open -a .build/release/Jaaga.app   # or run the executable directly
```

## Full Disk Access, in more detail

Until it is granted, expect roughly 150 protected folders inside `~/Library` to come back unreadable.
Jaaga shows those sizes as "At least 237.7 GB" with a lock beside them and a note saying how many
folders it could not open — it will not print a number that looks exact when it is not.

macOS also asks separately the first time Jaaga reads folders it protects individually — Music, Photos,
Desktop, Documents and Downloads. Declining is fine; those folders then show up as unreadable rather
than being silently left out of the total.

## Not done yet

The CLI. The MCP server. Dark appearance. App Store sandboxing. Signing and notarization. Aggregating
across volumes beyond listing them.
