# rex-gtk

A GTK4 / libadwaita client for [Rex](https://superlogical.com), written in Zig on top of
libghostty-vt.

## Build

Needs Zig 0.17.1 and the GTK 4, libadwaita, HarfBuzz, fontconfig, FreeType, epoxy, EGL/GL and
xkbcommon development packages. On aerynOS:

```sh
sudo moss pkg add zig pkgconf glibc-devel gtk-4-devel libadwaita-devel graphene-devel \
  harfbuzz-devel fontconfig-devel freetype-devel libepoxy-devel libglvnd-devel \
  mesa-libegl-devel mesa-libgl-devel libxkbcommon-devel
```

```sh
zig build run                                  # run the app
zig build run -- --session work --font "JetBrains Mono" --font-size 12
zig build test                                 # unit tests (no display needed)
```

Options: `--session [HOST:]ID|LABEL` picks the session to show, on one of your hosts if
`HOST:` is given (otherwise the server picks one),
`--font`/`--font-size` set the terminal font, `--label` names this client for
`rex -C LABEL …` (default: the name set in Preferences, or the machine's hostname). For debugging, `--dump-frame PATH` writes every terminal frame to a PNG and
`--screenshot PATH` saves the whole window to a PNG every second.

The sidebar lists every machine you use: this computer, then your hosts from `rex hosts`,
reached over ssh (`ssh://user@host`, through `rex __internal ssh-tunnel`), your tailnet, or a
plain address. Under each machine are its sessions and their tabs, with each tab's program and
working directory. A machine that can't be reached shows a warning; click it to try again. In
Preferences › Appearance the tabs can move to the header bar instead, with a session switcher
beside them, and the header bar can hide while the sidebar is collapsed, showing again when the
pointer reaches the top edge. Splits, zoom and floating layers follow the server's view, so
changes made with the `rex` CLI or another app show up live.

Right-click a terminal (Shift+right-click when a program uses the mouse) for the pane menu:
copy and paste, splits, zoom, reset, and the app's own items. Ctrl+Shift+P opens the command
palette, which runs any action or jumps to any tab of any machine.

Preferences (Ctrl+,) has the server's status, its Tailscale node and Pair Device QR code, the
configuration file, your machines and the ssh agent to use. rex-gtk keeps its own settings in
`~/.config/rex-gtk/settings.json`.

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
| Ctrl+Shift+P, Ctrl+, , Ctrl+? | Command palette, Preferences, keyboard shortcuts |
| Shift+F10 | Pane menu |
| Ctrl+= / Ctrl+- / Ctrl+0 | Font size |

## Install

```sh
zig build -Doptimize=ReleaseFast -Dtools=false --prefix ~/.local
```

installs `rex-gtk`, its desktop entry, icon and AppStream metadata.

On aerynOS it is also packaged in the
[aerynos-recipes](https://github.com/ligabloo/aerynos-recipes) moss repo:

```sh
sudo moss repo add aerynos-recipes https://github.com/ligabloo/aerynos-recipes/releases/download/repo-x86_64/stone.index
sudo moss pkg add rex-gtk
```

### Build and test a local AerynOS package

Before pushing a package release or publishing it, build the candidate locally and verify
that Moss can upgrade from the current published version. Test the same source changes,
package version, and release number you plan to publish.

Run these commands from the rex-gtk checkout on AerynOS x86-64, with `boulder`, `moss`,
and a sibling `../aerynos-recipes` checkout. If you haven't set up Boulder's `unstable`
profile yet, add it once:

```sh
boulder profile add unstable --repo 'name=unstable,base-uri=https://cdn.aerynos.dev/,channel=main,version=stream/unstable,arch=x86_64'
```

Pick a candidate version higher than the baseline you're testing. The temporary checkout
includes committed code and staged and unstaged changes to tracked files. Stage any new
source files you want to include before taking the snapshot.

```sh
version=0.2.2
work=$(mktemp -d /tmp/rex-gtk-package.XXXXXX)
mkdir -p "$work/packages" "$work/repo" "$work/root" "$work/cache"

git clone --no-local . "$work/source"
git diff --binary HEAD > "$work/working-tree.patch"
if [ -s "$work/working-tree.patch" ]; then
    git -C "$work/source" apply "$work/working-tree.patch"
fi
git -C "$work/source" add -A
git -C "$work/source" -c user.name='Local Build' -c user.email='local-build@localhost' \
    commit --allow-empty -m 'stage local package build'
revision=$(git -C "$work/source" rev-parse HEAD)

sed -e "s/^version .*/version     : \"$version\"/" \
    -e 's/^release .*/release     : 1/' \
    -e "s|^    - git.*|    - git\|file://$work/source : $revision|" \
    ../aerynos-recipes/recipes/rex-gtk/stone.yaml > "$work/stone.yaml"
boulder build -y -p unstable -o "$work/packages" "$work/stone.yaml"
```

The candidate `.stone` is in `"$work/packages"`. The recipe sets the Moss package version.
Update the app's version and AppStream metadata in the snapshot before committing it if
you're also testing those displays.

To test an upgrade, set `baseline` to an existing rex-gtk `.stone` from an older build or
the [Moss release](https://github.com/ligabloo/aerynos-recipes/releases/tag/repo-x86_64).
Run the following in the same shell. The test uses a separate Moss root and cache, with
the AerynOS repository enabled for dependencies.

```sh
baseline=/absolute/path/to/rex-gtk-0.2.1-1-1-x86_64.stone
test_moss() { moss -D "$work/root" --cache-dir "$work/cache" "$@"; }

cp "$baseline" "$work/repo/"
moss index -i "$work/repo"
test_moss repo add rex-gtk-local "file://$work/repo/stone.index"
test_moss repo add unstable https://cdn.aerynos.dev/ \
    --root-index channel=main,version=stream/unstable,arch=x86_64
test_moss repo update
test_moss -y pkg add rex-gtk

mv "$work/repo/$(basename "$baseline")" "$work/"
cp "$work/packages/rex-gtk-$version-1-1-x86_64.stone" "$work/repo/"
moss index -i "$work/repo"
test_moss repo update rex-gtk-local
test_moss sync --dry-run
test_moss -y sync
test_moss pkg list --installed | rg '^rex-gtk'
```

The dry run should show rex-gtk upgrading to the candidate version. Keep only one
rex-gtk package in the indexed directory when both versions use release `1`.

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

## License

MIT (see `LICENSE`). rex-gtk includes code derived from [Ghostty](https://github.com/ghostty-org/ghostty),
also under the MIT license; its notice is installed as `share/licenses/rex-gtk/LICENSE.ghostty`.
