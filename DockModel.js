// Pure data helpers for the dock: window-class normalization, desktop-entry
// candidate ids, and the grouping pass that turns Hyprland toplevels into dock
// items. No QML types are referenced here, so this file stays testable from a
// bare quickshell config and cheap to reason about.

// The workspace minimized windows are parked on. Hyprland has no minimized
// state of its own, so a hidden special workspace stands in for one.
var MINIMIZED_WORKSPACE = "special:minimized"

function stripDesktopSuffix(value) {
  return String(value === undefined || value === null ? "" : value).trim().replace(/\.desktop$/i, "")
}

function normalizeKey(value) {
  return stripDesktopSuffix(value).toLowerCase()
}

function isMinimizedWorkspace(name) {
  return String(name || "") === MINIMIZED_WORKSPACE
}

// Chromium-family "--app=" windows carry a synthesized class such as
// "chrome-youtube.com__-Default". Collapsing the underscore runs makes the
// class comparable to the same treatment applied to a desktop entry's Exec
// URL, which is how an Omarchy web app window finds its launcher again.
function collapseToken(token) {
  return String(token || "").toLowerCase().replace(/_+/g, "_").replace(/^_+|_+$/g, "")
}

function webappToken(appId) {
  var match = /^(?:chrome|chromium|brave|brave-browser|microsoft-edge|msedge|vivaldi|opera|helium)-(.+)-Default$/i
    .exec(String(appId || ""))
  return match ? collapseToken(match[1]) : ""
}

function execToken(execString) {
  var match = /https?:\/\/(\S+)/i.exec(String(execString || ""))
  if (!match) return ""
  return collapseToken(String(match[1]).replace(/["']/g, "").replace(/[^A-Za-z0-9.]+/g, "_"))
}

// "google.com_maps" -> "google.com": the host alone is a weaker but still
// useful key when the path part of a web app URL does not survive round-trip.
function hostOf(token) {
  var value = String(token || "")
  if (!value) return ""
  return value.split("_")[0]
}

// Ids worth trying against the desktop-entry index for a window class, most
// specific first. A reverse-DNS class such as "org.omarchy.btop" is also tried
// as its trailing segment, which is usually the entry id ("btop").
function candidateIds(appId) {
  var raw = stripDesktopSuffix(appId)
  if (!raw) return []
  var out = [raw, raw.toLowerCase()]
  var dot = raw.lastIndexOf(".")
  if (dot > 0 && dot < raw.length - 1) {
    var tail = raw.slice(dot + 1)
    out.push(tail, tail.toLowerCase())
  }
  var result = []
  for (var i = 0; i < out.length; i++)
    if (out[i] && result.indexOf(out[i]) === -1) result.push(out[i])
  return result
}

function prettyName(appId) {
  var raw = stripDesktopSuffix(appId)
  if (!raw) return "Window"
  var token = webappToken(raw)
  if (token) return hostOf(token)
  var dot = raw.lastIndexOf(".")
  var tail = dot > 0 && dot < raw.length - 1 ? raw.slice(dot + 1) : raw
  return tail.charAt(0).toUpperCase() + tail.slice(1)
}

// windows: [{address, appId, title, minimized, activated, focusRank, workspaceId}]
// pinned:  raw ids from shell.json, in dock order
// resolve: (appId|desktopId) -> {key, entryId, name, icon}
// options: {onlyCurrentWorkspace, currentWorkspaceId}
function buildGroups(windows, pinned, resolve, options) {
  var opts = options || {}
  var groups = []
  var byKey = {}

  function ensure(meta, isPinned) {
    var key = meta && meta.key ? meta.key : "unknown"
    if (byKey[key]) {
      if (isPinned) byKey[key].pinned = true
      return byKey[key]
    }
    var group = {
      key: key,
      entryId: (meta && meta.entryId) || "",
      name: (meta && meta.name) || key,
      icon: (meta && meta.icon) || "",
      pinned: isPinned === true,
      separator: false,
      windows: []
    }
    byKey[key] = group
    groups.push(group)
    return group
  }

  var pinnedList = pinned || []
  for (var p = 0; p < pinnedList.length; p++) {
    var pinnedId = String(pinnedList[p] || "").trim()
    if (pinnedId) ensure(resolve(pinnedId), true)
  }

  var windowList = windows || []
  for (var w = 0; w < windowList.length; w++) {
    var win = windowList[w]
    if (!win) continue
    // A minimized window is never filtered out by the workspace filter: the
    // whole point of the dock is that it is the only place left to find it.
    if (opts.onlyCurrentWorkspace && !win.minimized && win.workspaceId !== opts.currentWorkspaceId) continue
    ensure(resolve(win.appId), false).windows.push(win)
  }

  var out = []
  for (var g = 0; g < groups.length; g++) {
    finalizeGroup(groups[g])
    if (groups[g].pinned || groups[g].windows.length > 0) out.push(groups[g])
  }
  return out
}

function finalizeGroup(group) {
  // Ordered by when each window appeared, never by focus. A list sorted by
  // recency re-orders itself the moment you pick something from it, so "the
  // second window" would mean a different window every time it is opened —
  // which makes choosing a specific window by position impossible.
  group.windows.sort(function(a, b) { return (a.seq || 0) - (b.seq || 0) })
  var minimized = 0
  var focused = false
  for (var i = 0; i < group.windows.length; i++) {
    if (group.windows[i].minimized) {
      minimized++
      // Never "focused": a parked window can keep the activated flag when it
      // was the focused one at the moment it was minimized, and treating that
      // as focus would make a click minimize it again — leaving no way back.
      continue
    }
    if (group.windows[i].activated) focused = true
  }
  group.windowCount = group.windows.length
  group.minimizedCount = minimized
  group.visibleCount = group.windows.length - minimized
  group.running = group.windows.length > 0
  group.focused = focused
  group.allMinimized = group.windows.length > 0 && minimized === group.windows.length
}

// Pinned groups always lead, so one divider between the last pinned item and
// the first unpinned running app is enough to keep the two zones legible.
// The apps button, when enabled, is divided off at the far end.
function displayItems(groups, options) {
  var opts = options || {}
  var pinnedCount = 0
  for (var i = 0; i < groups.length; i++) if (groups[i].pinned) pinnedCount++

  var items = []
  for (var j = 0; j < groups.length; j++) {
    if (j === pinnedCount && pinnedCount > 0)
      items.push({ key: "__separator", separator: true, windows: [] })
    items.push(groups[j])
  }

  if (opts.appsButton) {
    if (items.length > 0) items.push({ key: "__separator-apps", separator: true, windows: [] })
    items.push({ key: "__apps", appsButton: true, name: "All apps", windows: [] })
  }
  return items
}

// A fingerprint of the dock's *structure*: which items, in what order, and
// which windows they hold. No window *state* here — focus and minimize change
// constantly and are read live, so they must not rebuild the row. Titles and
// icon URLs are absent for the same reason. Both
// change without the row itself changing — a terminal rewrites its title on
// every spinner frame, and an icon's URL flips from a themed name to a file
// path once the shell's icon index finishes scanning. Rebuilding the row on
// those destroys and recreates every cell, which cancels hover, drops the
// window list, and reads as flicker. They are bound live instead.
function signature(items) {
  var parts = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (item.separator) {
      parts.push("sep")
      continue
    }
    if (item.appsButton) {
      parts.push("apps")
      continue
    }
    var windows = []
    for (var w = 0; w < item.windows.length; w++) windows.push(item.windows[w].address)
    parts.push([item.key, item.pinned ? "p" : "", windows.join(",")].join("|"))
  }
  return parts.join(";")
}

// Marker in front of a window title in the tooltip and the context menu.
// Plain geometric shapes rather than Nerd Font glyphs: these render the same
// in every theme font the shell might be using.
function windowMarker(win) {
  if (!win) return "•  "
  if (win.minimized) return "○  "
  if (win.activated) return "●  "
  return "•  "
}

// The window of this app that currently holds focus, if any. Minimized windows
// are skipped for the same reason finalizeGroup skips them.
function focusedWindow(group) {
  if (!group) return null
  for (var i = 0; i < group.windows.length; i++)
    if (group.windows[i].activated && !group.windows[i].minimized) return group.windows[i]
  return null
}

// The window a plain left click should raise: the most recently focused one
// that is still on a real workspace. Recency is read here rather than baked
// into the display order. Null when every window of the app is minimized —
// focusing a window parked on the hidden workspace does nothing visible, so
// the caller must restore one instead.
function primaryWindow(group) {
  if (!group) return null
  var best = null
  for (var i = 0; i < group.windows.length; i++) {
    var win = group.windows[i]
    if (win.minimized) continue
    if (best === null || (win.focusRank || 0) < (best.focusRank || 0)) best = win
  }
  return best
}

function firstMinimized(group) {
  if (!group) return null
  for (var i = 0; i < group.windows.length; i++)
    if (group.windows[i].minimized) return group.windows[i]
  return null
}

// Next window of a group relative to the focused one, for scroll-to-cycle.
function cycleTarget(group, steps) {
  if (!group || group.windows.length === 0) return null
  var visible = []
  for (var i = 0; i < group.windows.length; i++)
    if (!group.windows[i].minimized) visible.push(group.windows[i])
  if (visible.length === 0) return firstMinimized(group)

  var current = -1
  for (var v = 0; v < visible.length; v++) if (visible[v].activated) current = v
  var next = current === -1 ? 0 : (current + (steps > 0 ? 1 : -1) + visible.length) % visible.length
  return visible[next]
}
