# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release,
architecture, and sharp-edge notes that should travel with the code.

## What Jaaga is

A macOS disk space explorer: a background daemon (`jaagad`) that does all the measuring, and a SwiftUI
app that only renders what the daemon reports. A CLI and an MCP server are planned as further clients
of the same socket protocol, so **keep the daemon's interface client-agnostic** — nothing in
`JaagaProtocol` or `JaagaDaemon` should assume the client is the app.

`README.md` covers building and running. `docs/protocol.md` is the protocol contract and is the thing
to update whenever the wire format changes.

## Architecture rules worth not breaking

- **The app must not walk the filesystem.** `JaagaApp` depends on `JaagaProtocol` and `JaagaLayout`
  only, never `JaagaCore`. That dependency edge is the enforcement; if you find yourself wanting
  `JaagaCore` in the app, the daemon is missing a method.
- **Sizes are always allocated bytes** (`st_blocks × 512`), one volume, symlinks never followed, hard
  links counted once, unreadable folders reported rather than skipped. The rules and their rationale
  are in `DiskScanner`'s doc comment and pinned by `Tests/JaagaCoreTests/DiskScannerTests.swift`.
- **Totals are recursive, and the `Recursive totals` suite checks them against `du -sk`.** If a size
  ever looks wrong, that suite plus `du` is the way to settle it — and the answer has usually been
  unreadable folders, not arithmetic. `Entry.unreadableDescendantCount` carries that caveat to every
  level, and the UI shows "At least" rather than a figure that looks exact.
- **`moveToTrash` is the only destructive operation and only ever moves to the Trash.** It refuses
  without `confirmed: true`, which defaults to `false` so forgetting it cannot read as consent.
- **The usual-suspects catalog is data**: `Sources/JaagaCore/Resources/suspects.json`, with a user
  override at `~/Library/Application Support/Jaaga/suspects.json`. Covering a new tool means editing
  JSON, not Swift.
- **Verdicts default to `your_data`.** Only promote to `safe_to_clear` for something specifically
  recognised; the cost of being wrong that way is somebody's work.

## Sharp edges

- **`Category` is a reserved name.** The ObjC runtime typedefs `Category`, so the protocol enum is
  `UsageCategory`. Do not rename it back.
- **Do not use `Bundle.module`.** Its generated accessor calls `fatalError` when the resource bundle is
  missing, which would turn a packaging mistake into a crashing daemon. `CatalogLocation` does the
  lookup by hand and reports where it looked. It has to find the bundle in three layouts: the app
  bundle's `Contents/Resources`, a `swift build` products directory, and beside `*.xctest` under
  `swift test`.
- **Resource bundles may not live in `Contents/MacOS`** — `codesign` rejects a nested bundle there.
  `Scripts/bundle-app.sh` puts them in `Contents/Resources` only.
- **`swift build` honours only the last `--product`.** Passing two silently skips one.
- **`NWListener` cannot bind a Unix domain socket** (fails `EINVAL`). The transport is POSIX sockets
  with a thread per connection, deliberately: blocking reads must stay off Swift's cooperative pool.
- **Scans must not run on the cooperative pool either.** `ScanRunner` puts them on its own queue and
  passes an `isCancelled` closure, because `Task.isCancelled` means nothing on a `DispatchQueue` thread.
- **`DiskScanner.scan` takes `onProgress` before `isCancelled`** so a trailing closure binds to the
  progress callback. Swift's forward-scan matching would otherwise attach it to `isCancelled`.
- **`WatchStore` coalesces samples taken within 60 seconds of each other.** A test that adds two
  samples back to back gets one. Assert on the value, not the count.

## Testing

`swift test` — Swift Testing, no XCTest. The daemon tests bind real sockets under `/tmp` and scan real
temporary trees; they are `.serialized` so they never fight over a socket.

- Socket paths go under `/tmp`, not inside the temporary home: `sockaddr_un` allows 103 bytes and a
  nested temporary path overruns it.
- There is no async per-test teardown in Swift Testing, so `Tests/JaagaDaemonTests` uses a scoped
  `withDaemon { }` helper. A `defer { Task { await stop() } }` lets one test's daemon outlive it and
  fight the next one for the socket.
- Permission tests skip themselves when running as root, and the fixture restores `0o755` before
  deleting the tree — a `0o000` directory cannot be removed.

## Releasing

Tag `v*` and push; `.github/workflows/release.yml` builds on a macOS runner and publishes the app and
the daemon as release assets. Builds are unsigned and not notarized, and the release notes say so.
