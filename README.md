# Jaaga (ಜಾಗ)

> ### 🚧 Under construction
>
> Jaaga is early and unfinished. It is published so the work is visible, not because it is ready.
> Expect rough edges, breaking changes to the daemon protocol, and builds that are **unsigned and not
> notarized**. Nothing here is a release you should rely on yet.

A macOS disk space explorer. *Jaaga* is Kannada for "space".

It shows you which folders are actually filling your Mac — as a colourful map you can click into, a
list of the usual suspects that grow quietly (Xcode's DerivedData, simulator devices, `~/Library/Caches`,
Docker's disk image, `node_modules` across your projects, old installers in Downloads), and a watch
list that tells you when a folder starts growing faster than it usually does. Everything it measures is
the **allocated** size — what you actually get back by deleting it — and the only thing it ever removes
is a move to the Trash, after you confirm.

Two pieces: a background **daemon** that does all the measuring, and a **SwiftUI app** that only draws
what the daemon reports. A CLI and an MCP server are meant to be added later as ordinary clients of the
same socket protocol.

---

## Building

Requires macOS 15 or later and Xcode 16 or later (Swift 6.1+).

```sh
swift build            # everything
swift test             # 118 tests
```

To produce a runnable `Jaaga.app`:

```sh
Scripts/bundle-app.sh                  # release, into .build/release/Jaaga.app
Scripts/bundle-app.sh --configuration debug
open .build/release/Jaaga.app
```

The script assembles the bundle the way an Xcode app target would — app executable, the daemon, the
resource bundles, `Info.plist`, the LaunchAgent plist — and ad-hoc signs it. There is no `.xcodeproj`;
the whole thing is one Swift package.

## Running it

Launch `Jaaga.app`. On first run the app registers the daemon as a per-user LaunchAgent with
`SMAppService`, and launchd keeps it running from then on — which is what lets it keep watched folders
up to date while the app is closed.

macOS may show the registration under **System Settings › General › Login Items & Extensions**. You can
turn it off there; the app will fall back to running the daemon itself.

**Development fallback.** `SMAppService` needs a signed bundle. If registration is refused, the app
launches the bundled `jaagad` as a child process instead and says so — everything works, but the daemon
stops when the app does. You can also run the daemon by hand:

```sh
swift run jaagad                 # listens on ~/Library/Application Support/Jaaga/jaagad.sock
swift run jaagad --help
swift run jaagad --home /tmp/sandbox --no-fsevents   # against a throwaway tree
```

The app connects to an already-running daemon if it finds one.

## Full Disk Access

Without it, parts of your home folder are unreadable and the totals would be short. Jaaga never hides
that: a folder it cannot open is listed under the total, and the interface says the number is a lower
bound. But you will want to grant it.

**System Settings › Privacy & Security › Full Disk Access →** add `Jaaga.app`, and add `jaagad` too if
you are running the daemon by hand from a terminal. Restart the app afterwards.

macOS will also ask separately the first time Jaaga reads folders it protects individually — your
Music library, Photos, Desktop, Documents and Downloads. Declining is fine; those folders then show up
as unreadable rather than being silently left out of the total.

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

The protocol is documented in [`docs/protocol.md`](docs/protocol.md) — enough to write a client in any
language, including how sizes are measured and how the suspects catalog is defined.

The daemon keeps its state in `~/Library/Application Support/Jaaga/`: the socket, `watched.json` (the
starred folders and their size history), and an optional `suspects.json` of your own catalog rules.

## Not done yet

The CLI. The MCP server. Dark appearance. App Store sandboxing. Signing and notarization. Aggregating
across volumes beyond listing them.
