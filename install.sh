#!/usr/bin/env bash
#
# Install this dock onto an Omarchy system.
#
#   ./install.sh                 install (or re-install) with detected defaults
#   ./install.sh --uninstall     remove the dock and everything it added
#   ./install.sh --help          full option list
#
# What it touches, all under $HOME:
#   ~/.config/omarchy/plugins/<id>/   the plugin itself
#   ~/.config/omarchy/shell.json      one entry in plugins[]
#   ~/.config/hypr/bindings.lua       a marked block of keybindings
#   ~/.config/hypr/looknfeel.lua      a marked layer rule
#
# Every edit is idempotent, marked, backed up first, and undone by --uninstall.

set -euo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_FILES=(manifest.json Dock.qml DockItem.qml DockModel.js icon-mono.sh README.md install.sh)

# Marked blocks so the Hyprland edits can be found again, skipped on re-install,
# and removed on uninstall without disturbing anything else in the file.
BLOCK_BEGIN="-- >>> dock plugin (installed by install.sh) >>>"
BLOCK_END="-- <<< dock plugin <<<"

DRY_RUN=0
NO_RESTART=0
UNINSTALL=0
WANT_AUTOHIDE="true"
WANT_PINNED=""
WANT_KEYS=1
RESET_CONFIG=0

info()  { printf '  %s\n' "$*"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn()  { printf '  \033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --uninstall           Remove the plugin, its shell.json entry, and its
                        Hyprland blocks, then restart the shell.
  --pinned "a,b,c"      Desktop entry ids to pin, in dock order. Default:
                        detected terminal, browser, and file manager.
  --autohide true|false Autohide the dock (default true; it still shows itself
                        on an empty workspace).
  --reset-config        Overwrite an existing shell.json entry with fresh
                        defaults. Without it, a re-install keeps the settings
                        already in shell.json and only adds missing keys.
  --no-keys             Do not touch ~/.config/hypr/bindings.lua.
  --no-restart          Do not reload Hyprland or restart omarchy-shell.
  --dry-run             Print what would change and exit.
  --help                This text.

Keys installed (unless --no-keys):
  SUPER + M          minimize the active window to the dock
  SUPER + CTRL + M   restore the most recently minimized window
  SUPER + D          hide/show the dock
USAGE
}

while (($#)); do
  case $1 in
    --uninstall) UNINSTALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --no-keys) WANT_KEYS=0 ;;
    --reset-config) RESET_CONFIG=1 ;;
    --pinned) shift; WANT_PINNED=${1-} ;;
    --pinned=*) WANT_PINNED=${1#*=} ;;
    --autohide) shift; WANT_AUTOHIDE=${1-} ;;
    --autohide=*) WANT_AUTOHIDE=${1#*=} ;;
    --help | -h) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

[[ $WANT_AUTOHIDE == true || $WANT_AUTOHIDE == false ]] || die "--autohide takes true or false"

# ---------------------------------------------------------------- preflight

((EUID != 0)) || die "run this as your own user, not root: the dock lives in \$HOME"

command -v jq >/dev/null || die "jq is required (Omarchy ships it: omarchy pkg add jq)"
# Monochrome icons are rendered by ImageMagick; without it the dock simply
# shows every app's own icon, so this is a warning rather than a stop.
command -v magick >/dev/null || warn "ImageMagick (magick) not found: icons stay in colour until it is installed (omarchy pkg add imagemagick)"

OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
[[ -d $OMARCHY_PATH ]] || die "Omarchy not found at $OMARCHY_PATH — is this an Omarchy system?"
[[ -f $OMARCHY_PATH/shell/shell.qml ]] || die \
  "this Omarchy has no Quickshell shell at $OMARCHY_PATH/shell — the dock is a shell plugin, so it needs a version of Omarchy that hosts one (run: omarchy update)"

for file in "${PLUGIN_FILES[@]}"; do
  [[ -f $SOURCE_DIR/$file ]] || die "missing $file next to install.sh (run this from the plugin folder)"
done

PLUGIN_ID=$(jq -r '.id // ""' "$SOURCE_DIR/manifest.json")
[[ -n $PLUGIN_ID ]] || die "manifest.json has no id"

PLUGINS_DIR="$HOME/.config/omarchy/plugins"
TARGET_DIR="$PLUGINS_DIR/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
SHELL_DEFAULTS="$OMARCHY_PATH/config/omarchy/shell.json"
HYPR_DIR="$HOME/.config/hypr"
BINDINGS_LUA="$HYPR_DIR/bindings.lua"
LOOKNFEEL_LUA="$HYPR_DIR/looknfeel.lua"

hypr_live() { command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; }

# The dock drives Hyprland over IPC, and Hyprland 0.56 changed that surface
# from dispatcher strings to Lua. Older versions would reject every call.
check_hyprland_version() {
  local tag major minor
  if hypr_live; then
    tag=$(hyprctl version -j 2>/dev/null | jq -r '.tag // ""')
  elif command -v Hyprland >/dev/null; then
    tag=$(Hyprland --version 2>/dev/null | sed -n 's/.*tag: \([^,]*\).*/\1/p' | head -1)
  fi
  if [[ -z ${tag:-} ]]; then
    warn "could not determine the Hyprland version; the dock needs 0.56 or newer"
    return 0
  fi
  tag=${tag#v}
  major=${tag%%.*}
  minor=${tag#*.}
  minor=${minor%%.*}
  if ((major == 0 && minor < 56)); then
    warn "Hyprland $tag is older than 0.56, whose Lua IPC the dock's minimize and focus calls use; minimizing will not work until you update"
  else
    info "Hyprland $tag"
  fi
}

backup() {
  local path=$1
  [[ -e $path ]] || return 0
  local copy="$path.bak.$(date +%Y%m%d%H%M%S)"
  ((DRY_RUN)) && { info "would back up $path -> $copy"; return 0; }
  cp -a "$path" "$copy"
  info "backed up $(basename "$path") -> $(basename "$copy")"
}

write_file() { # path, content on stdin — atomic, so a failure never leaves a half file
  local path=$1 tmp
  tmp=$(mktemp "$path.XXXXXX")
  cat > "$tmp"
  mv "$tmp" "$path"
}

# ------------------------------------------------------- app detection

desktop_dirs() {
  local dirs=("$HOME/.local/share/applications" "$HOME/.nix-profile/share/applications")
  local IFS=:
  local entry
  for entry in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
    dirs+=("$entry/applications")
  done
  printf '%s\n' "${dirs[@]}"
}

desktop_exists() {
  local id=${1%.desktop} dir
  [[ -n $id ]] || return 1
  while IFS= read -r dir; do
    [[ -f "$dir/$id.desktop" ]] && return 0
  done < <(desktop_dirs)
  return 1
}

first_existing() {
  local id
  for id in "$@"; do
    id=${id%.desktop}
    [[ -n $id ]] || continue
    desktop_exists "$id" && { printf '%s\n' "$id"; return 0; }
  done
  return 1
}

# Omarchy launches terminals through xdg-terminal-exec, so its preference list
# is the honest answer to "which terminal is this system's terminal".
detect_terminal() {
  local list line id
  for list in "$HOME/.config/xdg-terminals.list" /etc/xdg/xdg-terminals.list; do
    [[ -f $list ]] || continue
    while IFS= read -r line; do
      line=${line%%#*}
      line=$(printf '%s' "$line" | tr -d '[:space:]')
      [[ -n $line ]] || continue
      id=${line%.desktop}
      desktop_exists "$id" && { printf '%s\n' "$id"; return 0; }
    done < "$list"
  done
  first_existing com.mitchellh.ghostty org.codeberg.dnkl.foot Alacritty kitty org.wezfurlong.wezterm
}

detect_browser() {
  local id
  id=$(xdg-settings get default-web-browser 2>/dev/null | head -1 || true)
  first_existing "$id" chromium google-chrome brave-browser firefox
}

detect_files() {
  local id
  id=$(xdg-mime query default inode/directory 2>/dev/null | head -1 || true)
  first_existing "$id" org.gnome.Nautilus org.kde.dolphin thunar nemo
}

TERMINAL_ID=""
PINNED_JSON="[]"
ALIASES_JSON="{}"

detect_apps() {
  TERMINAL_ID=$(detect_terminal || true)

  local pinned=()
  if [[ -n $WANT_PINNED ]]; then
    local IFS=','
    local id
    for id in $WANT_PINNED; do
      id=$(printf '%s' "$id" | tr -d '[:space:]')
      id=${id%.desktop}
      [[ -n $id ]] || continue
      desktop_exists "$id" || warn "pinned entry '$id' has no .desktop file on this system; keeping it anyway"
      pinned+=("$id")
    done
  else
    local browser files
    browser=$(detect_browser || true)
    files=$(detect_files || true)
    [[ -n $TERMINAL_ID ]] && pinned+=("$TERMINAL_ID")
    [[ -n $browser ]] && pinned+=("$browser")
    [[ -n $files ]] && pinned+=("$files")
  fi

  PINNED_JSON=$(printf '%s\n' "${pinned[@]+"${pinned[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')

  # Omarchy gives its terminals synthetic app-ids with no desktop entry of
  # their own, so they are aliased onto whichever terminal this system uses.
  local aliases='{}'
  if [[ -n $TERMINAL_ID ]]; then
    aliases=$(jq -n --arg t "$TERMINAL_ID" \
      '{"org.omarchy.terminal": $t, "org.omarchy.bash": $t, "TUI.float": $t}')
  fi
  if desktop_exists btop; then
    aliases=$(printf '%s' "$aliases" | jq '. + {"org.omarchy.btop": "btop"}')
  fi
  ALIASES_JSON=$aliases
}

plugin_entry_json() {
  jq -n \
    --arg id "$PLUGIN_ID" \
    --argjson autohide "$WANT_AUTOHIDE" \
    --argjson pinned "$PINNED_JSON" \
    --argjson aliases "$ALIASES_JSON" \
    '{
      id: $id,
      position: "bottom",
      autohide: $autohide,
      iconSize: 40,
      opacity: 0.92,
      monochrome: true,
      onlyCurrentWorkspace: false,
      appsButton: true,
      pinned: $pinned,
      aliases: $aliases
    }'
}

# ------------------------------------------------------------ file edits

install_plugin_files() {
  step "Plugin files"
  if [[ $SOURCE_DIR == "$TARGET_DIR" ]]; then
    info "already at $TARGET_DIR (running from the installed copy)"
    return 0
  fi
  ((DRY_RUN)) && { info "would copy ${#PLUGIN_FILES[@]} files -> $TARGET_DIR"; return 0; }
  mkdir -p "$TARGET_DIR"
  local file
  for file in "${PLUGIN_FILES[@]}"; do
    cp -f "$SOURCE_DIR/$file" "$TARGET_DIR/$file"
  done
  chmod +x "$TARGET_DIR/install.sh" "$TARGET_DIR/icon-mono.sh"
  info "installed to $TARGET_DIR"
}

configure_shell_json() {
  step "shell.json"
  mkdir -p "$(dirname "$SHELL_JSON")"

  local seeded=0
  if [[ ! -f $SHELL_JSON ]]; then
    seeded=1
    if ((DRY_RUN)); then
      info "would seed $SHELL_JSON from $SHELL_DEFAULTS"
    elif [[ -f $SHELL_DEFAULTS ]]; then
      cp "$SHELL_DEFAULTS" "$SHELL_JSON"
      info "seeded from Omarchy defaults"
    else
      write_file "$SHELL_JSON" <<<'{ "version": 1, "plugins": [] }'
      info "created a minimal shell.json"
    fi
  fi

  if ((DRY_RUN)); then
    info "would set plugins[] entry:"
    plugin_entry_json | sed 's/^/    /'
    return 0
  fi

  jq empty "$SHELL_JSON" 2>/dev/null || die "$SHELL_JSON is not valid JSON; fix or move it and re-run"

  local entry current next
  entry=$(plugin_entry_json)
  current=$(jq -c --arg id "$PLUGIN_ID" '.plugins // [] | map(select(.id == $id)) | first // null' "$SHELL_JSON")

  # Defaults first, the existing entry on top: an upgrade picks up new keys
  # without reverting pinned apps, autohide, or anything else already tuned.
  if [[ $current != null ]] && ((!RESET_CONFIG)); then
    entry=$(jq -n --argjson defaults "$entry" --argjson existing "$current" --arg id "$PLUGIN_ID" \
      '$defaults + $existing + { id: $id }')
  fi

  next=$(jq --arg id "$PLUGIN_ID" --argjson entry "$entry" '
    .version = (.version // 1)
    | .plugins = (((.plugins // []) | map(select(.id != $id))) + [$entry])
  ' "$SHELL_JSON")

  if [[ $(jq -c . <<<"$next") == $(jq -c . "$SHELL_JSON") ]]; then
    info "entry already up to date"
    return 0
  fi

  ((seeded)) || backup "$SHELL_JSON"
  write_file "$SHELL_JSON" <<<"$next"
  if [[ $current != null ]]; then
    ((RESET_CONFIG)) && info "reset the $PLUGIN_ID entry to defaults" || info "updated the $PLUGIN_ID entry, keeping your settings"
  else
    info "added the $PLUGIN_ID entry"
  fi
  info "pinned: $(jq -r '.pinned | join(", ")' <<<"$entry")"
}

# Warn rather than fight: Omarchy owns these keys' defaults and they move
# between releases, so a conflict is the user's call, not the installer's.
warn_if_bound() {
  local modmask=$1 key=$2 label=$3 ours=$4
  hypr_live || return 0
  local existing
  existing=$(hyprctl binds -j 2>/dev/null | jq -r --argjson m "$modmask" --arg k "$key" '
    [ .[] | select(.modmask == $m and (.key | ascii_downcase) == ($k | ascii_downcase)) | .description // "" ]
    | map(select(. != "")) | first // ""')
  # A live binding with our own description is this installer's earlier run,
  # not a conflict.
  [[ -n ${existing:-} && $existing != "$ours" ]] \
    && warn "$label is already bound to \"$existing\"; the dock's binding will win — edit ~/.config/hypr/bindings.lua if you want the old one back"
  return 0
}

append_block() { # file, content
  local file=$1 content=$2
  if [[ -f $file ]] && grep -qF -e "$BLOCK_BEGIN" "$file"; then
    info "$(basename "$file"): block already present"
    return 0
  fi
  ((DRY_RUN)) && { info "would append a marked block to $file"; return 0; }
  [[ -f $file ]] || { mkdir -p "$(dirname "$file")"; : > "$file"; }
  backup "$file"
  printf '\n%s\n%s\n%s\n' "$BLOCK_BEGIN" "$content" "$BLOCK_END" >> "$file"
  info "$(basename "$file"): block appended"
}

remove_block() { # file
  local file=$1
  [[ -f $file ]] || return 0
  grep -qF -e "$BLOCK_BEGIN" "$file" || { info "$(basename "$file"): nothing to remove"; return 0; }
  ((DRY_RUN)) && { info "would remove the marked block from $file"; return 0; }
  backup "$file"
  local kept
  kept=$(awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    index($0, b) { skip = 1 }
    !skip { print }
    index($0, e) { skip = 0 }
  ' "$file")
  write_file "$file" <<<"$kept"
  info "$(basename "$file"): block removed"
}

configure_keys() {
  step "Keybindings"
  if ((!WANT_KEYS)); then
    info "skipped (--no-keys)"
    return 0
  fi
  warn_if_bound 64 m "SUPER + M" "Minimize window to dock"
  warn_if_bound 68 m "SUPER + CTRL + M" "Restore last minimized window"
  warn_if_bound 64 d "SUPER + D" "Toggle dock"

  append_block "$BINDINGS_LUA" "$(cat <<'LUA'
-- Hyprland has no minimized state, so "minimize" parks the window on the
-- hidden special:minimized workspace; the dock is what brings it back.
o.bind("SUPER + M", "Minimize window to dock", hl.dsp.window.move({ workspace = "special:minimized", follow = false }))
o.bind("SUPER + CTRL + M", "Restore last minimized window", "omarchy-shell dock restore")
o.bind("SUPER + D", "Toggle dock", "omarchy-shell dock toggle")

-- Also available:
-- o.bind("SUPER + ALT + M", "Restore all minimized windows", "omarchy-shell dock restoreAll")
-- o.bind("SUPER + ALT + D", "Peek at the dock", "omarchy-shell dock peek")
LUA
)"
}

configure_layer_rule() {
  step "Layer rule"
  append_block "$LOOKNFEEL_LUA" "$(cat <<'LUA'
-- The dock animates its own slide, so Hyprland should leave the layer surface
-- alone instead of animating it a second time.
hl.layer_rule({ match = { namespace = "omarchy-dock" }, no_anim = true, animation = "none" })
LUA
)"
}

apply() {
  step "Applying"
  if ((DRY_RUN)); then
    info "would reload Hyprland and restart omarchy-shell"
    return 0
  fi
  if ((NO_RESTART)); then
    info "skipped (--no-restart); run: hyprctl reload && omarchy restart shell"
    return 0
  fi

  if hypr_live; then
    hyprctl reload >/dev/null 2>&1 && info "Hyprland reloaded"
    local errors
    errors=$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]')
    [[ -n $errors ]] && warn "Hyprland reports config errors; check: hyprctl configerrors"
  else
    info "Hyprland is not running here; the config applies at next login"
  fi

  if command -v omarchy >/dev/null && hypr_live; then
    # Plugin QML is only picked up reliably by a full shell restart.
    omarchy restart shell >/dev/null 2>&1 || warn "could not restart omarchy-shell; run: omarchy restart shell"
    local deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
      if [[ $(omarchy-shell dock ping 2>/dev/null) == ok ]]; then
        info "dock is live: $(omarchy-shell dock state 2>/dev/null)"
        return 0
      fi
      sleep 1
    done
    warn "the shell restarted but the dock did not answer IPC; check: qs log -p \"$OMARCHY_PATH/shell\" --tail 40"
  fi
}

verify() {
  step "Verifying"
  if command -v omarchy >/dev/null && [[ $DRY_RUN -eq 0 ]]; then
    omarchy plugin validate "$TARGET_DIR" >/dev/null && info "manifest validates"
  fi
}

summary() {
  cat <<EOF

$(printf '\033[1mDone.\033[0m') The dock is at $TARGET_DIR

  SUPER + M          minimize the focused window to the dock
  SUPER + CTRL + M   restore the last minimized window
  SUPER + D          hide/show the dock

  Hover an icon for its window list; click a row to raise or restore it.
  Right-click an icon for new window / minimize / pin / close.
  The trailing button opens Omarchy's apps menu.

  Settings live in $SHELL_JSON under plugins[] (hot-reloads on save).
  Details: $TARGET_DIR/README.md
  Remove:  $TARGET_DIR/install.sh --uninstall
EOF
}

uninstall() {
  step "Removing the dock"
  if [[ -f $SHELL_JSON ]] && jq empty "$SHELL_JSON" 2>/dev/null; then
    if [[ $(jq -r --arg id "$PLUGIN_ID" '[.plugins // [] | .[] | select(.id == $id)] | length' "$SHELL_JSON") != 0 ]]; then
      if ((DRY_RUN)); then
        info "would drop the $PLUGIN_ID entry from shell.json"
      else
        backup "$SHELL_JSON"
        write_file "$SHELL_JSON" < <(jq --arg id "$PLUGIN_ID" '.plugins = ((.plugins // []) | map(select(.id != $id)))' "$SHELL_JSON")
        info "shell.json entry removed"
      fi
    else
      info "shell.json had no entry"
    fi
  fi

  remove_block "$BINDINGS_LUA"
  remove_block "$LOOKNFEEL_LUA"

  if [[ -d $TARGET_DIR ]]; then
    if ((DRY_RUN)); then
      info "would delete $TARGET_DIR"
    else
      rm -rf "$TARGET_DIR"
      info "deleted $TARGET_DIR"
    fi
  else
    info "no plugin directory to delete"
  fi

  local icon_cache="${XDG_CACHE_HOME:-$HOME/.cache}/$PLUGIN_ID"
  if [[ -d $icon_cache ]]; then
    if ((DRY_RUN)); then
      info "would delete $icon_cache"
    else
      rm -rf "$icon_cache"
      info "deleted $icon_cache (rendered icons)"
    fi
  fi

  apply
  printf '\nThe dock is gone. Backups of every edited file are next to it.\n'
}

# --------------------------------------------------------------------- main

if ((UNINSTALL)); then
  uninstall
  exit 0
fi

step "Checking the system"
info "Omarchy at $OMARCHY_PATH"
check_hyprland_version
detect_apps
[[ -n $TERMINAL_ID ]] && info "terminal: $TERMINAL_ID" || warn "no terminal desktop entry found; Omarchy's terminal windows may show a generic icon"

install_plugin_files
configure_shell_json
configure_keys
configure_layer_rule
apply
verify
((DRY_RUN)) && { printf '\nDry run: nothing was changed.\n'; exit 0; }
summary
