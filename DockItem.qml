import QtQuick
import Quickshell
import qs.Commons

// One dock cell: an app icon, its window indicators, and the pointer handling.
// It carries no state of its own beyond hover — every decision about what a
// click means lives in Dock.qml, which owns the window model.
Item {
  id: item

  // `group` is the structural snapshot the icon row is built from; `live` is the
  // same app as it is right now. Everything the cell reports about windows
  // reads from `live`, so what the dock shows can never drift from reality —
  // only which cells exist, and their order, comes from the snapshot.
  property var group: null
  property var live: null
  readonly property var facts: (live !== null && live !== undefined) ? live : group
  property string iconSource: ""
  property int iconSize: 40
  property int itemSize: 50
  property int indicatorZone: 8
  // The card's padding beyond this cell; the window dots are centred in the
  // strip between the cell and the card's edge, on the dock's screen-edge side.
  property int edgePad: 6
  property string dockPosition: "bottom"

  readonly property bool isSeparator: !group || group.separator === true
  readonly property bool isAppsButton: !isSeparator && group.appsButton === true
  readonly property bool running: !isSeparator && !!facts && facts.running === true
  readonly property bool focused: !isSeparator && !!facts && facts.focused === true
  readonly property bool allMinimized: !isSeparator && !!facts && facts.allMinimized === true
  readonly property int windowCount: (isSeparator || !facts) ? 0 : (facts.windowCount || 0)
  readonly property bool pinnedItem: !isSeparator && !isAppsButton && !!facts && facts.pinned === true
  // A shell-owned window with no icon of its own draws as a font glyph
  // instead of an image, in the theme's foreground like the apps button.
  readonly property string glyph: (!isSeparator && !isAppsButton && facts && facts.glyph) ? String(facts.glyph) : ""
  // This cell is the source of an active drag: its icon stays in place but
  // dims, while the ghost in Dock.qml does the moving.
  property bool dragSource: false
  // Glyphs are drawn in the same ink the monochrome icons are rendered in, so
  // a glyph cell reads as one of the row rather than a stranger in it.
  property color glyphColor: Color.foreground

  signal activateRequested()
  signal launchRequested()
  signal menuRequested()
  signal cycleRequested(int steps)
  signal hoverChanged(bool hovered)
  signal reorderStarted()
  signal reorderMoved(real pointX)
  signal reorderEnded()

  implicitWidth: isSeparator ? Style.space(9) : itemSize
  implicitHeight: itemSize + indicatorZone
  width: implicitWidth
  height: implicitHeight

  // The cell sits in the middle of the item, so with the row centred in the
  // card the icon has the same breathing room above and below it.
  readonly property int cellY: Math.round(indicatorZone / 2)

  Rectangle {
    visible: item.isSeparator
    anchors.centerIn: parent
    width: Math.max(1, Style.space(1))
    height: Math.round(item.iconSize * 0.65)
    color: Util.alpha(Color.foreground, 0.22)
  }

  Rectangle {
    id: cell

    visible: !item.isSeparator
    width: item.itemSize
    height: item.itemSize
    x: 0
    y: item.cellY
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : Math.round(item.itemSize * 0.22)
    color: item.focused
      ? Util.alpha(Color.foreground, 0.16)
      : (pointer.containsMouse ? Util.alpha(Color.foreground, 0.09) : "transparent")
    border.width: item.focused ? Math.max(1, Style.space(1)) : 0
    border.color: Util.alpha(Color.accent, 0.45)

    Behavior on color {
      ColorAnimation { duration: 120 }
    }
  }

  // The apps button is the shell's own glyph rather than an app icon: it is a
  // door into Omarchy's menu, not an application.
  Text {
    visible: item.isAppsButton
    anchors.centerIn: cell
    text: "󰀻"
    font.family: Style.font.family
    font.pixelSize: Math.round(item.iconSize * 0.66)
    color: Color.foreground
    opacity: pointer.containsMouse ? 1.0 : 0.75
    scale: pointer.containsMouse ? 1.08 : 1.0

    Behavior on scale {
      NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }
    Behavior on opacity {
      NumberAnimation { duration: 130 }
    }
  }

  Image {
    id: icon

    visible: !item.isSeparator && !item.isAppsButton && item.glyph === ""
    anchors.centerIn: cell
    width: item.iconSize
    height: item.iconSize
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    // Decode at physical pixels so PNG icons stay sharp on HiDPI screens.
    sourceSize.width: Math.round(item.iconSize * Screen.devicePixelRatio)
    sourceSize.height: Math.round(item.iconSize * Screen.devicePixelRatio)
    source: (item.isSeparator || item.isAppsButton) ? "" : item.iconSource
    // A dimmed icon means "running but nothing on screen": every window of
    // this app is parked on the minimized workspace. Running and not running
    // look the same — the dots below tell them apart.
    opacity: item.dragSource ? 0.3 : (item.running && item.allMinimized ? 0.5 : 1.0)
    scale: pointer.containsMouse ? 1.08 : 1.0

    Behavior on scale {
      NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }
    Behavior on opacity {
      NumberAnimation { duration: 130 }
    }
  }

  Text {
    visible: !item.isSeparator && !item.isAppsButton && item.glyph !== ""
    anchors.centerIn: cell
    text: item.glyph
    font.family: Style.font.family
    font.pixelSize: Math.round(item.iconSize * 0.72)
    color: item.glyphColor
    opacity: item.running && item.allMinimized ? 0.5 : 1.0
    scale: pointer.containsMouse ? 1.08 : 1.0

    Behavior on scale {
      NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }
    Behavior on opacity {
      NumberAnimation { duration: 130 }
    }
  }

  Row {
    id: dots

    readonly property int dotSize: Math.max(3, Style.space(4))
    // Strip between the cell and the card's edge: the half indicator zone
    // inside this item plus the card's own padding outside it.
    readonly property int strip: (item.dockPosition === "bottom" ? item.indicatorZone - item.cellY : item.cellY) + item.edgePad
    readonly property int inset: Math.round((strip - dotSize) / 2)

    visible: item.running
    spacing: Style.space(3)
    anchors.horizontalCenter: cell.horizontalCenter
    y: item.dockPosition === "bottom"
      ? item.cellY + item.itemSize + inset
      : -item.edgePad + inset

    Repeater {
      model: Math.min(item.windowCount, 4)

      delegate: Rectangle {
        required property int index

        readonly property var win: item.facts && item.facts.windows ? item.facts.windows[index] : null

        width: dots.dotSize
        height: dots.dotSize
        radius: width / 2
        // Filled dot = mapped window, accented = focused, hollow = minimized.
        color: win && win.minimized
          ? "transparent"
          : (win && win.activated ? Color.accent : Util.alpha(Color.foreground, 0.6))
        border.width: win && win.minimized ? Math.max(1, Style.space(1)) : 0
        border.color: Util.alpha(Color.foreground, 0.5)
      }
    }
  }

  MouseArea {
    id: pointer

    enabled: !item.isSeparator
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    // Reorder drag. A pinned cell's press arms it; moving past the threshold
    // turns the press into a drag instead of a click. The MouseArea keeps its
    // grab for the whole drag, so position updates keep coming wherever the
    // pointer goes, and the click that would fire on release is swallowed.
    property real pressX: 0
    property real pressY: 0
    property bool reordering: false
    property bool swallowClick: false

    onEntered: item.hoverChanged(true)
    onExited: item.hoverChanged(false)

    onPressed: function(mouse) {
      pointer.swallowClick = false
      if (mouse.button === Qt.LeftButton) {
        pointer.pressX = mouse.x
        pointer.pressY = mouse.y
      }
    }

    onPositionChanged: function(mouse) {
      if (!(pointer.pressedButtons & Qt.LeftButton)) return
      if (!pointer.reordering) {
        if (!item.pinnedItem) return
        if (Math.abs(mouse.x - pointer.pressX) + Math.abs(mouse.y - pointer.pressY) < 14) return
        pointer.reordering = true
        pointer.swallowClick = true
        item.reorderStarted()
      }
      item.reorderMoved(mouse.x)
    }

    onReleased: function(mouse) {
      if (pointer.reordering) {
        pointer.reordering = false
        item.reorderEnded()
      }
    }

    onCanceled: {
      if (pointer.reordering) {
        pointer.reordering = false
        item.reorderEnded()
      }
    }

    onClicked: function(mouse) {
      if (pointer.swallowClick) {
        pointer.swallowClick = false
        return
      }
      if (mouse.button === Qt.MiddleButton) item.launchRequested()
      else if (mouse.button === Qt.RightButton) item.menuRequested()
      else item.activateRequested()
    }

    // Scrolling an icon walks that app's windows. High-resolution wheels emit
    // many small deltas per notch, so one step per cooldown keeps it usable.
    onWheel: function(wheel) {
      if (wheelCooldown.running) return
      var steps = wheel.angleDelta.y < 0 ? 1 : -1
      wheelCooldown.restart()
      item.cycleRequested(steps)
    }

    Timer {
      id: wheelCooldown
      interval: 160
    }
  }
}
