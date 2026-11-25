# rex-gtk

A GTK4 / libadwaita client for [Rex](https://superlogical.com), written in Zig on top of
libghostty-vt.

## Build

Needs Zig 0.17.1 and the GTK 4, libadwaita, HarfBuzz, fontconfig, FreeType, epoxy, EGL/GL and
xkbcommon development packages. On aerynOS:

```sh
sudo moss install zig pkgconf glibc-devel gtk-4-devel libadwaita-devel graphene-devel \
  harfbuzz-devel fontconfig-devel freetype-devel libepoxy-devel libglvnd-devel \
  mesa-libegl-devel mesa-libgl-devel libxkbcommon-devel
```

```sh
zig build run                                  # run the app
zig build run -- --session work --font "JetBrains Mono" --font-size 12
zig build test                                 # unit tests (no display needed)
```

Options: `--session ID|LABEL` picks the session to show (otherwise the server picks one),
`--font`/`--font-size` set the terminal font, `--label` names this client for
`rex -C LABEL …` (default: the machine's hostname). For debugging, `--dump-frame PATH` writes every terminal frame to a PNG and
`--screenshot PATH` saves the whole window to a PNG every second.

The window shows the server's sessions in a sidebar (toggle it with the button at the top left)
and the selected session's windows as tabs. Splits, zoom and floating layers follow the server's
view, so changes made with the `rex` CLI or another app show up live.

Mouse: drag to select (double-click for a word, triple-click for a line); selecting copies to
the primary selection, and middle-click pastes it. Ctrl+Shift+C and Ctrl+Shift+V copy and paste
with the clipboard, and Ctrl+click opens a URL. The wheel scrolls back through the terminal's
history; typing returns to the bottom. When a program asks for the mouse (htop, vim with
`mouse=a`) events go to it instead; hold Shift to select text anyway.

## Connection problems

If the connection to the server drops, rex-gtk reconnects with backoff, continuing the same client
when the server still has it, and starts the server with `rex __internal autostart-status` if it
stopped. A terminal whose stream drops reopens it with a new ticket. A terminal whose snapshot
can't be decoded says so: the Rex server uses a different Ghostty version (see below).

In debug builds, `kill -USR1` drops the control connection and `kill -USR2` drops every data
stream, to test reconnecting. `kill -TERM` and Ctrl+C quit cleanly.

## Shortcuts and remote control

Actions use Rex.app's names, so bindings in `~/.config/rex/init.lua` work here too, and
`rex -C LABEL actions` lists them. The server merges the built-in shortcuts with your
configuration file; key sequences (such as `ctrl+b` then `%`), modes and keys bound to Lua
functions all work. Built-in shortcuts:

| Keys | Action |
| --- | --- |
| Ctrl+Shift+T / Ctrl+Shift+N | New tab / new session |
| Ctrl+PageDown / Ctrl+PageUp, Ctrl+Tab | Next / previous tab |
| Ctrl+Shift+PageDown / PageUp | Move tab |
| Alt+1…9 | Go to tab |
| Ctrl+Shift+O / Ctrl+Shift+E | Split right / down |
| Ctrl+Alt+arrows, Ctrl+Shift+] / [ | Focus pane |
| Ctrl+Shift+Enter / Ctrl+Shift+W | Zoom / close pane |
| Ctrl+Shift+C / V / A | Copy / paste / select all |
| Shift+PageUp / PageDown | Scroll |
| Ctrl+Alt+PageDown / PageUp | Next / previous session |
| Ctrl+Shift+S, F11 | Sidebar, full screen |
| Ctrl+= / Ctrl+- / Ctrl+0 | Font size |

## Tools

- `rexcat BLOCK [--follow MS] [--record FILE]`: attach to a terminal headlessly and print it;
  `--record` saves the raw data stream.
- `rexshot RECORDING OUT.png`: render a recording with the GPU renderer, no display needed.
- `fontcheck [FAMILY] [SIZE]`: load the terminal font and rasterize sample glyphs.

## Protocol reference

`docs/api/llms.txt` and `docs/api/help.json` are the Rex server's own API reference for API
revision 19, fetched from the local server:

```sh
sock="$XDG_RUNTIME_DIR/rex/server.sock"
curl -s --unix-socket "$sock" http://rex/llms.txt  > docs/api/llms.txt
curl -s --unix-socket "$sock" http://rex/api/help  > docs/api/help.json
```

## Keeping libghostty in step with the server

A terminal's data stream starts with a snapshot in Ghostty's snapshot format, which is not yet
stable between Ghostty versions. rex-gtk must therefore use the same Ghostty commit the Rex server
was built with. To find it and update the pin:

1. Read the Go binding version the server uses:
   ```sh
   python3 -c "import re;d=open('$(command -v rex)','rb').read();print(re.search(rb'go.mitchellh.com/libghostty\t(\S+)',d).group(1).decode())"
   ```
   It prints a pseudo-version such as `v0.0.0-20261123035439-5bbe1d0d0990`. The last part is a
   commit of https://github.com/mitchellh/go-libghostty.
2. In that commit's `CMakeLists.txt`, the `GIT_TAG` of `FetchContent_Declare(ghostty …)` is the
   Ghostty commit.
3. Update the pin and rebuild:
   ```sh
   zig fetch --save=ghostty https://github.com/ghostty-org/ghostty/archive/<COMMIT>.tar.gz
   ```
4. Re-copy anything under `src/vendor/ghostty/` from the same commit (see its `UPSTREAM` file),
   then check that `rexcat` still matches `rex capture`.

Current pin: Ghostty `74d1983f27eb004ef442c8353bd703eba19c93b6`
(go-libghostty `5bbe1d0d0990`, Rex server `0.1.0-preview.23`).
