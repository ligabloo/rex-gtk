# Protocol notes

Facts about the Rex API that the reference (`docs/api/llms.txt`) leaves out, found by testing
against Rex server `0.1.0-preview.23` (API revision 19) on 2026-11-24.

## Snapshots

- Ghostty commit `74d1983f` decodes the server's terminal snapshots. `rexcat` output matched
  `rex capture --trim` for: a shell with colours, wide CJK characters and Nerd Font glyphs; a
  terminal resized to 100x30 by another client; the alternate screen (`ESC [?1049h`); and live
  output followed for 2.5 s while `top` redrew.
- A `resize` message arrives right after the snapshot, before any program output.

## `block.event` mouse payload

Not in `/api/help`. Field names and types come from the server's validation errors and struct tags.

```json
{"action": "press", "button": "left", "x": 5, "y": 3, "mods": "shift", "buttons": {"left": true}}
```

- `action`: `press`, `release` or `motion`.
- `button`: `left`, `right`, `middle`, or an extra button spelled as a word (`four`…`eleven`).
  Usually `unknown` for motion.
- `x`, `y`: **0-based cell column and row** within the block. `x=5, y=3` is reported to the
  program as column 6, row 4.
- `mods`: the same `shift+ctrl+alt+super` string format as `client.key`.
- `buttons`: the buttons held after the event, as `{"left": true}`. Motion with a button held is a drag.

## `block.event` wheel payload

```json
{"x": 2, "y": 2, "delta_x": 0, "delta_y": 3, "delta_mode": "line", "mods": ""}
```

- `delta_x`, `delta_y` (float), optional `delta_z`; positive `delta_y` scrolls down.
- `delta_mode`: `pixel`, `line` or `page`.
- `x`, `y`: cell coordinates as for mouse. With mouse reporting on, the server encodes the wheel
  reports itself.

## Selection

With mouse reporting off, the server selects text itself from forwarded mouse events: a drag
selects a range, a double click selects a word. It reports the text with a `selection_copied`
block event. It does **not** send the selection back on the data stream, so a client can't draw the
highlight from server state.

rex-gtk therefore selects locally (Ghostty's `SelectionGesture` on the mirror) and forwards mouse
events only while the program has turned on mouse reporting and Shift isn't held.
