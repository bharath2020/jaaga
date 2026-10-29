# Jaaga (ಜಾಗ)

> ### 🚧 Under construction
>
> Jaaga is early and unfinished. It is published so the work is visible, not because it is ready.
> Expect rough edges, breaking changes to the daemon protocol, and builds that are **unsigned and not
> notarized**. Nothing here is a release you should rely on yet.

A macOS disk space explorer. *Jaaga* is Kannada for "space". It shows which folders are actually
filling your Mac as a colourful map you can click into, lists the usual suspects that grow quietly, and
watches folders you star so you hear when one starts growing faster than usual. A background daemon
does the measuring; the app only draws what it reports.

## Building

Requires macOS 15 or later and Xcode 16 or later (Swift 6.1+).

```sh
swift build
swift test
Scripts/bundle-app.sh            # builds .build/release/Jaaga.app
```

## Running

```sh
open .build/release/Jaaga.app
```

The app registers the daemon as a login item, or runs it itself when that is refused (as it is for an
unsigned build). To run the daemon by hand: `swift run jaagad --help`.

## Full Disk Access

Without it, parts of your home folder cannot be read. Jaaga says so rather than hiding it — those sizes
show as "At least …" with a note — but to measure everything, add `Jaaga.app` (and `jaagad`, if you run
it from a terminal) under **System Settings › Privacy & Security › Full Disk Access**, then restart the
app.

## More

- [`docs/development.md`](docs/development.md) — how it is put together, working against a test tree,
  and what is not done yet
- [`docs/protocol.md`](docs/protocol.md) — the daemon's socket protocol, for writing another client
