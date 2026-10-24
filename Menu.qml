import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import qs.services
import "MenuModel.js" as MenuModel

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon omarchy.menu ...` and close() when hidden.
  property string pendingInitialMenu: "root"

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    if (payload.mode === "select" || payload.mode === "input") {
      root.openDmenu(payload)
    } else {
      root.openRoute(payload.initialMenu || payload.menu || "root")
    }
  }

  // PS3-inspired XMB surface. The host creates this layer-shell window on the
  // focused output, matching the behavior of the packaged Omarchy menu.
  PanelWindow {
    id: panel
    visible: root.opened && root.rowsLoaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Compatibility hooks used by the retained menu/search model.
    property int cardTop: -1
    property int maxRowsHeight: -1
    function freezeCardTop() {}

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0.015, 0.035, 0.075, 0.70)

      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(0.03, 0.12, 0.24, 0.72) }
        GradientStop { position: 0.48; color: Qt.rgba(0.015, 0.045, 0.10, 0.66) }
        GradientStop { position: 1.0; color: Qt.rgba(0.0, 0.01, 0.04, 0.78) }
      }
    }

    // Slowly intersecting translucent ribbons, drawn only while the overlay is
    // visible. This keeps the organic XMB motion without shipping Sony assets
    // or continuously animating a hidden, keep-loaded plugin.
    Canvas {
      id: waveCanvas
      anchors.fill: parent
      antialiasing: true
      property real phase: 0

      function waveY(x, base, amplitude, cycles, offset, detail) {
        var t = x / Math.max(1, width)
        return height * (base
          + amplitude * Math.sin(t * Math.PI * 2 * cycles + phase + offset)
          + amplitude * detail * Math.sin(t * Math.PI * 2 * (cycles * 0.47) - phase * 0.62 + offset * 1.7))
      }

      function drawRibbon(ctx, base, amplitude, cycles, offset, thickness, red, green, blue, alpha) {
        var step = Math.max(18, width / 110)
        var x
        ctx.beginPath()
        ctx.moveTo(0, waveY(0, base, amplitude, cycles, offset, 0.42))
        for (x = step; x < width; x += step)
          ctx.lineTo(x, waveY(x, base, amplitude, cycles, offset, 0.42))
        ctx.lineTo(width, waveY(width, base, amplitude, cycles, offset, 0.42))

        for (x = width; x >= 0; x -= step) {
          var breathing = 0.76 + 0.24 * Math.sin((x / Math.max(1, width)) * Math.PI * 3 - phase + offset)
          ctx.lineTo(x, waveY(x, base, amplitude, cycles, offset, 0.42) + height * thickness * breathing)
        }
        ctx.closePath()

        var gradient = ctx.createLinearGradient(0, height * (base - amplitude), 0,
                                                height * (base + amplitude + thickness))
        gradient.addColorStop(0, "rgba(" + red + "," + green + "," + blue + ",0)")
        gradient.addColorStop(0.36, "rgba(" + red + "," + green + "," + blue + "," + alpha + ")")
        gradient.addColorStop(1, "rgba(" + red + "," + green + "," + blue + ",0)")
        ctx.fillStyle = gradient
        ctx.fill()
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        drawRibbon(ctx, 0.53, 0.055, 0.92, 0.2, 0.055, 72, 174, 255, 0.10)
        drawRibbon(ctx, 0.58, 0.040, 1.13, 2.3, 0.024, 168, 220, 255, 0.13)
        drawRibbon(ctx, 0.62, 0.072, 0.71, 4.5, 0.060, 35, 121, 232, 0.075)
        drawRibbon(ctx, 0.66, 0.045, 1.26, 1.1, 0.018, 204, 235, 255, 0.12)
        drawRibbon(ctx, 0.70, 0.060, 0.84, 3.4, 0.075, 49, 142, 238, 0.055)
      }

      onPhaseChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      NumberAnimation {
        target: waveCanvas
        property: "phase"
        from: 0
        to: Math.PI * 2
        duration: 22000
        loops: Animation.Infinite
        running: panel.visible
      }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    Item {
      id: card
      anchors.fill: parent
      anchors.leftMargin: Math.max(48, panel.width * 0.065)
      anchors.rightMargin: Math.max(48, panel.width * 0.065)
      anchors.topMargin: Math.max(70, panel.height * 0.12)
      anchors.bottomMargin: Math.max(48, panel.height * 0.08)
      readonly property real categoryAnchorCenterX: categoryList.selectedCenterX

      MouseArea { anchors.fill: parent; onClicked: {} }

      // Use compositor/Qt-provided deltas without adding a speed multiplier.
      // Touchpads report pixels while mouse wheels report angle units, so each
      // input type keeps its native scale and accumulates partial row steps.
      WheelHandler {
        id: menuWheel
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        enabled: panel.visible && !root.deleteConfirmOpen
        property real remainderY: 0
        property bool accumulatingPixels: false

        onEnabledChanged: {
          remainderY = 0
          accumulatingPixels = false
        }
        onWheel: function(event) {
          var usePixels = event.pixelDelta.y !== 0
          var delta = usePixels ? event.pixelDelta.y : event.angleDelta.y
          if (delta === 0) return

          if (remainderY !== 0 && accumulatingPixels !== usePixels)
            remainderY = 0
          accumulatingPixels = usePixels

          if (remainderY !== 0 && ((remainderY > 0) !== (delta > 0)))
            remainderY = 0
          remainderY += delta

          var stepSize = usePixels ? root.baseRowHeight : 120
          var steps = Math.floor(Math.abs(remainderY) / stepSize)
          if (steps === 0) {
            event.accepted = true
            return
          }

          var direction = remainderY > 0 ? -1 : 1
          remainderY -= (remainderY > 0 ? 1 : -1) * steps * stepSize
          root.select(direction * steps)
          event.accepted = true
        }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.deleteConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (root.dmenuActive) {
            if (root.handleDmenuKey(event)) event.accepted = true
            return
          }

          if (event.key === Qt.Key_Delete) {
            root.requestDeleteSelected()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.cancel()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Left && !root.filterText && root.activeMenu === "root") {
            root.selectCategory(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right && !root.filterText && root.activeMenu === "root") {
            root.selectCategory(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Left && !root.filterText) {
            if (root.activeMenuIsTopLevel()) root.selectCategory(-1)
            else if (!root.goBack()) root.selectCategory(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace && !root.filterText) {
            if (!root.goBack()) root.cancel()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            if (root.activeMenu !== "root" || root.filterText) root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            if (root.activeMenu === "root" && !root.filterText) root.previewCategory(false)
            else root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.activeMenu === "root" && !root.filterText) root.activateCategory(false)
            else if (root.dmenuActive && root.mode === "input") root.applyDmenuSelection(root.filterText)
            else if (displayModel.count > 0) root.activateIndex(root.cursorActive ? root.selectedIndex : 0)
            event.accepted = true
          } else if (event.key === Qt.Key_Right && !root.filterText) {
            if (root.activeMenuIsTopLevel()) root.selectCategory(1)
            else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: deleteConfirm
          anchors.centerIn: parent
          width: Math.min(parent.width, Style.space(520))
          height: Math.min(parent.height, Style.space(280))
          opened: root.deleteConfirmOpen
          z: 10
          message: "Do you want to uninstall " + ((root.deleteTarget && root.deleteTarget.label) || "") + "?"
          confirmText: "Uninstall"
          background: Qt.rgba(0.02, 0.07, 0.14, 0.96)
          foreground: "white"
          scrim: Qt.rgba(0, 0, 0, 0.6)
          selectedBackground: Qt.rgba(0.25, 0.68, 1.0, 0.42)
          selectedText: "white"
          fontFamily: root.fontFamily
          cornerRadius: Style.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }
      }

      Text {
        anchors.right: parent.right
        anchors.top: parent.top
        text: root.filterText && root.mode !== "input" ? "Search: " + root.filterText : "OMARCHY  /  XMB"
        color: "white"
        opacity: 0.72
        font.family: root.fontFamily
        font.pixelSize: Math.max(14, Style.font.body)
        font.letterSpacing: 1.5
      }

      Item {
        id: categoryList
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Math.max(56, panel.height * 0.08)
        height: Math.max(112, panel.height * 0.17)
        clip: false
        visible: !root.dmenuActive
        readonly property real delegateWidth: Math.max(88, panel.width * 0.072)
        readonly property real categoryStep: Math.max(108, panel.width * 0.08)
        // Leave room for earlier categories on the left. All delegates move
        // around this point, so the selected category never depends on a
        // Flickable's viewport or on whether a delegate is instantiated.
        readonly property real selectedCenterX: Math.min(
          width * 0.30,
          Math.max(width * 0.20, categoryStep * 2.15)
        )

        Repeater {
          model: categoryModel

          delegate: Item {
            id: category
            required property int index
            required property string itemId
            required property string kind
            required property string icon
            required property string iconFont
            required property string label
            required property string target
            required property string action
            readonly property int distance: Math.abs(index - root.categoryIndex)
            readonly property bool selected: distance === 0
            width: categoryList.delegateWidth
            height: categoryList.height
            x: categoryList.selectedCenterX
              + (index - root.categoryIndex) * categoryList.categoryStep
              - width / 2
            z: selected ? 2 : 1
            scale: selected ? 1.18 : 0.82
            opacity: selected ? 1.0 : (distance === 1 ? 0.56 : 0.38)
            visible: x + width > -categoryList.categoryStep
              && x < categoryList.width + categoryList.categoryStep

            Behavior on x { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 120 } }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              text: category.icon
              color: "white"
              font.family: category.iconFont.length ? category.iconFont : root.fontFamily
              font.pixelSize: Math.max(38, panel.height * 0.058)
              style: Text.Raised
              styleColor: Qt.rgba(0, 0, 0, 0.55)
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: 8
              text: category.label
              color: "white"
              font.family: root.fontFamily
              font.pixelSize: Math.max(13, Style.font.body)
              font.weight: category.selected ? Font.DemiBold : Font.Normal
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.categoryIndex = category.index
                root.activateCategory(true)
              }
            }
          }
        }
      }

      // A picker takes over the category band: its prompt sits where the
      // selected category would, and its options run through the same
      // vertical carousel as a submenu.
      Column {
        visible: root.dmenuActive
        x: Math.max(0, card.categoryAnchorCenterX - 27)
        width: Math.min(Math.max(420, panel.width * 0.34), parent.width - x)
        anchors.verticalCenter: categoryList.verticalCenter
        spacing: 10

        Text {
          width: parent.width
          text: root.dmenuPrompt
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Math.max(26, panel.height * 0.032)
          font.weight: Font.Light
          elide: Text.ElideRight
          style: Text.Raised
          styleColor: Qt.rgba(0, 0, 0, 0.55)
        }

        Text {
          width: parent.width
          visible: root.mode === "input"
          text: root.filterText + "▏"
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: 23
          font.weight: Font.DemiBold
          elide: Text.ElideLeft
        }

        Text {
          width: parent.width
          text: root.mode === "input"
            ? "Enter  confirm      Esc  cancel"
            : "Enter  select      Esc  cancel      Type to filter"
          color: Qt.rgba(1, 1, 1, 0.5)
          font.family: root.fontFamily
          font.pixelSize: 12
          font.letterSpacing: 1
        }
      }

      Column {
        anchors.left: parent.left
        anchors.leftMargin: Math.max(0, card.categoryAnchorCenterX - 27)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.min(Math.max(420, panel.width * 0.34), parent.width - x)
        spacing: 0
        visible: root.activeMenu !== "root" || root.filterText || root.dmenuActive

        Text {
          width: 0
          height: 0
          visible: false
          text: root.filterText || (root.dmenuActive ? root.dmenuPrompt : ((root.item(root.activeMenu) && (root.item(root.activeMenu).title || root.item(root.activeMenu).label)) || "Menu"))
          color: "white"
          opacity: 0.94
          font.family: root.fontFamily
          font.pixelSize: Math.max(22, Style.font.title)
          font.weight: Font.Light
          elide: Text.ElideRight
        }

        Rectangle { width: 0; height: 0; visible: false }

        Item {
          id: xmbResultList
          width: parent.width
          height: parent.height
          clip: true

          Repeater {
            model: displayModel

            delegate: Item {
              id: xmbRow
              required property int index
              required property string itemId
              required property string kind
              required property string icon
              required property string iconFont
              required property string appIcon
              required property string appId
              required property string label
              required property string target
              required property string detail
              required property string path
              required property string action
              required property int childCount

              readonly property bool selected: root.cursorActive && index === root.selectedIndex
              readonly property real selectedY: categoryList.y + categoryList.height + 12
              readonly property real rowStep: 52
              width: xmbResultList.width
              height: selected ? 72 : 48
              y: index < root.selectedIndex
                ? categoryList.y - (root.selectedIndex - index) * rowStep
                : (index === root.selectedIndex
                  ? selectedY
                  : selectedY + 72 + (index - root.selectedIndex - 1) * rowStep)
              visible: y + height > 0 && y < xmbResultList.height
              opacity: selected ? 1.0 : 0.48
              Behavior on y { NumberAnimation { duration: 145; easing.type: Easing.OutCubic } }
              Behavior on opacity { NumberAnimation { duration: 110 } }

              Image {
                id: xmbAppImage
                visible: xmbRow.kind === "app"
                width: xmbRow.selected ? 48 : 30
                height: width
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: visible && root.appLibrary ? root.appLibrary.iconSource(xmbRow.appIcon) : ""
                asynchronous: true
              }

              Text {
                id: xmbRowIcon
                visible: xmbRow.kind !== "app"
                width: xmbRow.selected ? 54 : 38
                height: parent.height
                anchors.left: parent.left
                text: xmbRow.icon || "•"
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.family: xmbRow.iconFont.length ? xmbRow.iconFont : root.fontFamily
                font.pixelSize: xmbRow.selected ? 42 : 24
                Behavior on font.pixelSize { NumberAnimation { duration: 120 } }
              }

              Column {
                anchors.left: parent.left
                anchors.leftMargin: xmbRow.selected ? 68 : 48
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                  width: parent.width
                  text: xmbRow.label
                  color: "white"
                  font.family: root.fontFamily
                  font.pixelSize: xmbRow.selected ? 23 : 17
                  font.weight: xmbRow.selected ? Font.DemiBold : Font.Normal
                  elide: Text.ElideRight
                  Behavior on font.pixelSize { NumberAnimation { duration: 120 } }
                }

                Text {
                  width: parent.width
                  visible: (root.filterText || root.dmenuActive) && xmbRow.detail.length > 0
                  text: xmbRow.detail
                  color: Qt.rgba(1, 1, 1, 0.55)
                  font.family: root.fontFamily
                  font.pixelSize: 12
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selectedIndex = xmbRow.index; root.activateIndex(xmbRow.index, true) }
              }
            }
          }

          Text {
            x: 48
            y: categoryList.y + categoryList.height + 12
            visible: root.dmenuActive && root.mode !== "input" && displayModel.count === 0
            text: root.filterText ? "No matches" : "Nothing here yet"
            color: "white"
            opacity: 0.62
            font.family: root.fontFamily
            font.pixelSize: 20
          }
        }
      }

    }
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    return "ok"
  }

  function ping() { return "ok" }

  property string fontFamily: Style.font.menuFamily
  // JSONC menu definitions. The shell parses both at startup and merges
  // the user file on top of the defaults, so the keybind → IPC → visible
  // path doesn't have to shell out to bash + jq on every open.
  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property bool opened: false
  property string mode: "menu"
  readonly property bool dmenuActive: mode === "select" || mode === "input"
  property string dmenuPrompt: ""
  property var dmenuOptions: []
  property string selectionFile: ""
  property string doneFile: ""
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0
  property bool requestActive: false
  property bool rowsLoaded: false
  property string activeMenu: "root"
  property string filterText: ""
  property int selectedIndex: 0
  property int categoryIndex: 0
  property bool cursorActive: false
  property int requestSerial: 0
  property int applySerial: 0
  property var items: ({})
  property var itemOrder: []
  property var navStack: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0

  // Shared application engine (entries, hidden filters, icons, launch,
  // removal), owned by the shell and also used by the standalone launcher.
  // Qt can turn manifest.kinds into a sequence while loading third-party
  // menus, causing the host to omit its scoped app library. Reuse the host's
  // engine so filtering, icons and launch feedback stay consistent.
  readonly property var appLibrary: root.shell && root.shell.appLibrary
    ? root.shell.appLibrary : fallbackAppLibrary.item
  onAppLibraryChanged: {
    if (root.appLibrary && root.providersLoaded["apps"]) root.mergeAppRows()
  }

  Loader {
    id: fallbackAppLibrary
    active: !!root.shell && !root.shell.appLibrary
    sourceComponent: Component {
      AppLibrary { omarchyPath: root.omarchyPath }
    }
  }
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  onOpenedChanged: if (!opened) { deleteConfirmOpen = false; deleteTarget = null }
  // Bound to the central [menu] section in shell.toml via Color.qml.
  // Each color already includes its alpha companion (composed in the
  // singleton), so consumers can drop them straight into a Rectangle.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  // How much of the first hidden row stays visible at the fold — enough to
  // read as a cut-off row rather than a bottom border.
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  property int rowSpacing: Style.spacing.xs
  property int dividerHeight: Style.space(17)
  property bool searchDivider: false
  property int layoutSerial: 0
  property int cardWidth: Math.min(root.dmenuActive ? Style.space(root.dmenuWidth) : ((root.activeMenu === "trigger.capture.screenrecord" || root.activeMenu === "style.font") ? Style.space(520) : Style.space(300)), panel.width - Style.gapsOut * 2)
  property int visibleRowsHeight: root.dmenuActive ? dmenuRowListHeight(layoutSerial, displayModel.count, filterText) : rowListHeight(layoutSerial, displayModel.count, filterText, searchDivider)
  property int cardHeight: root.dmenuActive
    ? Math.min(contentMargin * 2 + headerHeight + (mode === "input" ? 0 : contentSpacing + visibleRowsHeight), panel.height - Style.gapsOut * 2)
    : Math.min(contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight, panel.height - Style.gapsOut * 2)

  function finishRequest(selection) {
    if (!root.requestActive || !root.doneFile) {
      root.opened = false
      return
    }

    var activeSelectionFile = root.selectionFile
    var activeDoneFile = root.doneFile
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""

    if (selection === null || selection === undefined) {
      resultProc.command = ["bash", "-c", ": > " + Util.shellQuote(activeDoneFile)]
    } else {
      resultProc.command = ["bash", "-c", "printf '%s\\n' " + Util.shellQuote(selection) + " > " + Util.shellQuote(activeSelectionFile) + "; : > " + Util.shellQuote(activeDoneFile)]
    }
    resultProc.running = true
  }

  function runAction(action) {
    var command = String(action || "")
    if (!command) return

    Util.execDetached(command)
  }

  // Menu rows only surface their detail while a search is narrowing them;
  // dmenu rows carry caller-supplied subtext that must always be visible.
  function rowHeightForDetail(detail) {
    return (root.filterText || root.dmenuActive) && detail ? root.detailRowHeight : root.baseRowHeight
  }

  // Height the card can devote to rows before running off the screen — or
  // past the frozen top edge once a search has pinned the card in place.
  // Uses panel.cardTop rather than effectiveCardTop: the centered top is
  // derived from the card height, which this value feeds.
  function availableRowsHeight() {
    var top = panel.cardTop >= 0 ? panel.cardTop : Style.gapsOut
    var available = panel.height - top - Style.gapsOut - root.contentMargin * 2 - root.headerHeight - root.contentSpacing
    // The starting menu sets the ceiling along with the offset: drilling into
    // a longer submenu scrolls behind the fold instead of growing the card.
    if (panel.maxRowsHeight >= 0) available = Math.min(available, panel.maxRowsHeight)
    // A card that swallows the whole screen reads as a page, not a menu.
    return Math.min(available, Math.round(panel.height * 0.7))
  }

  // When every row fits, the list gets its full height. When they don't,
  // the card must end mid-row: a clipped row is what tells the eye there is
  // more below the fold, so never come out even on a row boundary.
  function foldedListHeight(totals, available) {
    var count = totals.length
    if (count === 0) return root.baseRowHeight
    if (totals[count - 1] <= available) return totals[count - 1]

    var peek = root.rowPeek
    var full = 0
    while (full < count && totals[full] <= available) full++
    while (full > 1 && totals[full - 1] + root.rowSpacing + peek > available) full--
    if (full < 1) return Math.max(available, root.baseRowHeight)

    return totals[full - 1] + root.rowSpacing + peek
  }

  function rowListHeight(_serial, _count, _filter, _divider) {
    if (displayModel.count === 0) return root.baseRowHeight

    var totals = []
    var total = 0
    var previousSection = ""

    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (i > 0) total += root.rowSpacing
      if (row.section === "drilldown" && previousSection !== "drilldown") total += root.dividerHeight
      total += root.rowHeightForDetail(row.detail)
      previousSection = row.section
      totals.push(total)
    }

    return foldedListHeight(totals, availableRowsHeight())
  }

  function dmenuRowListHeight(_serial, _count, _filter) {
    if (root.mode === "input") return 0
    if (displayModel.count === 0) return root.baseRowHeight

    var available = availableRowsHeight()
    if (root.dmenuMaxHeight > 0) available = Math.min(available, Style.space(root.dmenuMaxHeight))

    var totals = []
    var total = 0
    for (var i = 0; i < displayModel.count; i++) {
      if (i > 0) total += root.rowSpacing
      total += root.rowHeightForDetail(displayModel.get(i).detail)
      totals.push(total)
    }

    return foldedListHeight(totals, available)
  }

  function item(id) {
    return root.items[id] || null
  }

  // ------------------------------------------------------------------
  // JSONC → normalized item array. Mirrors the bash bin's jq pipeline so
  // the on-disk authoring format stays untouched.
  // ------------------------------------------------------------------

  function stripJsonc(raw) {
    return MenuModel.stripJsonc(raw)
  }

  function normalizeAliases(value) {
    return MenuModel.normalizeAliases(value)
  }

  function normalizeItem(id, raw) {
    return MenuModel.normalizeItem(id, raw)
  }

  function parseMenuJsonc(raw) {
    return MenuModel.parseMenuJsonc(raw)
  }

  // Merge defaults + user extension. Later entries override earlier ones
  // on a per-key basis (so the user can tweak label/icon/action without
  // re-declaring the whole row).
  function rebuildItemsFromSources() {
    var mergedMenu = MenuModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = mergedMenu.items
    root.itemOrder = mergedMenu.itemOrder
    root.rebuildCategories()
    root.rowsLoaded = true
    root.evaluateGuards()
    if (root.opened) {
      root.rebuildDisplay()
      if (!root.dmenuActive) {
        if (root.filterText.trim()) root.loadProvidersForSearch()
        else root.loadProviderForMenu(root.activeMenu)
      }
    }
  }

  function rebuildCategories() {
    categoryModel.clear()
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || entry.parent !== "root") continue
      if (entry.when && root.whenResults[entry.id] === false) continue
      categoryModel.append({
        itemId: entry.id,
        kind: entry.kind,
        icon: entry.icon || "•",
        iconFont: entry.iconFont || "",
        label: entry.label || entry.id,
        target: entry.target || "",
        action: entry.action || ""
      })
    }
    if (categoryModel.count === 0) root.categoryIndex = 0
    else root.categoryIndex = Math.max(0, Math.min(root.categoryIndex, categoryModel.count - 1))
  }

  function selectCategory(delta) {
    if (categoryModel.count === 0) return
    var nextIndex = Math.max(0, Math.min(categoryModel.count - 1, root.categoryIndex + delta))
    if (nextIndex === root.categoryIndex) return
    root.categoryIndex = nextIndex
    if (!root.filterText) root.previewCategory(false)
  }

  function activeMenuIsTopLevel() {
    var active = root.item(root.activeMenu)
    return !!active && active.parent === "root"
  }

  function activateCategory(fromPointer) {
    if (root.categoryIndex < 0 || root.categoryIndex >= categoryModel.count) return
    var category = categoryModel.get(root.categoryIndex)
    if (category.kind === "action") root.applySelected(category.itemId, category.action)
    else root.previewCategory(fromPointer)
  }

  function previewCategory(fromPointer) {
    if (root.categoryIndex < 0 || root.categoryIndex >= categoryModel.count) return
    var category = categoryModel.get(root.categoryIndex)
    if (category.kind === "action") {
      root.activeMenu = "root"
      root.navStack = []
      root.selectedIndex = 0
      root.cursorActive = false
      root.rebuildDisplay()
      return
    }
    root.setActiveMenu(category.target || category.itemId, false, fromPointer)
  }

  function syncCategoryToMenu() {
    var topId = root.activeMenu
    var current = root.item(topId)
    var guard = 0
    while (current && current.parent && current.parent !== "root" && guard < 32) {
      topId = current.parent
      current = root.item(topId)
      guard += 1
    }
    for (var i = 0; i < categoryModel.count; i++) {
      if (categoryModel.get(i).itemId === topId) {
        root.categoryIndex = i
        return
      }
    }
  }

  // Each known provider is a tiny bash one-liner that enumerates a list and
  // emits one tab-delimited row per item: `label\tvalue\tcurrent`. The shell
  // turns those into menu items children of `menuId`. A `volatile` provider
  // re-runs every time its submenu is entered, so a font installed since the
  // shell started shows up without restarting it.
  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "\udb81\udc0b",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function slugify(value) {
    return MenuModel.slugify(value)
  }

  // The apps provider is QML-native: rows come from the shared AppLibrary
  // (DesktopEntries) instead of a bash enumeration, so they carry image
  // icons, launch feedback, and uninstall support like the launcher.
  function mergeAppRows() {
    if (!root.appLibrary) return

    var rows = root.appLibrary.sortedEntries("")
    var appRows = []
    for (var j = 0; j < rows.length; j++) {
      var entry = rows[j].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      var subtext = root.appLibrary.entrySubtext(entry)
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }
      appRows.push({
        id: "apps." + appId,
        parent: "apps",
        kind: "app",
        icon: "",
        appIcon: String(entry.icon || ""),
        appId: appId,
        label: root.appLibrary.entryName(entry),
        title: "",
        target: "",
        description: subtext,
        action: "",
        provider: "",
        aliases: aliases,
        when: "",
        checked: "",
        order: 0
      })
    }

    var merged = MenuModel.mergeAppRows(root.items, root.itemOrder, appRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    if (entry.provider === "apps") {
      root.providersLoaded[id] = true
      root.mergeAppRows()
      return
    }
    var spec = root.providers[entry.provider]
    if (!spec) return

    root.providersLoaded[id] = true
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.collected = ""
    providerProc.command = ["bash", "-lc", spec.script]
    providerProc.running = true
  }

  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      var current = parts[2] || ""
      if (!label) continue
      // Distinct values can slugify alike — Fira Code and Fira-Code both give
      // fira-code — and a repeated id is dropped, which would silently lose a
      // row from the list. Nudge it until it is the row's own.
      var rowId = menuId + "." + root.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true

      providerRows.push({
        id: rowId,
        parent: menuId,
        kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        label: label,
        title: "",
        target: "",
        description: "",
        action: spec.actionFor(value),
        provider: "",
        aliases: [],
        when: "",
        checked: "",
        order: 0
      })
    }
    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startNextProvider() {
    if (providerProc.running) return

    while (root.providerQueue.length > 0) {
      var id = root.providerQueue.shift()
      var entry = root.item(id)
      if (!entry || !entry.provider || root.providersLoaded[id]) continue

      root.startProviderForMenu(id)
      return
    }
  }

  // Entering a submenu is the one moment a volatile list is worth paying for
  // again: it may have been reshaped by the last pick from it. Search doesn't
  // invalidate, or every keystroke would restart the same enumeration.
  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  function loadProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return

    // Native providers don't touch providerProc, so they never need to queue.
    if (entry.provider === "apps") {
      root.startProviderForMenu(id)
      return
    }

    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }

    root.startProviderForMenu(id)
  }

  function loadProvidersForSearch() {
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || !entry.provider || root.providersLoaded[entry.id]) continue

      root.loadProviderForMenu(entry.id)
    }
  }

  function depthFor(id) {
    return MenuModel.depthFor(root.items, id)
  }

  function pathFor(id) {
    return MenuModel.pathFor(root.items, id)
  }

  function parentPathFor(id) {
    return MenuModel.parentPathFor(root.items, id)
  }

  function isDescendantOf(id, ancestorId) {
    return MenuModel.isDescendantOf(root.items, id, ancestorId)
  }

  function childCount(id) {
    return MenuModel.childCount(root.items, root.itemOrder, id)
  }

  // Guarded items are hidden when their `when:` evaluates false. Static
  // submenus are also hidden when none of their descendants are visible;
  // provider-backed menus stay visible because their rows load on demand.
  function isVisible(entry) {
    return MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry)
  }

  // Label with the ✓ marker baked in when `checked:` evaluated truthy.
  function labelFor(entry) {
    return MenuModel.labelFor(entry, root.checkedResults)
  }

  function searchableToken(value) {
    return MenuModel.searchableToken(value)
  }

  function leafIdFor(id) {
    return MenuModel.leafIdFor(id)
  }

  function nameSearchText(entry) {
    return MenuModel.nameSearchText(entry)
  }

  function termInSearchWords(term, text) {
    return MenuModel.termInSearchWords(term, text)
  }

  function descriptionTextMatches(query, text) {
    return MenuModel.descriptionTextMatches(query, text)
  }

  function matchesQuery(entry, query) {
    return MenuModel.matchesQuery(entry, query, root.isVisible(entry))
  }

  function searchScore(entry, query) {
    return MenuModel.searchScore(root.items, entry, query)
  }

  function displayRow(entry, detail, score, section) {
    return MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, detail, score, section)
  }

  function rebuildDmenuDisplay() {
    displayModel.clear()
    root.searchDivider = false

    if (root.mode === "input") {
      layoutSerial += 1
      return
    }

    var query = root.filterText.trim().toLowerCase()
    for (var i = 0; i < root.dmenuOptions.length; i++) {
      // An option is "<label>", "<glyph>\t<label>", or
      // "<glyph>\t<label>\t<subtext>". The glyph never comes back with the
      // selection; the subtext renders under the label, filters alongside it,
      // and returns with the selection as a stable key for same-named rows.
      var parts = String(root.dmenuOptions[i] || "").split("\t")
      var icon = parts.length > 1 ? parts.shift() : ""
      var label = parts.shift() || ""
      var detail = parts.join("\t")
      if (query && label.toLowerCase().indexOf(query) < 0
          && detail.toLowerCase().indexOf(query) < 0) continue
      displayModel.append({
        itemId: "dmenu." + i,
        kind: "dmenu",
        icon: icon,
        iconFont: "",
        appIcon: "",
        appId: "",
        label: label,
        target: "",
        detail: detail,
        path: "",
        childCount: 0,
        action: "",
        provider: "",
        score: i,
        section: ""
      })
    }

    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0
  }

  function rebuildDisplay() {
    if (root.dmenuActive) {
      root.rebuildDmenuDisplay()
      return
    }

    displayModel.clear()

    if (!root.rowsLoaded) return

    var active = root.item(root.activeMenu) ? root.activeMenu : "root"
    root.activeMenu = active
    var rows = []
    var query = root.filterText.trim()
    root.searchDivider = false

    if (query) {
      var searchRows = []

      for (var i = 0; i < root.itemOrder.length; i++) {
        var entry = root.item(root.itemOrder[i])
        if (!entry || entry.id === "root") continue
        if (!root.matchesQuery(entry, query)) continue

        var detail = root.parentPathFor(entry.id)
        var row = root.displayRow(entry, detail, root.searchScore(entry, query))
        searchRows.push(row)
      }

      var searchSort = function(a, b) {
        if (a.score !== b.score) return a.score - b.score
        return a.path.localeCompare(b.path)
      }

      searchRows.sort(searchSort)
      rows = searchRows
    } else {
      for (var j = 0; j < root.itemOrder.length; j++) {
        var child = root.item(root.itemOrder[j])
        if (!child || child.parent !== active) continue
        if (!root.isVisible(child)) continue
        rows.push(root.displayRow(child, child.description, child.order))
      }

      // DesktopEntries can reorder its values when an application starts.
      // Keep the Apps menu alphabetical independently of provider refreshes.
      if (active === "apps") {
        rows.sort(function(a, b) {
          var aLabel = String(a.label || "").toLowerCase()
          var bLabel = String(b.label || "").toLowerCase()
          if (aLabel < bLabel) return -1
          if (aLabel > bLabel) return 1
          var aId = String(a.itemId || "")
          var bId = String(b.itemId || "")
          if (aId < bId) return -1
          if (aId > bId) return 1
          return 0
        })
      }
    }

    for (var k = 0; k < rows.length; k++) displayModel.append(rows[k])
    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0
  }

  function select(delta) {
    if (displayModel.count === 0) return

    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      // Page Up can move farther than the length of a short list. JavaScript
      // remainder may be negative, so normalize it before using it as an index.
      selectedIndex = ((selectedIndex + delta) % displayModel.count + displayModel.count) % displayModel.count
    }
  }

  function setFilter(nextFilter) {
    panel.freezeCardTop()
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = root.mode !== "input"
    if (!root.dmenuActive && root.filterText.trim()) root.loadProvidersForSearch()
    root.rebuildDisplay()
  }

  function setActiveMenu(id, pushHistory, fromPointer) {
    panel.freezeCardTop()
    if (!root.item(id)) id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.syncCategoryToMenu()
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
  }

  function goBack() {
    if (root.activeMenu === "root") return false

    if (root.navStack.length > 0) {
      var previous = root.navStack[root.navStack.length - 1]
      root.navStack = root.navStack.slice(0, root.navStack.length - 1)
      root.setActiveMenu(previous, false)
      return true
    }

    var active = root.item(root.activeMenu)
    root.setActiveMenu((active && active.parent) ? active.parent : "root", false)
    return true
  }

  function activateIndex(index, fromPointer) {
    if (root.deleteConfirmOpen) return
    if (root.dmenuActive) {
      if (root.mode === "input") {
        root.applyDmenuSelection(root.filterText)
        return
      }
      if (index < 0 || index >= displayModel.count) return
      var picked = displayModel.get(index)
      root.applyDmenuSelection(picked.detail ? picked.label + "\t" + picked.detail : picked.label)
      return
    }

    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    if (row.kind === "menu" || row.kind === "link") {
      root.setActiveMenu(row.target || row.itemId, true, fromPointer)
    } else if (row.kind === "app") {
      var appId = row.appId
      var label = row.label
      applySerial = requestSerial
      opened = false
      filterText = ""
      if (root.appLibrary) root.appLibrary.launch(appId, label)
    } else {
      root.applySelected(row.itemId, row.action)
    }
  }

  // A picker summoned by omarchy-menu-select or omarchy-menu-input has no
  // category carousel to drive, so the root-menu bindings would switch
  // categories (or run a category's action) instead of picking an option.
  function handleDmenuKey(event) {
    var key = event.key
    if (key === Qt.Key_Escape) {
      if (root.filterText) root.setFilter("")
      else root.cancel()
    } else if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
    } else if ((key === Qt.Key_Backspace || key === Qt.Key_Left) && !root.filterText) {
      root.cancel()
    } else if (key === Qt.Key_Up) {
      root.select(-1)
    } else if (key === Qt.Key_Down) {
      root.select(1)
    } else if (key === Qt.Key_PageUp) {
      root.select(-6)
    } else if (key === Qt.Key_PageDown) {
      root.select(6)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      root.activateIndex(root.cursorActive ? root.selectedIndex : 0)
    } else if (key === Qt.Key_Right && root.mode !== "input") {
      root.activateIndex(root.selectedIndex)
    } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
      root.setFilter(root.filterText + event.text)
    } else {
      return false
    }
    return true
  }

  function requestDeleteSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    if (!row || row.kind !== "app") return
    root.deleteTarget = { appId: row.appId, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    deleteConfirm.selectedIndex = 1
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (!target) return
    root.cancel()
    if (root.appLibrary) root.appLibrary.remove(target.appId, target.label)
  }

  function applyDmenuSelection(value) {
    applySerial = requestSerial
    opened = false
    filterText = ""
    root.finishRequest(value)
  }

  function applySelected(id, action) {
    if (!id) { cancel(); return }

    applySerial = requestSerial
    opened = false
    filterText = ""
    root.runAction(action)
  }

  function cancel() {
    if (root.dmenuActive) root.finishRequest(null)
    opened = false
    filterText = ""
  }

  function openExistingMenu(initialMenu) {
    requestSerial += 1
    mode = "menu"
    requestActive = false
    selectionFile = ""
    doneFile = ""
    activeMenu = root.item(initialMenu) ? initialMenu : "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = true
    root.evaluateGuards()
    opened = true
    if (activeMenu === "root" && categoryModel.count > 0) {
      categoryIndex = 0
      root.previewCategory(false)
    } else {
      root.syncCategoryToMenu()
      rebuildDisplay()
      invalidateVolatileProvider(activeMenu)
      loadProviderForMenu(activeMenu)
    }
    // The shell may start before first-install packages have finished placing
    // their icons. Refresh here even when the desktop entry list did not change.
    if (root.appLibrary) root.appLibrary.refreshIcons()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openDmenu(payload) {
    requestSerial += 1
    mode = payload.mode === "input" ? "input" : "select"
    dmenuPrompt = String(payload.prompt || (mode === "input" ? "Input" : "Select"))
    dmenuOptions = Array.isArray(payload.options) ? payload.options : []
    selectionFile = String(payload.selectionFile || "")
    doneFile = String(payload.doneFile || "")
    requestActive = !!doneFile
    dmenuWidth = Math.max(1, Number(payload.width || 300))
    dmenuMaxHeight = Math.max(0, Number(payload.maxHeight || 0))
    activeMenu = "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = mode !== "input"
    opened = true
    rebuildDisplay()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  ListModel { id: displayModel }
  ListModel { id: categoryModel }

  // ----------------------------------------------------------- route surface
  //
  // The menu is opened through the standard plugin lifecycle:
  // `omarchy-shell shell summon omarchy.menu '{"menu":"system"}'`.
  // Callers may pass a real id (`system`, `setup.power`) or an alias declared
  // in JSONC (`power`, `reminder-set`). Unknown strings fall through to the
  // id-as-route behavior so misspellings still attempt to open the literal id.
  function resolveRoute(input) {
    return MenuModel.resolveRoute(root.items, root.itemOrder, input)
  }

  function openRoute(initialMenu) {
    var id = root.resolveRoute(initialMenu)
    var entry = root.items[id]
    // If the resolved id is an action (i.e. the user invoked an alias for
    // a leaf, e.g. `omarchy menu summon screenrecord-stop`), run it directly
    // instead of opening an action with no children.
    if (entry && entry.kind === "action" && entry.action) {
      root.cancel()
      root.runAction(entry.action)
      return "ok"
    }
    // If it's a link (a redirect to another menu), follow the link.
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    root.pendingInitialMenu = id
    root.openExistingMenu(id)
    return "ok"
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    property int revision: 0
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: {
      if (providerProc.revision === root.providerRevision) {
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
        if (root.filterText.trim()) root.loadProvidersForSearch()
      }
      root.startNextProvider()
    }
  }

  Process {
    id: resultProc
    onExited: {
      if (root.applySerial === root.requestSerial)
        root.opened = false
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (root.providersLoaded["apps"]) root.mergeAppRows()
    }
  }

  // The JSONC sources are watched so live edits to the default file (or the
  // user extension at ~/.config/omarchy/extensions/omarchy-menu.jsonc) take
  // effect without restarting the shell.
  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = root.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = root.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onLoadFailed: { root.userMenuItems = []; root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  // ---------------------------------------------------------------- guards
  //
  // `when:` (visibility) and `checked:` (✓ marker) are bash expressions the
  // shell wasn't allowed to evaluate before the perf rewrite. Now the shell
  // batches them into one bash subprocess per (re)load so the open path
  // never has to wait on them.

  property var whenResults: ({})       // id → true|false (allow visibility)
  property var checkedResults: ({})    // id → true|false (show ✓)
  property bool guardsPending: false

  function evaluateGuards() {
    // Process ignores a command change while it is running, and `collected`
    // belongs to the run in flight, so a second evaluation cannot overwrite
    // the first: it would throw away the lines already read and never start.
    // The surviving tail then lands as the whole answer, and every id lost
    // with it goes back to showing, since a `when:` only hides on an explicit
    // false. Wait for the run in flight and evaluate once it lands instead.
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    var script = MenuModel.guardScript(root.items)
    if (!script) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      // A batch that was killed rather than finished has only told us about
      // the rows it reached, and a row whose `when:` went unanswered shows.
      // Keep the last complete set rather than let a half-read one through.
      // A signal leaves the exit code at 0, so the status is what tells us.
      if (exitCode !== 0 || exitStatus !== 0) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      root.rebuildCategories()
      if (root.opened) root.rebuildDisplay()
      // Run the evaluation that had to stand aside. Deferred by a turn so the
      // process is settled before its command is set again.
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }
}
