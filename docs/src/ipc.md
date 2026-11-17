# IPC and sessions

The default TUI connects directly to the Julia process over a full-duplex UNIX
domain socket. The optional Zig broker is a separate experimental program and
is not started by `jEMach.start()`.

## Session ownership

Each process creates `/tmp/jemach-<uid>/session-<random>/`. The parent and session
directories are private to the user (0700); the listening socket is 0600.
`src/session.jl` owns creation, discovery metadata and cleanup. Session files are:

| File | Purpose |
| --- | --- |
| `repl.sock` | Commands and state subscriptions |
| `state.json` | Last published snapshot, replaced atomically |
| `project` | Canonical project directory, advertised after the socket starts |

Paths are independent of project name length and remain short enough for UNIX
sockets. Several Julia processes may use the same project without unlinking one
another's socket. `jEMach.terminal_info()` reports the current socket, state file
and session directory. A restart creates a fresh session directory.

The launcher and TUI share `scripts/tui/sessions.lua`. Discovery only considers
live sockets for the current user and canonical project path. A single match is
selected automatically; multiple matches require `jl-assist -s SOCKET`. No match
produces an error with startup instructions. Explicit selection remains pinned
when a connection drops. Discovery ignores stale session directories after a
crash; normal shutdown removes the process's own files.

## Wire protocol

Messages are UTF-8, one JSON object per line, terminated with a newline.

1. A subscriber sends `SUB\n`.
2. Julia immediately sends the cached snapshot, or collects the first snapshot.
3. While subscribers are connected, Julia checks state every 0.5 seconds.
   An unchanged serialized body is not broadcast again. Without subscribers,
   the watcher skips snapshot collection.
4. The same connection accepts command objects. A one-shot connection may
   send a command without subscribing.
5. Shutdown sends `{"event":"stop","action":"close"}` and closes subscribers.

| Command | Fields | Effect |
| --- | --- | --- |
| `eval` | `code`, optional `history` | Evaluate in `Main`, show output and refresh state |
| `eval_silent` | `code`, optional `filename`, `proc_name` | Evaluate management code and refresh state |
| `insert` | `text`, optional `move_left` | Insert into the active REPL buffer |
| `replace_input` | `text`, optional `move_left` | Replace input and switch to Julia mode |
| `clear` | — | Clear and redraw the REPL |

RPC objects are flat: strings, numbers, booleans and null. Malformed JSON is
rejected as a whole, including bad escapes, malformed numbers and trailing input.
Both codecs handle Unicode escapes and surrogate pairs. Code evaluation is
available to processes running as the same user through the private socket.

## File fallback

Snapshot publication writes `state.json.tmp` and atomically renames it to
`state.json`. When socket frames are unavailable, the TUI reads that session's
file and compares its contents, avoiding platform-specific `stat` commands and
timestamp granularity issues. It never discovers a different session as a
side effect of a failed read or reconnect.

`publish_state()` also supports an explicit snapshot while the watcher is stopped;
it creates a private directory without advertising a listening session. `stop()`
cleans that directory as well.
