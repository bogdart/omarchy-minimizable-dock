#!/bin/bash
#
# icon-mono.sh — render app icons as theme-tinted monochrome PNGs, cached.
#
#   icon-mono.sh <cache-dir> <dark> <light> <px> <source>...
#
# Each source is an icon path (or file:// URL) as the dock resolved it. The
# icon is rasterised at <px> pixels, reduced to luminance, and that luminance
# is mapped onto the ramp <dark> -> <light> — the dock's frame colour and its
# background, darker first — so an icon's body takes the frame's exact colour
# and nothing in it is ever darker (on a dark theme: brighter) than that.
# A result lands in
# <cache-dir>, named after the source so the same icon is rendered once per
# theme and size, and is reused as long as it is newer than its source.
#
# For every source that ends up with a rendering, one line is printed:
#
#   <source><TAB><rendered-png-path>
#
# Sources that cannot be rendered (no file, unsupported scheme, a converter
# failure) print nothing and the dock falls back to the original icon. The
# exit status is always 0: a broken icon must not take the whole batch down.
#
# Needs ImageMagick (`magick`); SVG sources also use `rsvg-convert` when it is
# available and ImageMagick's own RSVG delegate otherwise.

set -u

(( $# >= 4 )) || exit 0
cache=$1 dark=$2 light=$3 px=$4
shift 4

command -v magick >/dev/null 2>&1 || exit 0
[[ $px =~ ^[0-9]+$ && $px -gt 0 ]] || exit 0
[[ $dark =~ ^#[0-9a-fA-F]{6}$ && $light =~ ^#[0-9a-fA-F]{6}$ ]] || exit 0

mkdir -p "$cache" 2>/dev/null || exit 0

# The ramp every icon's luminance is looked up in.
ramp=( \( -size 1x256 "gradient:${dark}-${light}" \) )

# Renders one rasterised, grey, alpha-preserving icon ($1) into $2.
#
# Luminance is normalised per icon first, so every icon spans the whole ramp:
# its darkest tone becomes the frame colour whether it shipped black or pale
# (Chromium's white-centred ring), and its brightest the background. The
# range is measured over opaque pixels only — `-auto-level` cannot be used,
# because transparent pixels carry garbage colour after a resize (wildly out
# of range on an HDRI build) and an icon's own soft drop shadow would
# otherwise pin the dark end. Then a gentle S-curve for body-versus-detail
# contrast and the lookup. Only RGB is touched: alpha is the icon's shape.
tint() {
  local gray=$1 out=$2 lo hi level=()
  lo=$(magick "$gray" \( +clone -alpha extract -threshold 50% -negate \) -alpha off -compose Lighten -composite -format '%[fx:100*minima]' info: 2>/dev/null)
  hi=$(magick "$gray" \( +clone -alpha extract -threshold 50% \) -alpha off -compose Darken -composite -format '%[fx:100*maxima]' info: 2>/dev/null)
  # A nearly flat icon (one tone, a thin outline) is left alone rather than
  # blown up into noise.
  if [[ -n $lo && -n $hi ]] && awk -v l="$lo" -v h="$hi" 'BEGIN { exit !(h - l > 20) }'; then
    level=(-level "${lo}%,${hi}%")
  fi
  magick "$gray" -background white -alpha background \
    -channel RGB "${level[@]}" -sigmoidal-contrast 4x50% +channel \
    "${ramp[@]}" -channel RGB -clut +channel "png32:$out" 2>/dev/null
}

urldecode() {
  local s=${1//+/ }
  printf '%b' "${s//%/\\x}"
}

# Icon theme lookup for the `image://icon/<name>` sources Quickshell hands
# out when no indexed file matched: the configured theme first (plus what it
# inherits), then hicolor and Adwaita, preferring a scalable SVG and otherwise
# the largest raster. Only ever runs on a cache miss.
icon_dirs=()
icon_themes=()
icon_theme_setup() {
  (( ${#icon_dirs[@]} )) && return
  local d t theme inherits
  [[ -d $HOME/.icons ]] && icon_dirs+=("$HOME/.icons")
  [[ -d $HOME/.local/share/icons ]] && icon_dirs+=("$HOME/.local/share/icons")
  local IFS=:
  for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
    [[ -d $d/icons ]] && icon_dirs+=("$d/icons")
  done
  unset IFS
  theme=$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'")
  [[ -n $theme ]] || theme=$(sed -n 's/^gtk-icon-theme-name *= *//p' "$HOME/.config/gtk-3.0/settings.ini" 2>/dev/null | head -1)
  icon_themes=()
  [[ -n $theme ]] && icon_themes+=("$theme")
  for d in "${icon_dirs[@]}"; do
    [[ -n $theme && -f $d/$theme/index.theme ]] || continue
    inherits=$(sed -n 's/^Inherits *= *//p' "$d/$theme/index.theme" | head -1)
    local IFS=,
    for t in $inherits; do icon_themes+=("$t"); done
    unset IFS
    break
  done
  icon_themes+=(hicolor Adwaita)
}

# Ranks candidate files: SVG beats any raster, rasters by pixel size (with
# @2x counting double), "scalable" dirs high; prints the best.
pick_best() {
  awk '
    {
      score = 0
      if ($0 ~ /\.svgz?$/) score = 1000000
      else if (match($0, /\/[0-9]+x[0-9]+(@[0-9]+x)?\//)) {
        seg = substr($0, RSTART + 1, RLENGTH - 2)
        split(seg, parts, /x|@/)
        score = parts[1] + 0
        if (seg ~ /@2x/) score *= 2
      }
      if (score > best) { best = score; path = $0 }
    }
    END { if (path != "") print path }
  '
}

resolve_icon_name() {
  local name=$1 d t found
  [[ $name =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
  icon_theme_setup
  for t in "${icon_themes[@]}"; do
    for d in "${icon_dirs[@]}"; do
      [[ -d $d/$t ]] || continue
      found=$(find "$d/$t" \( -name "$name.svg" -o -name "$name.svgz" -o -name "$name.png" \) 2>/dev/null | pick_best)
      [[ -n $found ]] && { printf '%s' "$found"; return 0; }
    done
  done
  for found in "/usr/share/pixmaps/$name.svg" "/usr/share/pixmaps/$name.png"; do
    [[ -f $found ]] && { printf '%s' "$found"; return 0; }
  done
  return 1
}

for source in "$@"; do
  path=$source
  # Cache entries are named after the source as the dock phrased it, so a
  # themed name maps to the same file every time without a lookup first.
  out="$cache/$(printf '%s' "$source" | sed 's|.*/||; s/\.\(png\|svgz\?\)$//; s/[^A-Za-z0-9._-]/_/g')-$(printf '%s' "$source" | md5sum | cut -c1-10).png"
  if [[ -f $out && $source == image://* ]]; then
    printf '%s\t%s\n' "$source" "$out"
    continue
  fi
  case $path in
    file://*) path=$(urldecode "${path#file://}") ;;
    image://icon/*) path=$(resolve_icon_name "$(urldecode "${path#image://icon/}")") || continue ;;
    /*) ;;
    *) continue ;;  # qrc:, another provider, a bare name — nothing to read
  esac
  [[ -f $path ]] || continue

  if [[ ! -f $out || $path -nt $out ]]; then
    tmp="$out.$$.tmp"
    gray="$out.$$.gray.png"
    ok=0
    # Rasterise at the target size and reduce to luminance; `-clamp` discards
    # the out-of-range values a resize leaves in transparent pixels.
    if [[ ${path,,} == *.svg || ${path,,} == *.svgz ]] && command -v rsvg-convert >/dev/null 2>&1; then
      rsvg-convert -w "$px" -h "$px" --keep-aspect-ratio "$path" 2>/dev/null \
        | magick png:- -clamp -colorspace Gray -colorspace sRGB "png32:$gray" 2>/dev/null && ok=1
    else
      magick -background none -density 384 "$path" -resize "${px}x${px}" -clamp -colorspace Gray -colorspace sRGB "png32:$gray" 2>/dev/null && ok=1
    fi
    (( ok )) && [[ -s $gray ]] && tint "$gray" "$tmp" || ok=0
    rm -f "$gray"
    if (( ok )) && [[ -s $tmp ]]; then
      mv -f "$tmp" "$out"
    else
      rm -f "$tmp"
      continue
    fi
  fi

  printf '%s\t%s\n' "$source" "$out"
done

# Housekeeping: every theme, ink, contrast, and size ever shown leaves its own
# folder. Mark this one as in use and drop siblings nothing has touched in two
# weeks — a theme switched back to sooner than that is still instant.
touch "$cache" 2>/dev/null
find "$(dirname "$cache")" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null

exit 0
