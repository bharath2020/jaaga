# The Jaaga daemon protocol, version 1

`jaagad` measures folders and answers questions about them over a Unix domain socket. The macOS app is
one client; a CLI or an MCP server would be another, and this document is everything either needs.

Nothing in the protocol is macOS-specific beyond the paths it reports, and nothing in it assumes Swift.

---

## Connecting

| | |
|---|---|
| **Socket** | `~/Library/Application Support/Jaaga/jaagad.sock` |
| **Type** | `AF_UNIX`, `SOCK_STREAM` |
| **Permissions** | `0600`, in a `0700` directory — the owning user only |
| **Framing** | newline-delimited JSON (one compact object per line, UTF-8, `\n` terminated) |
| **Encoding** | UTF-8. Timestamps are seconds since the Unix epoch, as JSON numbers |
| **Sizes** | always **allocated** (on-disk) bytes, as `Int64` |

JSON escapes newlines inside strings, so a bare `\n` byte always ends a frame. A client can therefore
frame messages with a plain line reader — no length prefixes, no chunked encoding.

A frame larger than 8 MiB is refused with a `malformedFrame` error and the connection is closed.

```
client ──── {"v":1,"id":"1","method":"listFolder","params":{"path":"/Users/me"}} ───▶ jaagad
       ◀─── {"v":1,"type":"event","event":"scanProgress","payload":{…}} ────────────
       ◀─── {"v":1,"type":"event","event":"scanProgress","payload":{…}} ────────────
       ◀─── {"v":1,"type":"response","id":"1","method":"listFolder","result":{…}} ──
```

Responses and events share the connection. Every frame from the daemon carries a `type`, so a client
switches on that before decoding anything else.

### Trying it by hand

```sh
printf '%s\n' '{"v":1,"id":"1","method":"hello","params":{"clientName":"curl"}}' \
  | nc -U ~/Library/Application\ Support/Jaaga/jaagad.sock
```

`nc` closes the connection as soon as stdin ends, so for anything slower than `hello` use a client that
keeps reading — `examples/` has nothing yet, but `DaemonClient` in `Sources/JaagaProtocol` is the
reference implementation, and `Tests/JaagaDaemonTests` drives a raw socket directly.

---

## Versioning

Every frame carries `v`, the protocol version. This document describes **version 1**.

- A request with a `v` this daemon does not support is refused with `unsupportedProtocolVersion`,
  naming the versions it does speak. Nothing is executed.
- A request with no `v` is read as the current version.
- **Unknown fields are ignored**, in both directions. A later daemon may add fields to any object
  without breaking an older client, so clients must not reject unrecognised keys.
- Adding a method, an event, a verdict or a field is *not* a breaking change and does not bump `v`.
  Removing or repurposing one is, and does.
- `hello` reports `supportedProtocolVersions`, so a client can negotiate rather than guess.

---

## Requests

```json
{"v": 1, "id": "7", "method": "listFolder", "params": {"path": "/Users/me/Library"}}
```

`id` is a client-chosen correlation string, echoed on the response. It only has to be unique among that
client's in-flight requests.

`params` may be omitted entirely for methods that take none. Parameters marked *optional* below may be
left out and take their stated default.

Requests are handled concurrently: a long scan does not hold up later requests on the same connection,
and responses may arrive out of order. Match them by `id`.

### `hello`

Handshake. Not strictly required before other methods, but it is where a version mismatch surfaces
cleanly.

| Parameter | Type | |
|---|---|---|
| `clientName` | string | required — for the daemon's log, e.g. `"jaaga-cli"` |
| `clientVersion` | string | optional |
| `protocolVersion` | int | optional, defaults to the current version |

Result: `{protocolVersion, supportedProtocolVersions, daemonVersion, homePath, socketPath}`

### `volumes`

No parameters. Result: `{volumes: [VolumeInfo], homePath}`, startup disk first.

Network shares and non-browsable volumes are left out.

### `volumeSummary`

| Parameter | Type | |
|---|---|---|
| `mountPath` | string | optional, defaults to the startup disk |
| `refresh` | bool | optional, defaults to `false` |

Result: `VolumeSummary` — the volume, plus a breakdown by category.

`segments` only covers what the daemon has measured, and `accountedBytes` says how much that is. When
the home folder has not been measured, `segments` is empty rather than fabricated; a client should show
plain used/free in that case. When it has, the space on the volume outside the home folder appears as
one `"System & apps"` segment rather than being broken down into detail nobody measured.

### `listFolder`

The main one: a folder and its immediate children.

| Parameter | Type | |
|---|---|---|
| `path` | string | required |
| `refresh` | bool | optional, defaults to `false` — discard the cache and measure again |

Result: `FolderListing`.

The first call for a path measures the whole subtree, which can take seconds or minutes; `scanProgress`
events stream meanwhile. Later calls are served from an in-memory cache (15 minutes, LRU, invalidated
by FSEvents on watched trees and by any action that changes the tree), and come back with
`fromCache: true` immediately.

### `entry`

| Parameter | Type | |
|---|---|---|
| `path` | string | required |

Result: a single `Entry`. Cheap when the path's parent is already cached; otherwise it measures.

### `suspects`

The catalogued folders that grow quietly, measured on this machine.

| Parameter | Type | |
|---|---|---|
| `root` | string | optional, defaults to the home folder |
| `refresh` | bool | optional, defaults to `false` |

Result: `SuspectReport`. Rules matching nothing on this machine are left out, so a Mac without Docker
has no Docker row.

### `watch` / `unwatch` / `watched`

`watch` and `unwatch` take `{path}`. `watched` takes nothing.

`watch` returns the `WatchedFolder` it created, measuring the folder to take its first sample.
`unwatch` returns `{ok}` — `false` when the path was not watched. `watched` returns
`{folders: [WatchedFolder]}`, largest first.

Both broadcast — `watchUpdated` and `watchRemoved` — so every connected client's stars agree with the
daemon's list. A CLI unstarring something has to change the app's star, not only its own.

Watched folders are persisted to `~/Library/Application Support/Jaaga/watched.json` and re-measured
hourly. They survive the daemon restarting; that history is the whole point of the feature.

### `quickLook`

| Parameter | Type | |
|---|---|---|
| `path` | string | required |
| `limit` | int | optional, defaults to `24` |

Result: `QuickLookReport` — for a folder, what is inside it largest first; for a file,
`prefersSystemPreview: true` and no items, meaning the client should hand the path to the platform's
own previewer. The daemon renders nothing.

### `reveal`

Takes `{path}`, selects it in the Finder, returns `{ok: true}`.

### `moveToTrash`

| Parameter | Type | |
|---|---|---|
| `path` | string | required |
| `confirmed` | bool | optional, defaults to `false` |

Result: `{originalPath, trashedPath, reclaimedBytes}`.

**This is the only destructive method, and it only ever moves things to the Trash — nothing is
permanently deleted, ever.** It refuses with `confirmationRequired` unless `confirmed` is `true`, and
`confirmed` defaults to `false` so forgetting it can never read as consent. A client must have asked a
human before setting it. A CLI should require an interactive confirmation or an explicit
`--yes`-style flag; an MCP server should treat it as requiring user approval.

### `cancel`

| Parameter | Type | |
|---|---|---|
| `requestID` | string | required — the `id` of the request to abandon |

Result: `{ok}` — `false` when there was nothing in flight under that id, which is not an error.

Answered immediately, ahead of any queued work. The cancelled request then fails with `cancelled`.

---

## Responses

```json
{"v": 1, "type": "response", "id": "7", "method": "listFolder", "result": { … }}
```

`method` is echoed so a dynamically typed client can decode `result` without keeping its own
bookkeeping of what it asked for.

## Errors

```json
{"v": 1, "type": "error", "id": "7",
 "error": {"code": "notReadable", "message": "…", "path": "/…", "errnoCode": 13}}
```

`id` is present whenever the daemon could work out which request failed. `path` and `errnoCode` are
present where they mean something.

| `code` | Meaning |
|---|---|
| `unsupportedProtocolVersion` | The request's `v` is not one this daemon speaks |
| `malformedFrame` | Not decodable as a request frame, or over the size limit |
| `unknownMethod` | No such `method` |
| `invalidParameters` | `params` missing or of the wrong shape |
| `notFound` | Nothing at that path |
| `notADirectory` | A directory was required |
| `notReadable` | It exists but could not be opened — usually a missing Full Disk Access grant |
| `notPermitted` | The action was refused by the system |
| `cancelled` | Abandoned via `cancel`, or the client disconnected |
| `confirmationRequired` | A destructive request arrived without `confirmed: true` |
| `internalError` | Anything else |

## Events

```json
{"v": 1, "type": "event", "event": "scanProgress", "payload": { … }}
```

Events carry no `id`. **Every connected client receives every event** — there is no subscription
filter, deliberately: the volume is small and a filter would be one more thing a new client has to get
right before anything works. A client that only cares about its own scans can match
`payload.requestID`.

| `event` | Payload | When |
|---|---|---|
| `scanProgress` | `{requestID?, root, currentPath, itemsScanned, bytesScanned}` | Every ~2,000 items during a scan |
| `scanCompleted` | `{requestID?, root, allocatedBytes, itemCount, durationSeconds, unreadableCount}` | A scan finished |
| `folderChanged` | `{paths}` | FSEvents saw a change under a watched folder, or an action changed one. Anything cached below those paths is stale |
| `watchUpdated` | `{folder}` | A folder was starred, or a watched one was re-measured |
| `watchRemoved` | `{path}` | A folder stopped being watched |
| `watchAlert` | `{folder, accelerationFactor?, message}` | A watched folder is growing much faster than its own recent pace |

---

## Objects

### `Entry`

```json
{
  "path": "/Users/me/Library/Developer/Xcode/DerivedData",
  "name": "DerivedData",
  "isDirectory": true,
  "isSymbolicLink": false,
  "allocatedBytes": 38600000000,
  "itemCount": 412380,
  "directChildCount": 9,
  "category": "dev",
  "verdict": "safe_to_clear",
  "reason": "Xcode rebuilds this the next time you build.",
  "kind": "Xcode build cache",
  "lastOpened": 1700000000,
  "contentModified": 1700000000,
  "created": 1600000000,
  "isWatched": true,
  "unreadableDescendantCount": 0
}
```

- `allocatedBytes` — what the subtree occupies on disk, recursive. See **How sizes are measured**.
- `itemCount` — files plus directories inside, recursive; `1` for a file.
- `directChildCount` — immediate children; `null` when the daemon has not measured them yet.
- `lastOpened` / `contentModified` / `created` — `st_atime`, `st_mtime`, `st_birthtime`. Any may be
  `null` on a filesystem that does not record it.
- `reason` — one plain sentence, meant to be shown to a person as written.
- `unreadableDescendantCount` — how many folders inside could not be opened. **When it is non-zero,
  `allocatedBytes` is a lower bound** and a client must not present it as exact. There is no way to
  say how many bytes are missing: measuring them is exactly what failed. On a real `~/Library` this
  is routinely 150-odd TCC-protected folders until Full Disk Access is granted. Added after version 1
  shipped, so it is absent from an older daemon's frames and should be read as `0`.

### `category`

`cache` · `media` · `dev` · `apps` · `docs` · `downloads` · `photos` · `system`

What a folder holds, for grouping and colour. A client may add more categories in a later version.

### `verdict`

| Value | Meaning |
|---|---|
| `safe_to_clear` | Rebuilt or re-downloaded on demand. Nothing of yours is lost |
| `review_first` | Big and often disposable, but only you know which parts you still need |
| `your_data` | Your own files. Jaaga never suggests clearing these |

The default is `your_data`. The daemon only upgrades to `safe_to_clear` when it recognises something
specific from the catalog or a well-known folder name, because the cost of being wrong in that
direction is somebody's work.

### `FolderListing`

`{folder: Entry, children: [Entry], parentPath?, scannedAt, fromCache, complete, unreadable}`

`children` is largest first. `complete` is `false` when part of the subtree could not be read, in which
case `allocatedBytes` is a **lower bound** and `unreadable` says which folders were missed.

### `UnreadablePath`

`{path, reason, errnoCode?}` — `errnoCode` is `13` (`EACCES`) for the common Full Disk Access case.

### `VolumeInfo`

`{name, mountPath, totalBytes, freeBytes, isStartupDisk, isInternal, isRemovable}`

`freeBytes` is the figure the Finder shows (`volumeAvailableCapacityForImportantUsage`), which counts
purgeable space as available.

### `Suspect`

`{id, title, displayPath, paths, category, verdict, reason, kind, allocatedBytes, itemCount, isWatched, isAggregate}`

`id` is the catalog rule id, stable across versions. `paths` holds every matched path; `isAggregate` is
true when several were summed, as for `node_modules` across projects.

### `WatchedFolder` and `GrowthSummary`

```json
{
  "path": "…", "name": "DerivedData", "category": "dev", "verdict": "safe_to_clear",
  "addedAt": 1600000000, "currentBytes": 38600000000,
  "samples": [{"at": 1699000000, "bytes": 21200000000}, …],
  "growth": {
    "deltaBytes": 17400000000, "windowSeconds": 4838400,
    "recentBytesPerDay": 1500000000, "baselineBytesPerDay": 480000000,
    "accelerationFactor": 3.1, "isAlerting": true
  }
}
```

`samples` is oldest first and thinned as it ages, keeping at most 400 points and always the oldest one,
so `deltaBytes` stays honest.

`accelerationFactor` is `recentBytesPerDay / baselineBytesPerDay`; it is `null` when the folder was flat
before, which has no meaningful ratio but is itself worth alerting on. `isAlerting` already applies the
daemon's thresholds — a client should use it rather than re-deriving one.

### `QuickLookReport`

`{entry, items, truncated, prefersSystemPreview}` — `items` is `{name, path, isDirectory,
allocatedBytes, contentModified?, fileExtension?, unreadableDescendantCount}`, largest first.

`unreadableDescendantCount` means the same thing as on `Entry`, and matters here for the same reason:
a folder nobody could open reports `0 bytes`, which would read as empty rather than as unmeasured.

---

## How sizes are measured

Every number the daemon reports follows these rules, and the tests in `Tests/JaagaCoreTests` pin each
one down:

- **Allocated, not logical.** Sizes come from `st_blocks × 512`, so a sparse file costs what it really
  costs and a pile of tiny files costs its block overhead. This is the number that moves the free-space
  figure when you delete something.
- **One volume.** A child on a different device is skipped, not folded into its parent, so a mounted
  disk image never inflates your home folder. Volumes are listed separately instead.
- **Symlinks are never followed.** A link contributes only its own few bytes. Nothing is double-counted
  and there are no traversal cycles.
- **Hard links are counted once.** Two names for one inode occupy one set of blocks, so the second name
  adds nothing — which is what the Finder's free-space figure will also say.
- **Unreadable folders are reported, never guessed at.** A folder that cannot be opened appears in
  `unreadable` with its errno, `complete` goes `false` on the listing, and every `Entry` between it
  and the scan root gets a non-zero `unreadableDescendantCount`. A total that is short says so, at
  every level a person might read it — not only for the folder that happened to be scanned.

  This matters more than it sounds: without Full Disk Access, `~/Library` is short by whatever is
  inside 150-odd protected folders, and a number that looks precise but is not is worse than no
  number at all.

Sizes are base-10 (1 GB = 1,000,000,000 bytes) wherever they are formatted, matching the rest of macOS.

---

## The usual-suspects catalog

The catalog is data, not code: `Sources/JaagaCore/Resources/suspects.json`, loaded at start-up. A user
can add rules or override shipped ones at `~/Library/Application Support/Jaaga/suspects.json`; a rule
there with the same `id` as a shipped one replaces it.

```json
{
  "version": 1,
  "rules": [
    {
      "id": "xcode-derived-data",
      "title": "DerivedData",
      "kind": "Xcode build cache",
      "category": "dev",
      "verdict": "safe_to_clear",
      "reason": "Xcode rebuilds this the next time you build.",
      "displayPath": "~/Library/Developer/Xcode/DerivedData",
      "match": { "type": "path", "path": "Library/Developer/Xcode/DerivedData" }
    }
  ]
}
```

| `match.type` | Fields | Finds |
|---|---|---|
| `path` | `path` | One directory or file, relative to the scan root (or absolute with a leading `/`) |
| `directoryName` | `name`, `roots`, `maxDepth` | Directories with that name under any of `roots`. Does not descend into one it has found, so nested copies are counted once |
| `filesWithExtensions` | `extensions`, `root`, `minimumAgeDays` | Files directly inside `root` with those extensions, optionally only ones untouched for a while |

`reason` may contain `{count}` (the number of matches) and `{s}` (a plural "s", empty when the count is
one), so an aggregate rule reads correctly whether it found one project or thirty-eight.

Set `"aggregate": true` when a rule is meant to sum many paths into one row.

---

## Writing a client

1. Connect to the socket. If it is not there, the daemon is not running — see the README.
2. Send `hello` and check `supportedProtocolVersions`.
3. Read lines, decode each as JSON, and switch on `type`:
   - `response` → match `id` to your request
   - `error` → match `id`; the `code` is the machine-readable part, `message` is for people
   - `event` → handle or ignore; never assume one belongs to you without checking `requestID`
4. Ignore fields you do not recognise.
5. Treat `moveToTrash` as needing human consent, every time.

`Sources/JaagaProtocol/DaemonClient.swift` is the reference implementation: connect, correlate, stream
events, and cancel an abandoned request. It is about 300 lines, and a client in another language does
not need to be bigger.
