# IPC & Socket Architecture

Overview of communication mechanics implemented between `jEMach.jl` and UI consumers (`jl-assist` TUI and Zig broker).

## Dual Sync Mechanism

`jEMach.jl` uses a hybrid communication model combining **UNIX Domain Socket Event Broadcasting** and **Filesystem State Backup**.

```
                       +-------------------------------+
                       |    jEMach Julia Engine        |
                       +---------------+---------------+
                                       |
                     +-----------------+-----------------+
                     |                                   |
           UNIX Socket Listener                  File State Output
     /tmp/jemach_<project_hash>.sock         /tmp/jl_tui_state_<hash>.json
                     |                                   |
            +--------+--------+                 +--------+--------+
            |                 |                 |                 |
     jl-assist TUI       Zig Broker       Fallback Reader   Offline Inspector
```

## Bidirectional UNIX Domain Socket Protocol

- **Socket Path**: `/tmp/jemach_<project_safe_name>.sock`
- **Protocol**: Full-duplex single-line JSON objects terminated with `\n`.
- **State Streaming (Julia -> TUI)**:
  1. Consumer connects to socket and writes `SUB\n`.
  2. `jEMach` registers client socket in active subscriber set `_socket_clients`.
  3. Immediately sends the latest serialized workspace JSON (including detected `"backend"`).
  4. Subsequent state refreshes write JSON payloads directly across open sockets.
  5. On `jEMach.stop()`, broadcasts `{"event":"stop","action":"close"}` so TUI panes exit cleanly across Ghostty, Kitty, Zellij, tmux, and Rex.
- **Interactive REPL RPC (TUI -> Julia)**:
  Subscribers can send JSON command lines back over the same open socket connection (removing any hard requirement on `tmux send-keys`):
  - `{"cmd":"eval","code":"..."}`: Evaluates code in `Main`, prints `julia> <code>` and formatted output in the REPL, refreshes `REPL.LineEdit`, and broadcasts updated state.
  - `{"cmd":"eval_silent","code":"..."}`: Evaluates internal management commands silently and refreshes state.
  - `{"cmd":"insert","text":"...","move_left":1}`: Injects text directly into the active `REPL.LineEdit` prompt buffer (`Base.active_repl.mistate`) and positions the cursor.
  - `{"cmd":"clear"}`: Clears the REPL terminal screen and redraws the prompt.

#### Automatic Fallback File

In addition to socket streaming, state updates are written to `/tmp/jl_tui_state_<project_safe_name>.json` to ensure recovery if socket connections reset or close.
