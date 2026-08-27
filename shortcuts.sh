#!/bin/bash
#
# shortcuts.sh — the dock's optional keyboard shortcuts.
#
# The dock itself needs nothing from this script. Installing the plugin from
# the Omarchy menu gives you a working dock: it detects this system's terminal,
# browser, and file manager for its own pinned defaults and aliases, and claims
# its own Hyprland layer rule at startup.
#
# Keybindings are the one thing a plugin genuinely cannot set up for itself,
# because they live in your Hyprland config and Omarchy — rightly — never runs
# code from a plugin. So that is all this script does:
#
#   SUPER + M          minimize the focused window to the dock
#   SUPER + CTRL + M   restore the last minimized window
#   SUPER + D          hide/show the dock
#
# It touches exactly one file, ~/.config/hypr/bindings.lua, appending a marked
# block. Your existing lines are never rewritten, the file is backed up first,
# and --uninstall removes the block and nothing else.
#
#   ./shortcuts.sh              add the keybindings
#   ./shortcuts.sh --dry-run    show what would change, change nothing
#   ./shortcuts.sh --uninstall  remove them again

set -euo pipefail

BINDINGS_LUA="$HOME/.config/hypr/bindings.lua"
BLOCK_BEGIN="-- >>> omarchy dock shortcuts >>>"
BLOCK_END="-- <<< omarchy dock shortcuts <<<"
# The marker used before this script was split out of a larger installer, so an
# older install can still be removed cleanly.
LEGACY_BEGIN="-- >>> dock plugin (installed by install.sh) >>>"
LEGACY_END="-- <<< dock plugin <<<"

DRY_RUN=0
UNINSTALL=0

info() { printf '  \033[32m•\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

((EUID != 0)) || die "run this as your regular user, not root — it only edits files in \$HOME"

while (($#)); do
  case "$1" in
  --dry-run) DRY_RUN=1 ;;
  --uninstall) UNINSTALL=1 ;;
  -h | --help)
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

hypr_live() { command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; }

backup() {
  local path=$1
  [[ -e $path ]] || return 0
  local copy="$path.bak.$(date +%Y%m%d%H%M%S)"
  ((DRY_RUN)) && { info "would back up $(basename "$path")"; return 0; }
  cp -a "$path" "$copy"
  info "backed up $(basename "$path") -> $(basename "$copy")"
}

# Warn rather than fight: these keys are the user's, and Omarchy's own defaults
# move between releases, so a conflict is their call and not this script's.
warn_if_bound() {
  local modmask=$1 key=$2 label=$3
  hypr_live || return 0
  command -v jq >/dev/null || return 0
  local existing
  existing=$(hyprctl binds -j 2>/dev/null | jq -r --argjson m "$modmask" --arg k "$key" '
    [ .[] | select(.modmask == $m and (.key | ascii_downcase) == ($k | ascii_downcase)) | .description // "" ]
    | map(select(. != "")) | first // ""') || return 0
  [[ -n ${existing:-} ]] &&
    warn "$label is already bound to \"$existing\" — the dock's binding is appended, so it wins; remove the block to get the old one back"
  return 0
}

remove_block() {
  [[ -f $BINDINGS_LUA ]] || { info "no bindings.lua to clean up"; return 0; }
  local begin=$BLOCK_BEGIN end=$BLOCK_END
  if ! grep -qF -e "$BLOCK_BEGIN" "$BINDINGS_LUA"; then
    if grep -qF -e "$LEGACY_BEGIN" "$BINDINGS_LUA"; then
      begin=$LEGACY_BEGIN
      end=$LEGACY_END
    else
      info "no dock shortcuts found"
      return 0
    fi
  fi
  ((DRY_RUN)) && { info "would remove the shortcuts block"; return 0; }
  backup "$BINDINGS_LUA"
  local kept
  kept=$(awk -v b="$begin" -v e="$end" '
    index($0, b) { skip = 1 }
    !skip { print }
    index($0, e) { skip = 0 }
  ' "$BINDINGS_LUA")
  local tmp
  tmp=$(mktemp "$BINDINGS_LUA.XXXXXX")
  printf '%s\n' "$kept" > "$tmp"
  mv "$tmp" "$BINDINGS_LUA"
  info "shortcuts removed"
}

add_block() {
  if [[ -f $BINDINGS_LUA ]] && grep -qF -e "$BLOCK_BEGIN" "$BINDINGS_LUA"; then
    info "shortcuts already present — nothing to do"
    return 0
  fi
  # An older install used a different marker; adding a second, identical block
  # on top of it would bind the same keys twice.
  if [[ -f $BINDINGS_LUA ]] && grep -qF -e "$LEGACY_BEGIN" "$BINDINGS_LUA"; then
    info "shortcuts from an earlier version are already present — nothing to do"
    info "run --uninstall first if you want them re-added under the current marker"
    return 0
  fi
  warn_if_bound 64 m "SUPER + M"
  warn_if_bound 68 m "SUPER + CTRL + M"
  warn_if_bound 64 d "SUPER + D"
  ((DRY_RUN)) && { info "would append the shortcuts block to bindings.lua"; return 0; }
  [[ -f $BINDINGS_LUA ]] || { mkdir -p "$(dirname "$BINDINGS_LUA")"; : > "$BINDINGS_LUA"; }
  backup "$BINDINGS_LUA"
  cat >> "$BINDINGS_LUA" <<LUA

$BLOCK_BEGIN
-- Hyprland has no minimized state, so "minimize" parks the window on the
-- hidden special:minimized workspace; the dock is what brings it back.
o.bind("SUPER + M", "Minimize window to dock", hl.dsp.window.move({ workspace = "special:minimized", follow = false }))
o.bind("SUPER + CTRL + M", "Restore last minimized window", "omarchy-shell dock restore")
o.bind("SUPER + D", "Toggle dock", "omarchy-shell dock toggle")

-- Also available:
-- o.bind("SUPER + ALT + M", "Restore all minimized windows", "omarchy-shell dock restoreAll")
-- o.bind("SUPER + ALT + D", "Peek at the dock", "omarchy-shell dock peek")
$BLOCK_END
LUA
  info "shortcuts added to bindings.lua"
}

reload() {
  ((DRY_RUN)) && { info "would reload Hyprland"; return 0; }
  if hypr_live; then
    hyprctl reload >/dev/null 2>&1 && info "Hyprland reloaded"
    local errors
    errors=$(hyprctl configerrors 2>/dev/null | tr -d '[:space:]')
    [[ -n $errors ]] && warn "Hyprland reports config errors; check: hyprctl configerrors"
  else
    info "Hyprland is not running here; the shortcuts apply at next login"
  fi
  return 0
}

if ((UNINSTALL)); then
  remove_block
  reload
  echo
  echo "Dock shortcuts removed. The dock itself is untouched — remove it from"
  echo "the Omarchy menu under Plugins if you want it gone too."
else
  add_block
  reload
  echo
  echo "  SUPER + M          minimize the focused window to the dock"
  echo "  SUPER + CTRL + M   restore the last minimized window"
  echo "  SUPER + D          hide/show the dock"
fi
