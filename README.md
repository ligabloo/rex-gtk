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
zig build run     # run the app
zig build test    # unit tests (no display needed)
```

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
