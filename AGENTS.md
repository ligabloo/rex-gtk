# AGENTS.md

A GTK4 / libadwaita client for Rex, written in Zig 0.17.1 on top of
libghostty-vt (a pinned Ghostty source tree, not a system library).

## Commands

```sh
zig build run                # build and run the app
zig build test               # unit tests, no display or server needed
zig build -Doptimize=ReleaseFast -Dtools=false --prefix ~/.local   # install
```

- `-Dtools=false` skips installing the headless tools (`rexcat`, `rexshot`,
  `fontcheck`).
- `-fno-sys=freetype` (also harfbuzz, fontconfig, libpng, zlib) builds that
  library from source instead of linking the system one.
- Debug-run options: `--session [HOST:]ID|LABEL`, `--font`, `--font-size`,
  `--label`, `--dump-frame PATH` (PNG per frame), `--screenshot PATH` (whole
  window each second). `REX_SERVER` env var overrides the local server address.
- In debug builds: `kill -USR1` drops the control connection, `kill -USR2`
  drops every data stream (reconnect testing), `kill -TERM`/Ctrl+C quit cleanly.

## Package releases

Before publishing an AerynOS package or pushing the source and recipe for that
release, build the candidate locally with Boulder and test it through a local
Moss repository. In an isolated Moss root, install the current published
version, sync to the candidate, and verify that Moss installed the expected
version. Use the same source changes, package version, and release number that
will be published. Fix any failures and repeat the test before publishing.
See [Build and test a local AerynOS package](README.md#build-and-test-a-local-aerynos-package).

## Architecture

Three module layers in build.zig, split so tests and headless tools never need
GTK or a display:

- **`src/core.zig`** — GTK-free core: `net/` (endpoint address parsing,
  WebSocket framing, the control connection: JSON over `/api/control` with
  subprotocol `rex.control.v1`, API revision 19; data connections over
  `/api/data` with subprotocol `rex.data.terminal.v1`), `term/` (the Mirror,
  recording, stream filter). `zig build test` runs the core module's tests.
- **`src/render/`** — GTK-free font stack and OpenGL renderer. `build.zig`'s
  `addGhosttyRender` assembles a `ghostty-render` module by copying selected
  dirs/files out of the pinned Ghostty package and overlaying the shims in
  `src/render/ghostty_shim/` (which replace Ghostty's config, global state,
  app runtime and renderer loop). Uses a surfaceless EGL context, so it works
  headless.
- **`src/ui/`** — the GTK application. `app.zig` is the window (machines in a
  sidebar, the selected session's tabs). `machine.zig` owns one control+data
  connection per machine. `client.zig` routes control responses to requests
  by id. `mainloop.zig` posts work from background threads to the GTK main
  thread. `prefs/` is the Preferences dialog. Settings persist in
  `~/.config/rex-gtk/settings.json` (`settings_file.zig`).
- **`src/tools/`** — headless tools: `rexcat` (attach to a terminal and print;
  use it to check protocol decoding against `rex capture --trim`), `rexshot`
  (render a recording), `fontcheck` (rasterize sample glyphs).

### Threading rule

All app state lives on the GTK main thread. Reader threads never touch it;
they call `mainloop.post` (idle) or `postWithPriority` (`.default`, ahead of
redraws, for latency-sensitive work). Control reads block (one reader thread
per control connection, one per data connection).

### Key protocol facts (details in `docs/protocol-notes.md` and `docs/api/`)

- A terminal data stream is a Ghostty snapshot first, then a `resize` message,
  then program output with Rex messages mixed in.
- The Mirror (`src/term/mirror.zig`) is a read-only VT copy: it never answers
  terminal queries, because the server's terminal already answered them.
- Selection is done client-side (Ghostty `SelectionGesture` on the mirror);
  the server's selection events exist but rex-gtk doesn't use them. Mouse
  events are forwarded only when the program turned on mouse reporting and
  Shift isn't held.
- The server's `/api/help` doesn't list block events; `docs/protocol-notes.md`
  documents the mouse/wheel payloads and event names found by testing.

## Gotchas

- **Ghostty pin must match the server.** Terminal snapshots are not stable
  between Ghostty versions, so the pinned Ghostty commit in `build.zig.zon`
  must be the one the Rex server was built with. The update procedure (find
  the go-libghostty version in the `rex` binary, trace to the Ghostty commit,
  `zig fetch --save=ghostty …`) is in README.md; also re-copy anything under
  the vendored dirs if the pin moves, and verify `rexcat` still matches
  `rex capture`.
- **Declare build options before the first `orelse return`** in build.zig: on
  the first pass, while lazy dependencies are still missing, the build script
  returns early, and options it never reached are rejected.
- If the Ghostty pin's build layout changes, the build panics with
  "ghostty-vt has no {s} import": the copied sources expect generated modules
  (`uucode`, `unicode_tables`, …) that are taken from `ghostty-vt`'s import
  table.
- Tests are colocated `test` blocks in the source files. Only GTK-free files
  are wired into the test step: the core module plus `src/ui/keymap.zig`,
  `settings_file.zig`, `qr.zig`, `themes.zig`. New `src/ui` tests must stay
  GTK-free and be added to build.zig to run.
- Files passed to `zig build test` run as standalone module roots: they can't
  import `core`/`render` the way `app.zig` does.

## Conventions

- Every file starts with a `//!` doc comment explaining its role; the comment
  often carries the non-obvious design decisions (see `mainloop.zig`,
  `endpoint.zig`, `mirror.zig`). Read it first.
- Logging via `std.log.scoped(.name)`.
- The Rex protocol is JSON over WebSocket; every message owns an arena
  (`Incoming.deinit`). Callers own messages passed to them.
- Commit messages are short, lowercase, user-facing ("Cut input latency"),
  sometimes prefixed `build:`/`README:`.
