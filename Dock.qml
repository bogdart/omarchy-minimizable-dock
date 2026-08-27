import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel

// A dock for Hyprland, hosted inside omarchy-shell as a keep-loaded panel
// plugin. It shows pinned launchers plus every open window grouped by app, and
// it is the other end of "minimize": Hyprland has no minimized state, so a
// minimized window is parked on the `special:minimized` workspace and the dock
// is what brings it back.
Item {
  id: root

  // ------------------------------------------------------- host injection
  // Set by the shell's panel loader once this plugin is mounted.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "bogdart.dock"

  // ------------------------------------------------------------- settings
  // The plugin's own entry in shell.json `plugins[]`. It hot-reloads with the
  // rest of the file, so edits take effect without restarting the shell.
  readonly property var settings: {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    var list = config && config.plugins ? config.plugins : null
    if (list && list.length !== undefined) {
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        if (entry && String(entry.id) === root.pluginId) return entry
      }
    }
    return ({})
  }

  function setting(key, fallback) {
    var value = settings ? settings[key] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string position: setting("position", "bottom") === "top" ? "top" : "bottom"
  readonly property bool autohide: setting("autohide", true) !== false
  readonly property int iconSize: Math.max(20, Math.min(96, Math.round(Number(setting("iconSize", 40)) || 40)))
  readonly property bool onlyCurrentWorkspace: setting("onlyCurrentWorkspace", false) === true
  readonly property bool showAppsButton: setting("appsButton", true) !== false
  // Icons redrawn in the theme's own two colours (see icon-mono.sh). Off
  // shows every app's icon as shipped.
  readonly property bool monochrome: setting("monochrome", true) !== false
  // Which colour the icons are drawn in: "frame" (the card's border colour,
  // so icons read as one piece with the dock) or "foreground" (the theme's
  // text colour).
  readonly property string monochromeColor: String(setting("monochromeColor", "frame")) === "foreground" ? "foreground" : "frame"
  readonly property real cardOpacity: {
    var value = Number(setting("opacity", 0.92))
    return isFinite(value) ? Math.max(0.3, Math.min(1, value)) : 0.92
  }
  // An explicit list always wins, including an empty one — unpinning
  // everything writes `[]` and must stay empty. Only a missing key falls back
  // to this system's own apps, so a dock installed from the menu opens with
  // something in it instead of a bare strip.
  readonly property var pinned: {
    var value = setting("pinned", null)
    if (value && value.length !== undefined) return value
    var out = []
    if (root.detectedTerminal) out.push(root.detectedTerminal)
    if (root.detectedBrowser) out.push(root.detectedBrowser)
    if (root.detectedFiles) out.push(root.detectedFiles)
    return out
  }
  // Window classes that should be treated as another app: Omarchy launches its
  // terminals and TUIs with synthetic app-ids (org.omarchy.terminal, TUI.float)
  // that have no desktop entry of their own.
  // Detected first, configured on top: a user alias overrides the default for
  // the same class, and everything else keeps working with no configuration.
  readonly property var aliases: {
    var out = ({})
    for (var key in root.defaultAliases) out[key] = root.defaultAliases[key]
    var value = setting("aliases", null)
    if (value && typeof value === "object")
      for (var extra in value) out[extra] = value[extra]
    return out
  }

  readonly property var defaultAliases: {
    var out = ({})
    var terminal = root.detectedTerminal
    if (terminal) {
      out["org.omarchy.terminal"] = terminal
      out["org.omarchy.bash"] = terminal
      out["TUI.float"] = terminal
    }
    if (root.entryIndex["btop"]) out["org.omarchy.btop"] = "btop"
    return out
  }
  // Shell-owned surfaces are real toplevels on Hyprland (the Omarchy
  // screensaver and lock windows among them) but they are not apps, so they
  // never belong in a dock. Configured ids extend this list.
  readonly property var ignoredClasses: {
    var ignored = ({ "org.quickshell": true, "org.omarchy.screensaver": true })
    var extra = setting("ignore", null)
    if (extra && extra.length !== undefined)
      for (var i = 0; i < extra.length; i++) ignored[String(extra[i]).toLowerCase()] = true
    return ignored
  }

  // -------------------------------------------------- this system's apps
  // Omarchy launches its terminals and TUIs with synthetic window classes
  // (org.omarchy.terminal, TUI.float) that have no desktop entry of their own,
  // so they only group under the right icon once they are pointed at whichever
  // terminal this system actually uses. The same answer, plus the default
  // browser and file manager, is what a dock with nothing configured pins.
  //
  // All of it is read straight from the XDG files rather than written into
  // shell.json by an installer, so a plugin installed from the menu — which
  // deliberately runs no setup script — behaves correctly with no setup at all.
  readonly property string homeDir: String(Quickshell.env("HOME") || "")

  property string detectedTerminal: ""
  property string detectedBrowser: ""
  property string detectedFiles: ""

  property string terminalsUserText: ""
  property string terminalsSystemText: ""
  property string mimeUserText: ""
  property string mimeSystemText: ""

  // "com.mitchellh.ghostty.desktop" per line, # comments, most preferred first.
  function parseTerminalsList(text) {
    var out = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var hash = line.indexOf("#")
      if (hash !== -1) line = line.substring(0, hash)
      line = line.replace(/\s+/g, "")
      if (line.length > 0) out.push(DockModel.stripDesktopSuffix(line))
    }
    return out
  }

  // "inode/directory=org.gnome.Nautilus.desktop", possibly several separated
  // by semicolons, under any section of a mimeapps.list.
  function parseMimeApps(text, key) {
    var out = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line.indexOf(key + "=") !== 0) continue
      var values = line.substring(key.length + 1).split(";")
      for (var v = 0; v < values.length; v++) {
        var id = DockModel.stripDesktopSuffix(values[v].replace(/\s+/g, ""))
        if (id.length > 0) out.push(id)
      }
    }
    return out
  }

  // The first candidate this system actually has a desktop entry for. Without
  // one there is nothing to launch, so an unknown id is no answer at all.
  function firstKnownEntry(ids) {
    for (var i = 0; i < ids.length; i++) {
      var entry = root.entryIndex[DockModel.normalizeKey(ids[i])]
      if (entry) return String(entry.id ? entry.id : ids[i])
    }
    return ""
  }

  function recomputeSystemApps() {
    var terminals = root.parseTerminalsList(root.terminalsUserText)
      .concat(root.parseTerminalsList(root.terminalsSystemText))
      // Nothing listed, or nothing listed that exists: fall back to the
      // terminals Omarchy is actually likely to have installed.
      .concat(["com.mitchellh.ghostty", "org.codeberg.dnkl.foot", "Alacritty",
               "kitty", "org.wezfurlong.wezterm"])
    root.detectedTerminal = root.firstKnownEntry(terminals)

    root.detectedBrowser = root.firstKnownEntry(
      root.parseMimeApps(root.mimeUserText, "x-scheme-handler/http")
        .concat(root.parseMimeApps(root.mimeUserText, "x-scheme-handler/https"))
        .concat(root.parseMimeApps(root.mimeSystemText, "x-scheme-handler/http"))
        .concat(root.parseMimeApps(root.mimeSystemText, "x-scheme-handler/https")))

    root.detectedFiles = root.firstKnownEntry(
      root.parseMimeApps(root.mimeUserText, "inode/directory")
        .concat(root.parseMimeApps(root.mimeSystemText, "inode/directory")))
  }

  FileView {
    path: root.homeDir + "/.config/xdg-terminals.list"
    watchChanges: true
    printErrors: false
    onLoaded: { root.terminalsUserText = text(); root.recomputeSystemApps() }
    onLoadFailed: { root.terminalsUserText = ""; root.recomputeSystemApps() }
    onFileChanged: reload()
  }

  FileView {
    path: "/etc/xdg/xdg-terminals.list"
    printErrors: false
    onLoaded: { root.terminalsSystemText = text(); root.recomputeSystemApps() }
    onLoadFailed: { root.terminalsSystemText = ""; root.recomputeSystemApps() }
  }

  FileView {
    path: root.homeDir + "/.config/mimeapps.list"
    watchChanges: true
    printErrors: false
    onLoaded: { root.mimeUserText = text(); root.recomputeSystemApps() }
    onLoadFailed: { root.mimeUserText = ""; root.recomputeSystemApps() }
    onFileChanged: reload()
  }

  FileView {
    path: "/usr/share/applications/mimeapps.list"
    printErrors: false
    onLoaded: { root.mimeSystemText = text(); root.recomputeSystemApps() }
    onLoadFailed: { root.mimeSystemText = ""; root.recomputeSystemApps() }
  }

  // ------------------------------------------------------------- geometry
  readonly property int pad: Style.space(6)
  readonly property int itemSpacing: Style.space(4)
  readonly property int indicatorZone: Style.space(8)
  readonly property int itemSize: iconSize + Style.space(10)
  // The indicator zone is split around the cell, so the icon sits exactly
  // in the vertical middle of the card; the dots then live in the strip
  // between the cell and the card's edge.
  readonly property int cardHeight: pad * 2 + itemSize + indicatorZone
  readonly property int edgeGap: Math.max(Style.gapsOut, Style.space(4))
  readonly property int triggerSize: Math.max(2, Style.space(3))
  readonly property int windowThickness: cardHeight + Math.max(edgeGap, triggerSize)

  // ----------------------------------------------------------- visibility
  // `opened` is the contract the shell host uses for `omarchy-shell shell
  // toggle bogdart.dock`; open()/close() are called by the same path.
  property bool hidden: false
  property bool peeking: false
  readonly property bool opened: !hidden
  // Name of the app under the pointer, for `omarchy-shell dock state`.
  property string hoveredName: ""
  // Live dock windows, one per screen, registered for `dock debug`.
  property var panels: []

  function registerPanel(panel) {
    var next = root.panels.slice()
    if (next.indexOf(panel) === -1) next.push(panel)
    root.panels = next
  }

  function unregisterPanel(panel) {
    var next = []
    for (var i = 0; i < root.panels.length; i++)
      if (root.panels[i] !== panel) next.push(root.panels[i])
    root.panels = next
  }

  function open(payloadJson) { root.hidden = false; return true }
  function close() { root.hidden = true; return true }

  // A peek exists for autohide mode: minimizing a window should show where it
  // went instead of swallowing it silently.
  function peek(durationMs) {
    peekTimer.interval = Number(durationMs) > 0 ? Number(durationMs) : 1400
    root.peeking = true
    peekTimer.restart()
  }

  Timer {
    id: peekTimer
    interval: 1400
    onTriggered: root.peeking = false
  }

  // -------------------------------------------------- desktop entry index
  // Built once from DesktopEntries and refreshed when the app set changes, so
  // window-class lookups never hit a warning-emitting byId() miss.
  property var entryIndex: ({})
  property var classIndex: ({})
  property var webappIndex: ({})
  property var resolveCache: ({})

  function rebuildIndexes() {
    var entries = DesktopEntries.applications && DesktopEntries.applications.values
      ? DesktopEntries.applications.values : []
    var byId = ({})
    var byClass = ({})
    var byUrl = ({})

    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry) continue
      byId[DockModel.normalizeKey(entry.id)] = entry

      var startupClass = String(entry.startupClass || "")
      if (startupClass) byClass[startupClass.toLowerCase()] = entry

      var token = DockModel.execToken(entry.execString)
      if (token) {
        if (!byUrl[token]) byUrl[token] = entry
        var host = DockModel.hostOf(token)
        if (host && !byUrl[host]) byUrl[host] = entry
      }
    }

    entryIndex = byId
    classIndex = byClass
    webappIndex = byUrl
    resolveCache = ({})
    root.recomputeSystemApps()
    scheduleRebuild()
  }

  function lookupEntry(id) {
    var candidates = DockModel.candidateIds(id)
    for (var i = 0; i < candidates.length; i++) {
      var hit = root.entryIndex[DockModel.normalizeKey(candidates[i])]
      if (hit) return hit
    }
    var byClass = root.classIndex[String(id || "").toLowerCase()]
    if (byClass) return byClass

    var token = DockModel.webappToken(id)
    if (token) {
      var webapp = root.webappIndex[token] || root.webappIndex[DockModel.hostOf(token)]
      if (webapp) return webapp
    }
    return null
  }

  function iconSourceFor(entry, fallbackId) {
    var name = entry && entry.icon ? String(entry.icon) : ""
    if (!name) {
      // No entry: the class itself is the best guess at an icon name, and its
      // trailing segment ("org.omarchy.btop" -> "btop") the next best.
      var candidates = DockModel.candidateIds(fallbackId)
      name = candidates.length > 0 ? candidates[candidates.length - 1] : ""
    }
    if (shell && shell.appLibrary && typeof shell.appLibrary.iconSource === "function")
      return shell.appLibrary.iconSource(name)
    var themed = name ? Quickshell.iconPath(name, true) : ""
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  // ------------------------------------------------- monochrome icons
  // Colourful app icons are re-rendered once per theme and size into
  // ~/.cache/<plugin id>/icons/ by icon-mono.sh, then served from there. The
  // cache key is the pair of theme colours the icons are drawn in, so a theme
  // change simply points at another folder (rendering it on first sight),
  // and an icon the dock has not seen before — a newly installed app — is
  // rendered the moment it appears. Until its rendering lands, the original
  // icon shows, so nothing is ever blank.
  function luminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }
  function hex(c) {
    function pair(v) {
      var n = Math.max(0, Math.min(255, Math.round(v * 255)))
      return (n < 16 ? "0" : "") + n.toString(16)
    }
    return "#" + pair(c.r) + pair(c.g) + pair(c.b)
  }
  // The ink the icons are drawn in, paired with the card background: the
  // darker of the two is the dark end of the ramp, so icons keep their own
  // light/dark structure whatever the theme.
  // The ink the icons are drawn in, paired with the card background: the
  // darker of the two is the dark end of the ramp, so an icon's body takes
  // the ink exactly and nothing in it reaches past it.
  readonly property color monoInk: root.monochromeColor === "foreground" ? Color.foreground : Color.popups.border
  readonly property color monoDark: luminance(Color.background) <= luminance(monoInk) ? Color.background : monoInk
  readonly property color monoLight: luminance(Color.background) <= luminance(monoInk) ? monoInk : Color.background
  // Rendered for the densest screen, so a HiDPI monitor never gets an upscaled
  // icon; a 1x screen simply downsamples.
  readonly property int monoPx: {
    var scale = 1
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++)
      scale = Math.max(scale, Number(screens[i].devicePixelRatio) || 1)
    return Math.ceil(root.iconSize * Math.min(3, scale))
  }
  readonly property string monoCacheDir: {
    var base = String(Quickshell.env("XDG_CACHE_HOME") || "")
    if (base.length === 0) base = Quickshell.env("HOME") + "/.cache"
    return base + "/" + root.pluginId + "/icons/" + root.monoPx + "-" + hex(root.monoDark).substring(1) + "-" + hex(root.monoLight).substring(1)
  }
  readonly property string monoScript: {
    var url = String(Qt.resolvedUrl("icon-mono.sh"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }
  // original icon source -> rendered file URL, for the current cache dir.
  property var monoBySource: ({})
  // Sources waiting for a render: keys of an object, so each is asked once.
  property var monoQueue: ({})
  property var monoCollected: ({})
  property bool monoRerun: false
  // The cache dir a running batch was started for; a batch that outlives a
  // theme change is answering for the wrong colours and is thrown away.
  property string monoRunDir: ""

  function monoSourceFor(source) {
    var original = String(source || "")
    if (!root.monochrome || original.length === 0) return original
    var rendered = root.monoBySource[original]
    return rendered ? rendered : original
  }

  function requestMono(sources) {
    if (!root.monochrome || monoSettle.running) return
    var added = false
    for (var i = 0; i < sources.length; i++) {
      var source = String(sources[i] || "")
      if (source.length === 0 || root.monoBySource[source] !== undefined) continue
      if (root.monoQueue[source]) continue
      root.monoQueue[source] = true
      added = true
    }
    if (added) monoDebounce.restart()
  }

  function runMonoBatch() {
    var sources = Object.keys(root.monoQueue)
    if (sources.length === 0) return
    if (monoProcess.running) {
      root.monoRerun = true
      return
    }
    root.monoCollected = ({})
    root.monoRunDir = root.monoCacheDir
    monoProcess.command = ["bash", root.monoScript, root.monoCacheDir, hex(root.monoDark), hex(root.monoLight), String(root.monoPx)].concat(sources)
    monoProcess.running = true
  }

  // A theme or size change moves the cache folder: forget every mapping and,
  // once the colours have settled, ask again for everything on the dock. The
  // wait matters: the shell starts on placeholder colours and a theme switch
  // reloads colors.toml and shell.toml separately, so the folder can move
  // twice within a few hundred milliseconds — rendering for the first would
  // be wasted work and a flash of the wrong colours.
  onMonoCacheDirChanged: {
    root.monoBySource = ({})
    root.monoQueue = ({})
    root.monoRerun = false
    monoSettle.restart()
  }
  Timer {
    id: monoSettle
    interval: 400
    onTriggered: root.requestMono(Object.keys(root.iconsByKey).map(function(k) { return root.iconsByKey[k] }))
  }
  onMonochromeChanged: {
    if (root.monochrome)
      root.requestMono(Object.keys(root.iconsByKey).map(function(k) { return root.iconsByKey[k] }))
  }

  Timer {
    id: monoDebounce
    interval: 40
    onTriggered: root.runMonoBatch()
  }

  Process {
    id: monoProcess
    stdout: SplitParser {
      onRead: function(line) {
        var tab = line.indexOf("\t")
        if (tab <= 0) return
        var source = line.substring(0, tab)
        var path = line.substring(tab + 1)
        if (path.length > 0) root.monoCollected[source] = "file://" + path
      }
    }
    onExited: function(exitCode) {
      var stale = root.monoRunDir !== root.monoCacheDir
      if (!stale) {
        var asked = root.monoProcessSources()
        var next = Object.assign({}, root.monoBySource)
        var queue = Object.assign({}, root.monoQueue)
        for (var i = 0; i < asked.length; i++) {
          var source = asked[i]
          // Remembered as "" when the script had nothing to say, so the dock
          // keeps the original icon instead of asking again every rebuild.
          next[source] = root.monoCollected[source] !== undefined ? root.monoCollected[source] : ""
          delete queue[source]
        }
        root.monoBySource = next
        root.monoQueue = queue
      }
      root.monoCollected = ({})
      if (root.monoRerun || stale) {
        root.monoRerun = false
        monoDebounce.restart()
      }
    }
  }

  function monoProcessSources() {
    var command = monoProcess.command || []
    return command.length > 6 ? command.slice(6) : []
  }

  function resolveMeta(rawId) {
    var raw = String(rawId || "").trim() || "unknown"
    if (root.resolveCache[raw]) return root.resolveCache[raw]

    var target = raw
    var alias = root.aliases[raw] || root.aliases[raw.toLowerCase()]
    if (alias) target = String(alias)

    var entry = root.lookupEntry(target)
    var meta = {
      key: entry ? DockModel.normalizeKey(entry.id) : DockModel.normalizeKey(target),
      entryId: entry ? String(entry.id) : "",
      name: entry ? String(entry.name || entry.id) : DockModel.prettyName(target),
      icon: root.iconSourceFor(entry, target)
    }
    root.resolveCache[raw] = meta
    return meta
  }

  // --------------------------------------------------------- window model
  property var groups: []
  property var items: []
  property var minimizedOrder: []
  // Addresses in most-recently-focused-first order. Tracked here rather than
  // read from `hyprctl clients` focus history so it stays correct without
  // re-querying Hyprland on every change.
  property var focusOrder: []
  // address -> the order it first appeared in. Gives every window a stable
  // position in its app's list for as long as it exists.
  property var windowSeq: ({})
  // address -> the workspace the window last lived on while visible. This is
  // where a restore sends it back to, however it was minimized (dock click or
  // SUPER+M alike) — not wherever the user happens to be at restore time.
  property var originWorkspace: ({})
  property int windowSeqNext: 1

  Timer {
    id: rebuildTimer
    interval: 24
    onTriggered: root.rebuild()
  }

  function scheduleRebuild() { rebuildTimer.restart() }

  function noteFocus(address) {
    var addr = String(address || "")
    if (!addr) return
    var next = [addr]
    for (var i = 0; i < root.focusOrder.length && next.length < 40; i++)
      if (root.focusOrder[i] !== addr) next.push(root.focusOrder[i])
    root.focusOrder = next
  }

  function focusRank(address) {
    var index = root.focusOrder.indexOf(String(address || ""))
    return index === -1 ? 1000 : index
  }

  function seqFor(address) {
    var known = root.windowSeq[address]
    if (known !== undefined) return known
    root.windowSeq[address] = root.windowSeqNext
    root.windowSeqNext++
    return root.windowSeq[address]
  }

  function rebuild() {
    root.rebuildCount++
    var toplevels = Hyprland.toplevels && Hyprland.toplevels.values ? Hyprland.toplevels.values : []
    var activeAddress = Hyprland.activeToplevel ? String(Hyprland.activeToplevel.address || "") : ""
    var list = []

    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel) continue
      var ipc = toplevel.lastIpcObject || ({})
      var workspace = toplevel.workspace
      var workspaceName = workspace ? String(workspace.name || "")
        : String((ipc.workspace && ipc.workspace.name) || "")
      var workspaceId = workspace ? Number(workspace.id)
        : Number((ipc.workspace && ipc.workspace.id) || 0)
      var appId = toplevel.wayland ? String(toplevel.wayland.appId || "") : ""
      if (!appId) appId = String(ipc.class || ipc.initialClass || "")
      if (root.ignoredClasses[appId.toLowerCase()]) continue
      var address = String(toplevel.address || "")

      var isMinimized = DockModel.isMinimizedWorkspace(workspaceName)
      if (!isMinimized && workspaceId > 0) root.originWorkspace[address] = workspaceId

      list.push({
        address: address,
        appId: appId,
        title: String(toplevel.title || ipc.title || ""),
        minimized: isMinimized,
        // Exactly one window can be focused, so when Hyprland names it that
        // name wins outright. ORing in the per-toplevel activated flag used to
        // let a second, stale flag mark another window focused, and then a
        // click minimized the wrong one. The flag is kept only as a fallback
        // for when nothing is named — focus parked on a layer surface, or the
        // instant before the first activewindow event arrives.
        activated: activeAddress !== ""
          ? address === activeAddress
          : (toplevel.wayland && toplevel.wayland.activated === true),
        focusRank: root.focusRank(address),
        seq: root.seqFor(address),
        workspaceId: workspaceId
      })
    }

    var focusedWorkspace = Hyprland.focusedWorkspace
    var built = DockModel.buildGroups(list, root.pinned, root.resolveMeta, {
      onlyCurrentWorkspace: root.onlyCurrentWorkspace,
      currentWorkspaceId: focusedWorkspace ? Number(focusedWorkspace.id) : -1
    })

    var seen = ({})
    var origins = ({})
    for (var k = 0; k < list.length; k++) {
      var liveAddress = list[k].address
      seen[liveAddress] = root.windowSeq[liveAddress]
      if (root.originWorkspace[liveAddress] !== undefined)
        origins[liveAddress] = root.originWorkspace[liveAddress]
    }
    root.windowSeq = seen
    root.originWorkspace = origins

    root.groups = built
    root.publishItems(DockModel.displayItems(built, { appsButton: root.showAppsButton }))
    root.updateEmptyScreens(list, focusedWorkspace)
    root.syncMinimizedOrder(list)
  }

  // `items` feeds the icon row and `groupsByKey` feeds the popups. Only the
  // first is throttled to structural changes: the row must stay put across
  // title churn, while an open window list should show titles as they change.
  property string itemsSignature: ""
  property int rebuildCount: 0
  property int publishCount: 0
  property var groupsByKey: ({})
  property var addressesByKey: ({})
  // Icons live outside the structural model so a late-resolving icon updates
  // in place instead of replacing the row.
  property var iconsByKey: ({})
  property var pendingItems: null
  property int deferredTicks: 0

  Timer {
    id: republishTimer
    interval: 350
    onTriggered: root.flushPendingItems()
  }

  // Anything the pointer is currently busy with. Rebuilding the icon row
  // under an open list or a hovered icon would pull it out from under the
  // pointer, so structural updates wait for the pointer to leave.
  function interactionActive() {
    for (var i = 0; i < root.panels.length; i++) {
      var panel = root.panels[i]
      if (panel && (panel.pointerInside || panel.listOpen || panel.menuOpen)) return true
    }
    return false
  }

  function flushPendingItems() {
    if (!root.pendingItems) return
    // Wait for the pointer to leave, but only briefly: a hover state that gets
    // stuck must never be able to freeze the icon row indefinitely.
    if (root.interactionActive() && root.deferredTicks < 3) {
      root.deferredTicks++
      republishTimer.restart()
      return
    }
    root.deferredTicks = 0
    var next = root.pendingItems
    root.pendingItems = null
    root.itemsSignature = DockModel.signature(next)
    root.publishCount++
    root.items = next
  }

  function publishItems(nextItems) {
    var byKey = ({})
    var addresses = ({})
    var icons = ({})
    for (var i = 0; i < nextItems.length; i++) {
      var item = nextItems[i]
      if (!item || item.separator) continue
      byKey[item.key] = item
      icons[item.key] = String(item.icon || "")

      // Reuse the previous array object when the window set is unchanged, so
      // the window list's rows survive a title-only update.
      var joined = []
      for (var w = 0; w < item.windows.length; w++) joined.push(item.windows[w].address)
      var previous = root.addressesByKey[item.key]
      addresses[item.key] = previous && previous.join(",") === joined.join(",") ? previous : joined
    }
    root.groupsByKey = byKey
    root.addressesByKey = addresses
    root.iconsByKey = icons
    root.requestMono(Object.keys(icons).map(function(k) { return icons[k] }))

    var signature = DockModel.signature(nextItems)
    if (signature === root.itemsSignature) {
      root.pendingItems = null
      return
    }
    if (root.interactionActive()) {
      root.pendingItems = nextItems
      republishTimer.restart()
      return
    }
    root.pendingItems = null
    root.deferredTicks = 0
    root.publishCount++
    root.itemsSignature = signature
    root.items = nextItems
  }

  function groupFor(key) {
    var group = root.groupsByKey[String(key || "")]
    return group === undefined ? null : group
  }

  // The icon row is a snapshot: it is only republished when the *structure*
  // changes (which apps, in what order, holding which windows), so the group
  // objects a cell was built from keep whatever focus and minimize state they
  // had at that moment — frozen, sometimes for minutes. Fine for drawing the
  // row, useless for deciding what a click means. Every action re-reads the
  // app by key so it acts on the window state as it is right now.
  function liveGroup(group) {
    if (!group || group.separator || group.appsButton) return group
    var live = root.groupFor(group.key)
    return live === null ? group : live
  }

  function windowFor(key, address) {
    var group = root.groupFor(key)
    if (!group) return null
    for (var i = 0; i < group.windows.length; i++)
      if (group.windows[i].address === address) return group.windows[i]
    return null
  }

  // An autohidden dock still shows itself on a bare desktop: with nothing on
  // the workspace there is nothing to hide from, and an empty screen is
  // exactly when the launchers are wanted. Computed per screen, since one
  // monitor can be empty while another is full.
  property var emptyScreens: ({})
  property bool focusedScreenEmpty: false

  function updateEmptyScreens(windows, focusedWorkspace) {
    var occupied = ({})
    for (var i = 0; i < windows.length; i++)
      if (!windows[i].minimized) occupied[String(windows[i].workspaceId)] = true

    var focusedId = focusedWorkspace ? String(focusedWorkspace.id) : ""
    var fallbackEmpty = focusedId === "" ? false : occupied[focusedId] !== true

    var next = ({})
    var monitors = Hyprland.monitors && Hyprland.monitors.values ? Hyprland.monitors.values : []
    for (var m = 0; m < monitors.length; m++) {
      var monitor = monitors[m]
      if (!monitor || !monitor.name) continue
      var workspace = monitor.activeWorkspace
      // No workspace on the monitor object means Hyprland has not reported one
      // yet; the focused workspace is the safer answer than "empty".
      next[String(monitor.name)] = workspace
        ? occupied[String(workspace.id)] !== true
        : fallbackEmpty
    }

    root.emptyScreens = next
    root.focusedScreenEmpty = fallbackEmpty
  }

  function screenIsEmpty(screenName) {
    var key = String(screenName || "")
    var known = key !== "" ? root.emptyScreens[key] : undefined
    return known === undefined ? root.focusedScreenEmpty : known === true
  }

  function syncMinimizedOrder(windows) {
    var present = ({})
    for (var i = 0; i < windows.length; i++)
      if (windows[i].minimized) present[windows[i].address] = true

    var next = []
    for (var j = 0; j < root.minimizedOrder.length; j++) {
      var known = root.minimizedOrder[j]
      if (present[known]) {
        next.push(known)
        delete present[known]
      }
    }

    var fresh = false
    for (var address in present) {
      next.push(address)
      fresh = true
    }
    root.minimizedOrder = next
    if (fresh && root.autohide && !root.hidden) root.peek(1400)
  }

  // ------------------------------------------------------------- actions
  // Hyprland 0.56 evaluates IPC dispatch requests as Lua, so these are Lua
  // expressions rather than the legacy "movetoworkspacesilent ..." strings.
  function addressToken(address) {
    var value = String(address || "")
    if (!value) return ""
    return value.indexOf("0x") === 0 ? value : "0x" + value
  }

  function moveToWorkspace(token, workspace) {
    var lua = 'hl.dsp.window.move({ workspace = "' + workspace + '"'
      + (token ? ', window = "address:' + token + '"' : "")
      + ", follow = false })"
    console.log("omarchy-dock: dispatch", lua)
    Hyprland.dispatch(lua)
  }

  function minimizeAddress(address) {
    var token = root.addressToken(address)
    if (!token) return false
    root.moveToWorkspace(token, DockModel.MINIMIZED_WORKSPACE)
    return true
  }

  function minimizeActive() {
    var active = Hyprland.activeToplevel
    if (active && active.address) return root.minimizeAddress(active.address)
    // No tracked active toplevel: let Hyprland resolve "the focused window".
    root.moveToWorkspace("", DockModel.MINIMIZED_WORKSPACE)
    return true
  }

  function restoreAddress(address) {
    var token = root.addressToken(address)
    if (!token) return false
    // Back to the workspace it was minimized from; focusing it then switches
    // the view there. Only a window with no remembered home (e.g. minimized
    // before the shell started) lands on the current workspace instead.
    var target = ""
    var origin = root.originWorkspace[String(address)]
    if (origin !== undefined && Number(origin) > 0) {
      target = String(origin)
    } else {
      var workspace = Hyprland.focusedWorkspace
      if (workspace) target = Number(workspace.id) > 0 ? String(workspace.id) : "name:" + String(workspace.name)
    }
    if (target) root.moveToWorkspace(token, target)
    root.focusAddress(address)
    return true
  }

  function restoreLast() {
    if (root.minimizedOrder.length === 0) return false
    return root.restoreAddress(root.minimizedOrder[root.minimizedOrder.length - 1])
  }

  function restoreAllMinimized() {
    var pending = root.minimizedOrder.slice()
    for (var i = 0; i < pending.length; i++) root.restoreAddress(pending[i])
    return pending.length
  }

  function focusAddress(address) {
    var token = root.addressToken(address)
    if (!token) return false
    console.log("omarchy-dock: dispatch focus address:" + token)
    Hyprland.dispatch('hl.dsp.focus({ window = "address:' + token + '" })')
    return true
  }

  function closeAddress(address) {
    var token = root.addressToken(address)
    if (!token) return false
    Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + token + '" })')
    return true
  }

  function launchGroup(group) {
    if (!group) return false
    if (group.entryId && shell && shell.appLibrary && typeof shell.appLibrary.launch === "function") {
      shell.appLibrary.launch(group.entryId, group.name)
      return true
    }
    if (group.entryId) {
      Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", group.entryId + ".desktop"])
      return true
    }
    return false
  }

  // Omarchy already has an app launcher; the dock's apps button opens that one
  // rather than growing a second one of its own.
  function openAppsMenu() {
    if (shell && typeof shell.toggle === "function") {
      shell.toggle("omarchy.menu", JSON.stringify({ menu: "apps" }))
      return true
    }
    Quickshell.execDetached(["omarchy-menu", "toggle", "apps"])
    return true
  }

  // The app's minimized window to bring back next: the one minimized most
  // recently, so repeated clicks undo minimizes in the order they were made.
  function nextMinimizedFor(group) {
    if (!group || !group.windows) return null
    var best = null
    var bestRank = -1
    for (var i = 0; i < group.windows.length; i++) {
      var win = group.windows[i]
      if (!win.minimized) continue
      var rank = root.minimizedOrder.indexOf(win.address)
      if (best === null || rank > bestRank) {
        best = win
        bestRank = rank
      }
    }
    return best
  }

  // Left click, in priority order:
  //
  //   1. nothing running        -> launch it
  //   2. this app holds focus   -> minimize the window that holds it
  //   3. a window is on screen  -> focus the one used most recently
  //   4. everything is parked   -> bring back the one minimized last
  //
  // On screen always beats minimized: while an app still has a visible window
  // to switch to, a click switches to it rather than digging another one out
  // of the minimized workspace. Only when nothing of the app is left on screen
  // does a click restore, one window per click, so a second parked window
  // stays reachable.
  //
  // Walking between windows of one app is the scroll wheel's job, not the
  // click's — a click on a focused app minimizes it, however many windows it
  // has, which is the half of this that never used to work.
  function activateGroup(group) {
    if (!group || group.separator) return
    if (group.appsButton) {
      root.openAppsMenu()
      return
    }
    group = root.liveGroup(group)
    if (!group.running) {
      root.launchGroup(group)
      return
    }
    var focused = DockModel.focusedWindow(group)
    if (focused) {
      root.minimizeAddress(focused.address)
      return
    }
    var primary = DockModel.primaryWindow(group)
    if (primary) {
      root.focusAddress(primary.address)
      return
    }
    var minimized = root.nextMinimizedFor(group)
    if (minimized) root.restoreAddress(minimized.address)
  }

  function minimizeGroup(group) {
    group = root.liveGroup(group)
    if (!group || !group.running) return
    for (var i = 0; i < group.windows.length; i++)
      if (!group.windows[i].minimized) root.minimizeAddress(group.windows[i].address)
  }

  function closeGroup(group) {
    group = root.liveGroup(group)
    if (!group || !group.running) return
    for (var i = 0; i < group.windows.length; i++) root.closeAddress(group.windows[i].address)
  }

  function cycleGroup(group, steps) {
    group = root.liveGroup(group)
    if (!group || !group.running) return
    var target = DockModel.cycleTarget(group, steps)
    if (!target) return
    if (target.minimized) root.restoreAddress(target.address)
    else root.focusAddress(target.address)
  }

  function isPinned(group) {
    if (!group) return false
    for (var i = 0; i < root.pinned.length; i++)
      if (DockModel.normalizeKey(root.pinned[i]) === group.key) return true
    return false
  }

  function togglePin(group) {
    if (!group || group.separator) return false
    var next = []
    var wasPinned = false
    for (var i = 0; i < root.pinned.length; i++) {
      var id = String(root.pinned[i])
      if (DockModel.normalizeKey(id) === group.key) {
        wasPinned = true
        continue
      }
      next.push(id)
    }
    if (!wasPinned) {
      // Only a desktop entry survives a restart as a launcher; a bare window
      // class has nothing to launch, so refuse rather than pin a dead icon.
      if (!group.entryId) return false
      next.push(group.entryId)
    }
    return root.persistSetting("pinned", next)
  }

  function persistSetting(key, value) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var next = ({})
    for (var existing in root.settings) if (existing !== "id") next[existing] = root.settings[existing]
    next[key] = value
    return shell.updateEntryInline(root.pluginId, next) === true
  }

  // ------------------------------------------------------------ liveness
  // Bind every toplevel's interesting properties so a title, workspace, or
  // focus change schedules a rebuild. Hyprland's ObjectModel only stays
  // populated while something holds it, which this also takes care of.
  Instantiator {
    model: Hyprland.toplevels

    delegate: QtObject {
      required property var modelData

      readonly property string workspaceName: modelData && modelData.workspace
        ? String(modelData.workspace.name || "") : ""
      readonly property string title: modelData ? String(modelData.title || "") : ""
      readonly property string appId: modelData && modelData.wayland
        ? String(modelData.wayland.appId || "") : ""
      readonly property bool activated: modelData && modelData.wayland
        ? modelData.wayland.activated === true : false

      onWorkspaceNameChanged: root.scheduleRebuild()
      onTitleChanged: root.scheduleRebuild()
      onAppIdChanged: root.scheduleRebuild()
      onActivatedChanged: {
        if (activated && modelData) root.noteFocus(modelData.address)
        root.scheduleRebuild()
      }
      Component.onCompleted: root.scheduleRebuild()
      Component.onDestruction: root.scheduleRebuild()
    }
  }

  // Same idea for monitors: hold the model so it stays populated, and rebuild
  // when a monitor switches workspace so the bare-desktop reveal follows.
  Instantiator {
    model: Hyprland.monitors

    delegate: QtObject {
      required property var modelData

      readonly property int workspaceId: modelData && modelData.activeWorkspace
        ? Number(modelData.activeWorkspace.id) : -1

      onWorkspaceIdChanged: root.scheduleRebuild()
      Component.onCompleted: root.scheduleRebuild()
    }
  }

  Connections {
    target: Hyprland

    function onActiveToplevelChanged() {
      if (Hyprland.activeToplevel) root.noteFocus(Hyprland.activeToplevel.address)
      root.scheduleRebuild()
    }
    function onFocusedWorkspaceChanged() { root.scheduleRebuild() }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.rebuildIndexes() }
  }

  Connections {
    target: shell && shell.appLibrary ? shell.appLibrary : null
    ignoreUnknownSignals: true
    function onAppsChanged() { root.rebuildIndexes() }
  }

  Component.onCompleted: {
    root.rebuildIndexes()
    Hyprland.refreshToplevels()
    root.claimLayerRule()
  }

  // The dock animates its own slide, so Hyprland must not animate the layer
  // surface a second time. Hyprland 0.56 refuses `hyprctl keyword` under its
  // Lua parser ("keyword can't work with non-legacy parsers, use eval"), so the
  // rule goes in through eval. Applying it here rather than asking the user to
  // paste a rule into looknfeel.lua keeps the plugin self-contained; it is
  // scoped to this dock's own namespace and touches nothing else.
  function claimLayerRule() {
    Quickshell.execDetached(["hyprctl", "eval",
      'hl.layer_rule({ match = { namespace = "omarchy-dock" }, no_anim = true, animation = "none" })'])
  }

  // Icon themes and desktop entries can land after the shell starts (a fresh
  // install finishing, an app installed mid-session); one late pass picks the
  // difference up without polling.
  Timer {
    running: true
    interval: 4000
    onTriggered: root.rebuildIndexes()
  }

  // ----------------------------------------------------------------- IPC
  IpcHandler {
    target: "dock"

    function toggle(): string {
      root.hidden = !root.hidden
      return root.hidden ? "hidden" : "shown"
    }
    function show(): string { root.hidden = false; return "shown" }
    function hide(): string { root.hidden = true; return "hidden" }
    function peek(): string { root.peek(1600); return "ok" }
    function minimize(): string { return root.minimizeActive() ? "ok" : "no window" }
    function restore(): string { return root.restoreLast() ? "ok" : "nothing minimized" }
    function restoreAll(): string { return "restored " + root.restoreAllMinimized() }
    function minimized(): string {
      var out = []
      for (var i = 0; i < root.groups.length; i++) {
        var group = root.groups[i]
        for (var w = 0; w < group.windows.length; w++)
          if (group.windows[w].minimized)
            out.push(group.name + " — " + group.windows[w].title)
      }
      return out.length > 0 ? out.join("\n") : "nothing minimized"
    }
    function state(): string {
      return JSON.stringify({
        hidden: root.hidden,
        autohide: root.autohide,
        position: root.position,
        items: root.items.length,
        minimized: root.minimizedOrder.length,
        hovered: root.hoveredName
      })
    }
    function activate(key: string): string {
      var group = root.groupFor(key)
      if (!group) return "no such app: " + key
      root.activateGroup(group)
      return "ok"
    }
    function windows(key: string): string {
      var group = root.groupFor(key)
      if (!group) return "no such app: " + key
      var out = []
      for (var i = 0; i < group.windows.length; i++) {
        var win = group.windows[i]
        out.push((i + 1) + ". " + DockModel.windowMarker(win).trim() + " " + (win.title || group.name)
          + "  [ws " + win.workspaceId + (win.minimized ? ", minimized" : "") + "]")
      }
      return out.length > 0 ? out.join("\n") : group.name + " has no windows"
    }
    function ping(): string { return "ok" }
    function debug(): string {
      var out = []
      for (var i = 0; i < root.panels.length; i++) {
        var panel = root.panels[i]
        out.push(JSON.stringify({
          screen: panel.screen ? panel.screen.name : "?",
          revealed: panel.revealed,
          desktopEmpty: panel.desktopEmpty,
          pointerInside: panel.pointerInside,
          surfaceHovered: panel.surfaceHovered,
          popupHovered: panel.popupHovered,
          listOpen: panel.listOpen,
          listPending: panel.listPending,
          hoveredKey: panel.hoveredKey,
          enters: panel.enterCount,
          rebuilds: root.rebuildCount,
          publishes: root.publishCount,
          exits: panel.exitCount,
          menuOpen: panel.menuOpen,
          peeking: root.peeking
        }))
      }
      return out.length > 0 ? out.join("\n") : "no dock windows"
    }
  }

  // ------------------------------------------------------------------ UI
  Variants {
    model: Quickshell.screens

    delegate: Component {
      DockPanel {
        required property var modelData
        screen: modelData
      }
    }
  }

  component DockPanel: PanelWindow {
    id: dockWindow

    // Pointer bookkeeping. The dock, its hover list, and its menu are three
    // separate Wayland surfaces, so the pointer leaves one to reach the next
    // and a popup mapping can bounce a leave/enter pair through the dock. All
    // three therefore feed one hover state, and letting go is always delayed:
    // without that, revealing would unmap the popup, which would re-reveal the
    // dock, in a loop.
    property bool surfaceHovered: false
    property bool popupHovered: false
    property int enterCount: 0
    property int exitCount: 0
    readonly property bool listPending: listDelay.running
    property bool pointerInside: false
    property bool menuOpen: false
    property bool listOpen: false
    property var hoveredItem: null
    property string hoveredKey: ""
    property var menuItem: null
    property string menuKey: ""

    // Derived from the live model rather than captured at hover time, so an
    // open list keeps showing current titles.
    readonly property var hoveredGroup: root.groupFor(dockWindow.hoveredKey)
    readonly property var menuGroup: root.groupFor(dockWindow.menuKey)

    readonly property bool hoverActive: surfaceHovered || popupHovered
    // Where the card sits with the dock out. Used for layout that must not
    // follow the slide animation.
    readonly property int cardRestY: root.position === "bottom"
      ? dockWindow.height - root.edgeGap - root.cardHeight
      : root.edgeGap
    readonly property bool desktopEmpty: root.screenIsEmpty(dockWindow.screen ? dockWindow.screen.name : "")
    readonly property bool revealed: !root.autohide || pointerInside || listOpen || menuOpen
      || root.peeking || desktopEmpty
    // Kept for the debug IPC's older field name.
    readonly property bool tooltipVisible: listOpen

    onHoverActiveChanged: {
      if (hoverActive) {
        releaseTimer.stop()
        dockWindow.pointerInside = true
      } else {
        releaseTimer.restart()
      }
    }

    visible: !root.hidden && !remapGuard.remapping && root.items.length > 0
    color: "transparent"
    surfaceFormat.opaque: false
    WlrLayershell.namespace: "omarchy-dock"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: root.autohide ? ExclusionMode.Ignore : ExclusionMode.Normal
    exclusiveZone: root.autohide ? 0 : root.cardHeight + root.edgeGap

    anchors {
      left: true
      right: true
      top: root.position === "top"
      bottom: root.position === "bottom"
    }
    implicitHeight: root.windowThickness

    // The layer surface spans the whole screen edge, but only the masked part
    // of it takes input: the dock card while revealed, plus the hairline along
    // the very edge that acts as the reveal trigger. The edge strip stays live
    // while revealed too — revealing from a corner would otherwise drop the
    // pointer out of the input region the instant the dock appeared, and the
    // dock would flap. Everything else stays click-through.
    mask: Region {
      item: dockWindow.revealed ? hitArea : triggerArea

      Region { item: triggerArea }
    }

    ScreenMoveRemap {
      id: remapGuard
      window: dockWindow
    }

    Component.onCompleted: root.registerPanel(dockWindow)
    Component.onDestruction: root.unregisterPanel(dockWindow)

    // Hovering an icon opens its window list. Moving on to another icon swaps
    // the list straight over — the wait is only there so sweeping across the
    // dock on the way somewhere else does not flash a list per icon.
    function setHovered(sourceItem, group, hovered) {
      if (hovered) {
        dockWindow.enterCount++
        dockWindow.hoveredItem = sourceItem
        dockWindow.hoveredKey = group && group.key ? String(group.key) : ""
        root.hoveredName = group && group.name ? String(group.name) : ""
        if (dockWindow.listOpen) listDelay.stop()
        else listDelay.restart()
      } else {
        dockWindow.exitCount++
        if (dockWindow.hoveredItem !== sourceItem || dockWindow.popupHovered) return
        // Leaving the icon closes nothing by itself — the pointer may be on
        // its way into the list, and a sliding dock can hand out a stray leave
        // while the pointer has not moved at all. Only a pointer that is off
        // the dock entirely cancels the pending list; releaseTimer handles the
        // rest.
        if (!dockWindow.surfaceHovered) listDelay.stop()
      }
    }

    function closeList() {
      dockWindow.listOpen = false
      dockWindow.hoveredItem = null
      dockWindow.hoveredKey = ""
      root.hoveredName = ""
      listDelay.stop()
    }

    function openMenu(sourceItem, group) {
      if (!group || group.separator) return
      dockWindow.closeList()
      dockWindow.menuItem = sourceItem
      dockWindow.menuKey = group && group.key ? String(group.key) : ""
      dockWindow.menuOpen = true
    }

    function closeMenu() {
      dockWindow.menuOpen = false
      dockWindow.menuItem = null
      dockWindow.menuKey = ""
    }

    // Hover state comes from three separate Wayland surfaces, so a missing
    // leave event is always possible. This notices that nothing is hovered any
    // more and lets go, instead of leaving the dock pinned open with a stale
    // window list in front of the icons.
    Timer {
      interval: 1200
      repeat: true
      running: dockWindow.pointerInside || dockWindow.listOpen
      onTriggered: {
        if (dockWindow.hoverActive || dockWindow.menuOpen) return
        dockWindow.pointerInside = false
        dockWindow.closeList()
      }
    }

    Timer {
      id: listDelay
      interval: 380
      onTriggered: dockWindow.listOpen = dockWindow.hoveredItem !== null
    }

    // One grace period covers both handing the pointer between surfaces and
    // the leave/enter churn a mapping popup can cause.
    Timer {
      id: releaseTimer
      interval: 380
      onTriggered: {
        if (dockWindow.hoverActive) return
        dockWindow.pointerInside = false
        if (!dockWindow.menuOpen) dockWindow.closeList()
      }
    }

    // Everything lives under one Item: pointer handlers only work when they
    // have an Item to attach to, and a handler declared straight on the window
    // would silently never fire.
    Item {
      id: inputRoot
      anchors.fill: parent

      HoverHandler {
        onHoveredChanged: dockWindow.surfaceHovered = hovered
        Component.onDestruction: dockWindow.surfaceHovered = false
      }

      Item {
        id: triggerArea
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.triggerSize
        y: root.position === "bottom" ? inputRoot.height - height : 0
      }

      Item {
        id: hitArea
        x: Math.round(Math.max(0, card.x - root.pad))
        width: Math.round(Math.min(inputRoot.width, card.width + root.pad * 2))
        y: 0
        height: inputRoot.height
      }

      BorderSurface {
        id: card

        width: Math.round(itemRow.implicitWidth + root.pad * 2)
        height: root.cardHeight
        anchors.horizontalCenter: parent.horizontalCenter
        y: dockWindow.revealed
          ? (root.position === "bottom" ? inputRoot.height - root.edgeGap - height : root.edgeGap)
          : (root.position === "bottom" ? inputRoot.height + Style.space(6) : -height - Style.space(6))
        color: Util.alpha(Color.background, root.cardOpacity)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius
        opacity: dockWindow.revealed ? 1 : 0

        Behavior on y {
          NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
        }
        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        Row {
          id: itemRow
          anchors.centerIn: parent
          spacing: root.itemSpacing

          Repeater {
            model: root.items

            delegate: DockItem {
              id: dockItem
              required property var modelData

              group: modelData
              live: root.groupsByKey[modelData.key]
              iconSource: {
                var live = root.iconsByKey[modelData.key]
                return root.monoSourceFor(live === undefined ? String(modelData.icon || "") : live)
              }
              iconSize: root.iconSize
              itemSize: root.itemSize
              indicatorZone: root.indicatorZone
              edgePad: root.pad
              dockPosition: root.position

              onActivateRequested: root.activateGroup(modelData)
              onLaunchRequested: root.launchGroup(modelData)
              onMenuRequested: dockWindow.openMenu(dockItem, modelData)
              onCycleRequested: function(steps) { root.cycleGroup(modelData, steps) }
              onHoverChanged: function(hovered) { dockWindow.setHovered(dockItem, modelData, hovered) }
            }
          }
        }
      }
    }

    // -------------------------------------------------------- window list
    // The hover popup is not a tooltip: its rows are clickable, so a specific
    // window can be picked by name.
    PopupWindow {
      id: windowList

      readonly property var group: dockWindow.hoveredGroup
      // Addresses, not window objects: the array keeps its identity across
      // title updates, so rows are not torn down under the pointer.
      readonly property var addresses: root.addressesByKey[dockWindow.hoveredKey] || []

      onImplicitHeightChanged: if (visible) listAnchor.updateAnchor()
      onImplicitWidthChanged: if (visible) listAnchor.updateAnchor()

      visible: dockWindow.listOpen && !dockWindow.menuOpen
        && dockWindow.hoveredItem !== null && windowList.group !== null && !windowList.group.separator
      color: "transparent"
      implicitWidth: Math.ceil(listCard.implicitWidth)
      implicitHeight: Math.ceil(listCard.implicitHeight)

      anchor {
        id: listAnchor
        window: dockWindow
        adjustment: PopupAdjustment.Slide
        edges: root.position === "bottom" ? Edges.Top : Edges.Bottom
        gravity: root.position === "bottom" ? Edges.Top : Edges.Bottom

        onAnchoring: {
          var item = dockWindow.hoveredItem
          if (!item) return
          // Anchor to where the icon rests, not to wherever the slide
          // animation has it right now.
          var inCard = card.mapFromItem(item, 0, 0)
          listAnchor.rect.x = Math.round(card.x + inCard.x)
          listAnchor.rect.y = Math.round(dockWindow.cardRestY + inCard.y)
          listAnchor.rect.width = Math.round(item.width)
          listAnchor.rect.height = Math.round(item.height)
        }
      }

      BorderSurface {
        id: listCard

        implicitWidth: Math.max(Style.space(190), listColumn.implicitWidth + contentLeftInset + contentRightInset)
        implicitHeight: listColumn.implicitHeight + contentTopInset + contentBottomInset
        anchors.fill: parent
        padding: Style.space(8)
        color: Color.tooltip.background
        borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, Math.max(1, Style.space(1)))
        radius: Style.cornerRadius

        HoverHandler {
          onHoveredChanged: dockWindow.popupHovered = hovered
          Component.onDestruction: dockWindow.popupHovered = false
        }

        Column {
          id: listColumn
          x: listCard.contentLeftInset
          y: listCard.contentTopInset
          width: listCard.width - listCard.contentLeftInset - listCard.contentRightInset
          spacing: Style.space(2)

          Text {
            text: windowList.group ? windowList.group.name : ""
            color: Color.tooltip.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Repeater {
            model: windowList.addresses

            delegate: Rectangle {
              id: listRow
              required property string modelData

              readonly property var win: root.windowFor(dockWindow.hoveredKey, listRow.modelData)

              visible: listRow.win !== null
              width: listColumn.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: listRowMouse.containsMouse ? Util.alpha(Color.tooltip.text, 0.14) : "transparent"

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                text: DockModel.windowMarker(listRow.win)
                  + (listRow.win ? (String(listRow.win.title || "").trim()
                    || (windowList.group ? windowList.group.name : "")) : "")
                color: Util.alpha(Color.tooltip.text, listRowMouse.containsMouse ? 1.0 : 0.8)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              MouseArea {
                id: listRowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor

                onClicked: function(mouse) {
                  var target = listRow.win
                  if (!target) return
                  // Act BEFORE closing. Closing clears hoveredKey, which
                  // empties the row model and destroys this very delegate —
                  // anything after that line would never run. That ordering
                  // bug is exactly why row clicks used to do nothing.
                  var address = target.address
                  if (mouse.button === Qt.RightButton) {
                    // Minimize exactly this window, and keep the list open so
                    // several can be parked one after another. Focus-follows-
                    // mouse makes "the focused window" a moving target by the
                    // time the pointer reaches the dock; the row names the
                    // window precisely.
                    root.minimizeAddress(address)
                    return
                  }
                  if (mouse.button === Qt.MiddleButton) {
                    // Close just this window and keep the list up, so several
                    // windows can be closed one after another. The row
                    // disappears on its own once the window is gone.
                    root.closeAddress(address)
                    return
                  }
                  if (target.minimized) root.restoreAddress(address)
                  else root.focusAddress(address)
                  Qt.callLater(function() { dockWindow.closeList() })
                }
              }
            }
          }

          Text {
            visible: windowList.group && !windowList.group.running && !windowList.group.appsButton
            text: "Not running"
            color: Util.alpha(Color.tooltip.text, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }

    // ------------------------------------------------------- context menu
    PopupWindow {
      id: contextMenu

      readonly property var group: dockWindow.menuGroup
      readonly property var addresses: root.addressesByKey[dockWindow.menuKey] || []
      readonly property var actions: {
        var out = []
        if (!group) return out
        if (group.entryId) out.push({ label: "New window", action: "launch" })
        if (group.running) {
          if (group.minimizedCount > 0) out.push({ label: "Restore all", action: "restore" })
          if (group.minimizedCount < group.windowCount) out.push({ label: "Minimize all", action: "minimize" })
        }
        out.push({ label: root.isPinned(group) ? "Unpin from dock" : "Pin to dock", action: "pin" })
        if (group.running) out.push({ label: group.windowCount > 1 ? "Close all windows" : "Close", action: "close" })
        return out
      }

      onImplicitHeightChanged: if (visible) menuAnchor.updateAnchor()
      onImplicitWidthChanged: if (visible) menuAnchor.updateAnchor()

      visible: dockWindow.menuOpen && contextMenu.group !== null
      color: "transparent"
      implicitWidth: Math.ceil(menuCard.implicitWidth)
      implicitHeight: Math.ceil(menuCard.implicitHeight)

      HyprlandFocusGrab {
        active: dockWindow.menuOpen
        windows: [contextMenu, dockWindow]
        onCleared: dockWindow.closeMenu()
      }

      anchor {
        id: menuAnchor
        window: dockWindow
        adjustment: PopupAdjustment.Slide
        edges: root.position === "bottom" ? Edges.Top : Edges.Bottom
        gravity: root.position === "bottom" ? Edges.Top : Edges.Bottom

        onAnchoring: {
          var item = dockWindow.menuItem
          if (!item) return
          var inCard = card.mapFromItem(item, 0, 0)
          menuAnchor.rect.x = Math.round(card.x + inCard.x)
          menuAnchor.rect.y = Math.round(dockWindow.cardRestY + inCard.y)
          menuAnchor.rect.width = Math.round(item.width)
          menuAnchor.rect.height = Math.round(item.height)
        }
      }

      function run(action) {
        // Act before closing: closeMenu() empties the action model, which
        // destroys the delegate whose click called this.
        var group = contextMenu.group
        if (group) {
          if (action === "launch") root.launchGroup(group)
          else if (action === "restore") {
            for (var i = 0; i < group.windows.length; i++)
              if (group.windows[i].minimized) root.restoreAddress(group.windows[i].address)
          } else if (action === "minimize") root.minimizeGroup(group)
          else if (action === "pin") root.togglePin(group)
          else if (action === "close") root.closeGroup(group)
        }
        Qt.callLater(function() { dockWindow.closeMenu() })
      }

      BorderSurface {
        id: menuCard

        implicitWidth: Math.max(Style.space(210), menuColumn.implicitWidth + contentLeftInset + contentRightInset)
        implicitHeight: menuColumn.implicitHeight + contentTopInset + contentBottomInset
        anchors.fill: parent
        padding: Style.space(6)
        color: Color.menu.background
        borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius

        HoverHandler {
          onHoveredChanged: dockWindow.popupHovered = hovered
          Component.onDestruction: dockWindow.popupHovered = false
        }

        Column {
          id: menuColumn
          x: menuCard.contentLeftInset
          y: menuCard.contentTopInset
          width: menuCard.width - menuCard.contentLeftInset - menuCard.contentRightInset
          spacing: Style.space(1)

          // One row per window, so a specific window can be raised or brought
          // back without cycling through the rest.
          Repeater {
            model: contextMenu.addresses

            delegate: Rectangle {
              id: windowRow
              required property string modelData

              readonly property var win: root.windowFor(dockWindow.menuKey, windowRow.modelData)

              visible: windowRow.win !== null
              width: menuColumn.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: windowRowMouse.containsMouse ? Color.menu.selectedBackground : "transparent"

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                text: DockModel.windowMarker(windowRow.win)
                  + (windowRow.win ? (String(windowRow.win.title || "").trim()
                    || (contextMenu.group ? contextMenu.group.name : "")) : "")
                color: windowRowMouse.containsMouse ? Color.menu.selectedText : Color.menu.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              MouseArea {
                id: windowRowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  var target = windowRow.win
                  if (!target) return
                  // Same ordering as the list rows: act first, then close —
                  // closing destroys this delegate mid-handler.
                  var address = target.address
                  if (mouse.button === Qt.RightButton) {
                    root.minimizeAddress(address)
                    return
                  }
                  if (mouse.button === Qt.MiddleButton) {
                    root.closeAddress(address)
                    return
                  }
                  if (target.minimized) root.restoreAddress(address)
                  else root.focusAddress(address)
                  Qt.callLater(function() { dockWindow.closeMenu() })
                }
              }
            }
          }

          Rectangle {
            visible: contextMenu.group && contextMenu.group.running
            width: menuColumn.width
            height: Math.max(1, Style.space(1))
            color: Util.alpha(Color.menu.text, 0.15)
          }

          Repeater {
            model: contextMenu.actions

            delegate: Rectangle {
              id: actionRow
              required property var modelData

              width: menuColumn.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: actionMouse.containsMouse ? Color.menu.selectedBackground : "transparent"

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                text: actionRow.modelData.label
                color: actionMouse.containsMouse ? Color.menu.selectedText : Color.menu.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: actionMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: contextMenu.run(actionRow.modelData.action)
              }
            }
          }
        }
      }
    }
  }
}
