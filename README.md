# Omarchy Minimizable Dock (`bogdart.dock`)

A dock for Hyprland, built as a third-party `omarchy-shell` panel plugin. No
extra packages: it runs inside the Quickshell process Omarchy already starts,
and drives Hyprland through its own IPC.

It shows pinned launchers plus every open window grouped by app, and it is the
other end of "minimize": Hyprland has no minimized window state, so a minimized
window is parked on the hidden `special:minimized` workspace and the dock is
what brings it back.

## Install

```bash
omarchy plugin add https://github.com/bogdart/omarchy-minimizable-dock.git --enable
```

That clones this repo into `~/.config/omarchy/plugins/bogdart.dock/`, validates
the manifest, and enables the plugin. Nothing in this repo runs at install time:
`omarchy plugin add` executes no hooks and never asks for sudo. Later,
`omarchy plugin update bogdart.dock` fast-forwards to the newest commit, and
`omarchy plugin remove bogdart.dock` takes it away again.

Requirements: Omarchy with the Quickshell shell (`$OMARCHY_PATH/shell`),
Hyprland 0.56 or newer (its Lua IPC is what minimize and focus use), and `jq`.
ImageMagick (`magick`, stock on Omarchy) renders the monochrome icons; without
it the dock falls back to the apps' own colour icons.

### Optional: keybindings, the layer rule, and pinned-app detection

Because `omarchy plugin add` runs nothing, three things it cannot do for you are
what `install.sh` in this repo is for:

```bash
./install.sh                # set up the extras
./install.sh --dry-run      # show what it would change, change nothing
./install.sh --uninstall    # remove the dock and every edit it made
```

It appends a marked block to `hypr/bindings.lua` (`SUPER + M`,
`SUPER + CTRL + M`, `SUPER + D`) and to `hypr/looknfeel.lua` (the dock's layer
rule), writes a `shell.json` entry whose pinned apps are detected from this
system's terminal, browser, and file manager — read from `xdg-terminals.list`,
`xdg-settings`, and `xdg-mime` — then reloads Hyprland, restarts the shell, and
checks that the dock answers IPC.

Every file it edits is backed up first and every edit is marked, so
`--uninstall` removes them without disturbing anything else in those files.
Re-running is safe: settings already in `shell.json` are kept (use
`--reset-config` to overwrite them) and the Hyprland blocks are added once.
Override the pinned apps with `--pinned "com.mitchellh.ghostty,chromium,obsidian"`,
and see `--help` for the rest (`--autohide`, `--no-keys`, `--no-restart`).

Running `install.sh` from a clone is also a complete install on its own, if you
would rather not use `omarchy plugin add`.

## Layout

```
[ pinned apps ] │ [ running apps that aren't pinned ] │ [ all apps ]
```

Each icon sits in the exact vertical middle of the card, with the same
breathing room above and below; the window dots live in the padding on the
screen-edge side.

The last cell opens Omarchy's own apps menu (the same one as
`SUPER + ALT + SPACE`); set `"appsButton": false` to drop it.

Under each icon:

| Indicator | Meaning |
|---|---|
| accent dot | that window is focused |
| filled dot | open window on some workspace |
| hollow dot + icon at half opacity | window is minimized (parked on `special:minimized`); the icon dims only when every window of the app is |
| no dot | pinned, not running |

One dot per window, up to four.

## Showing and hiding

By default the dock autohides: it slides away while a window is on the
workspace, and reveals itself when the pointer touches the bottom edge of the
screen. Two things bring it back on their own:

- **an empty workspace** — with nothing on screen there is nothing to hide
  from, so the dock simply stays up (per monitor, so a full screen next to a
  bare one behaves correctly);
- **minimizing a window** — the dock peeks for a moment so it is visible where
  the window just went.

Set `"autohide": false` to keep it on screen permanently instead; that mode
reserves its height, so windows tile above it.

## Mouse

| Action | Result |
|---|---|
| left click, not running | launch the app |
| left click, app holds focus | minimize the window that holds it, however many windows the app has |
| left click, a window is on screen | raise the most recently used one |
| left click, every window minimized | bring one back, most recently minimized first — click again for the next |
| middle click | new window / new instance |
| right click | menu: window list, new window, restore all, minimize all, pin/unpin, close |
| scroll | cycle that app's windows |
| hover | window list — per-window controls: left = switch/restore, right = minimize (list stays open), middle = close |

The hover list is reachable: it opens flush against the dock, the pointer can
walk from the icon into it, and the dock stays put while the pointer is inside
the list or the menu.

## Keys

Set in `~/.config/hypr/bindings.lua`:

| Key | Action |
|---|---|
| `SUPER + M` | minimize the active window to the dock |
| `SUPER + CTRL + M` | restore the most recently minimized window |
| `SUPER + D` | hide/show the dock |

`SUPER + M` is a plain Hyprland dispatcher, so minimizing keeps working even if
the shell is restarted; the dock only supplies the way back.

## Commands

```bash
omarchy-shell dock state        # position, autohide, item count, minimized count
omarchy-shell dock minimized    # list minimized windows
omarchy-shell dock minimize     # minimize the active window
omarchy-shell dock restore      # restore the most recently minimized window
omarchy-shell dock restoreAll   # restore every minimized window
omarchy-shell dock toggle       # hide/show
omarchy-shell dock peek         # reveal briefly (autohide mode)
omarchy-shell dock activate <app>  # act as if that icon were clicked
omarchy-shell dock debug        # per-screen reveal/hover state
```

## Configuration

The dock reads its own entry in `~/.config/omarchy/shell.json` under
`plugins[]`, and picks up edits to that file without a restart:

```json
{
  "id": "bogdart.dock",
  "position": "bottom",
  "autohide": true,
  "iconSize": 40,
  "opacity": 0.92,
  "monochrome": true,
  "onlyCurrentWorkspace": false,
  "appsButton": true,
  "pinned": ["com.mitchellh.ghostty", "chromium", "org.gnome.Nautilus", "obsidian"],
  "aliases": { "org.omarchy.terminal": "com.mitchellh.ghostty" },
  "ignore": []
}
```

| Key | Default | What it does |
|---|---|---|
| `position` | `bottom` | `bottom` or `top` |
| `autohide` | `true` | `true` parks the dock off-screen, revealing it on a pointer at that screen edge, on an empty workspace, and briefly after a minimize. `false` keeps it visible and reserves space so windows tile above it |
| `iconSize` | `40` | icon size in logical pixels (20–96) |
| `opacity` | `0.92` | dock background opacity |
| `monochrome` | `true` | redraw every icon in shades of one theme colour (see below). `false` shows the apps' icons as shipped |
| `monochromeColor` | `frame` | the ink: `frame` is the dock's border colour (the theme accent), `foreground` the theme's text colour |
| `onlyCurrentWorkspace` | `false` | `true` shows only windows on the focused workspace — minimized windows always show |
| `appsButton` | `true` | the trailing button that opens Omarchy's apps menu |
| `pinned` | — | desktop entry ids, in dock order. Right-click → Pin/Unpin edits this list for you |
| `aliases` | — | window class → desktop entry id, for windows whose class has no entry of its own (Omarchy launches terminals as `org.omarchy.terminal`) |
| `ignore` | `[]` | extra window classes to keep out of the dock (`org.quickshell` and `org.omarchy.screensaver` are always ignored) |

Pinned ids are desktop entry ids without `.desktop`; `omarchy plugin list` and
`ls /usr/share/applications ~/.local/share/applications` are the places to find
them.

## Monochrome icons

With `monochrome` on, every app icon is reduced to its luminance, normalised
so each icon spans the full range (a pale icon gets the same depth as a dark
one), and that luminance is mapped onto the ramp between one ink colour and
the theme background. The ink is the dock's own frame colour by default, so
an icon's body is exactly the frame's colour, its highlights fade toward the
background, and nothing in it is ever darker than the frame (on a dark
theme: brighter). `"monochromeColor": "foreground"` uses the theme's text
colour instead.

Renderings are produced once by `icon-mono.sh` (ImageMagick, plus
`rsvg-convert` for SVG sources) and cached in
`~/.cache/bogdart.dock/icons/<px>-<dark>-<light>/`, keyed by icon size and the
ramp's two colours, so the dock only pays for a render the first time it sees
an icon in a given theme:

- **theme change** — the shell's colours change, the cache key changes, and
  the dock renders the new set (the old one stays on disk, so switching back
  is instant);
- **a newly installed app** — its icon is rendered the moment it appears on
  the dock, and the original icon shows until then;
- **icon size, ink, or screen density change** — a new key, a new render.

A source that cannot be rendered keeps its original icon. Folders no theme
has used for two weeks are pruned automatically; delete the whole cache at
any time and it is rebuilt on the next shell start, and
`install.sh --uninstall` removes it.

## Notes

- Web app windows (Chromium `--app=`) are matched back to their Omarchy
  launcher by URL, so a pinned web app lights up when its window opens.
- Minimized windows survive on the special workspace; nothing unmaps them, so
  a video keeps playing and a build keeps running.
- Restoring returns a window to the workspace it was minimized from and
  focuses it there. Only a window with no remembered home (minimized before
  the shell started) falls back to the current workspace.
- `special:minimized` is deliberately separate from Omarchy's
  `special:scratchpad` (`SUPER + ALT + S`), so the two do not mix.
- Editing this plugin's QML: `shell.json` hot-reloads, but plugin code changes
  need `omarchy restart shell` to take effect reliably.
- A left click resolves in a fixed order: focused beats on-screen, and
  on-screen beats minimized. While an app still has a visible window to switch
  to, a click switches to it rather than digging another one out of the
  minimized workspace; only when nothing of the app is left on screen does a
  click restore, one window per click, so a second parked window stays
  reachable. Walking between an app's windows is the scroll wheel's job.
- A window parked on `special:minimized` never counts as focused, even though
  Hyprland can leave it as the active window when it was the last one on its
  workspace. Counting it would make a click minimize it again, with no way
  back.
- Only *which* icons exist and their order come from a snapshot, rebuilt when
  that structure changes; a snapshot is held back for at most a second while
  the pointer is on the dock so the row cannot reflow under a click. Everything
  the dock *reports* — window counts, focus, the minimized markers, titles,
  icons — is bound to live state, so what you see cannot drift from what
  Hyprland actually has. Every *action* re-reads the app by key for the same
  reason: the snapshot a cell was built from carries focus and minimize state
  frozen at that moment, which is fine for drawing the row and useless for
  deciding what a click means. A stuck pointer state can therefore never leave stale
  indicators on screen, and a watchdog releases hover if a leave event is ever
  missed.
- Files: `Dock.qml` (windows, actions, IPC), `DockItem.qml` (one icon),
  `DockModel.js` (class matching, grouping, and the structural signature).
