import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for snapper snapshots. The panel answers one question
// first — can this machine actually be rolled back right now — and only then
// lists what is on disk.
Panel {
  id: root
  moduleName: "ianswope.snapshots"
  ipcTarget: "ianswope.snapshots"
  manageIpc: false

  property int selectedIndex: 0
  property bool cursorActive: false
  // "" when no dialog is up, otherwise the action awaiting confirmation.
  property string confirmKind: ""
  property string confirmConfig: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var items: snapshots.navItems
  readonly property bool confirming: confirmKind !== ""

  // Only a real failure recolours the bar. An ungranted config is the stock
  // state on a fresh install, so it must not paint the icon urgent.
  readonly property color barIconColor: snapshots.level === "critical" ? bar.urgent : barForeground
  readonly property color heroColor: snapshots.level === "critical" ? urgent : foreground

  function levelColor(level) {
    if (level === "critical") return urgent
    if (level === "warn") return Qt.lighter(urgent, 1.25)
    return dim
  }

  function selectedItem() {
    if (items.length === 0) return null
    var i = Math.max(0, Math.min(selectedIndex, items.length - 1))
    return items[i]
  }

  function ensureCursor() {
    if (items.length === 0) { selectedIndex = 0; return }
    if (selectedIndex >= items.length) selectedIndex = items.length - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function moveCursor(dx, dy) {
    // While a dialog is up the same keys pick between its two buttons, so the
    // list cursor must not move underneath it.
    if (confirming) {
      if (dx !== 0) confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
      return
    }
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex + dy))
    scrollCursorIntoView()
  }

  function activateCursor() {
    if (confirming) {
      if (confirmDialog.selectedIndex === 0) cancelConfirm()
      else acceptConfirm()
      return
    }
    ensureCursor()
    var item = selectedItem()
    if (!item) return
    if (item.kind === "snapshot") snapshots.browse(item)
    else if (item.kind === "grant") askGrant(item.config)
    else if (item.kind === "create") snapshots.createSnapshot()
    else if (item.kind === "restore") askRestore()
  }

  function selectKind(kind) {
    var item = Model.itemOfKind(items, kind)
    if (!item) return
    cursorActive = true
    selectedIndex = item.navIndex
    scrollCursorIntoView()
  }

  function askRestore() {
    confirmConfig = ""
    confirmKind = "restore"
    // Default to Cancel: this dialog's other button reboots into a different
    // root filesystem, and Enter must never be the fast path to that.
    confirmDialog.selectedIndex = 0
  }

  function askGrant(configName) {
    confirmConfig = configName
    confirmKind = "grant"
    confirmDialog.selectedIndex = 0
  }

  function cancelConfirm() {
    confirmKind = ""
    confirmConfig = ""
  }

  function acceptConfirm() {
    var kind = confirmKind
    var configName = confirmConfig
    cancelConfirm()
    if (kind === "restore") snapshots.restore()
    else if (kind === "grant") snapshots.grantReadAccess(configName)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    var target = rowRegistry[selectedIndex]
    if (target) scrollItemIntoView(target)
  }

  // navIndex -> rendered row, so the cursor can be scrolled into view without
  // the sections having to agree on a shared layout.
  property var rowRegistry: ({})
  function registerRow(index, item) {
    rowRegistry[index] = item
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cancelConfirm()
    if (panelFlick) panelFlick.contentY = 0
    snapshots.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: snapshots
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { snapshots.refresh(); return "ok" }
    function status(): string { return snapshots.headline }
    function level(): string { return snapshots.level }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        SnapshotIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) snapshots.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(
      headerColumn.implicitHeight + column.implicitHeight + footerColumn.implicitHeight + Style.space(34),
      Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive && !root.confirming) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.confirming) root.activateCursor()
        else if (root.cursorActive) root.activateCursor()
        else root.cursorActive = true
      }
      onCloseRequested: {
        if (root.confirming) root.cancelConfirm()
        else root.close()
      }
      onTabRequested: function(direction) { if (!root.confirming) root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.confirming) return
        if (t === "r") snapshots.refresh()
        else if (t === "y") { var s = root.selectedItem(); if (s && s.kind === "snapshot") snapshots.copyPath(s) }
        else if (t === "c") root.selectKind("create")
        else if (t === "R") root.askRestore()
      }

      // Hero and actions are pinned; only the snapshot list scrolls. Otherwise a
      // machine with several configs pushes "create" and "restore" off the
      // bottom of the popup, where nobody finds them.
      Column {
        id: headerColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          title: "Snapshots"
          meta: snapshots.headline
          foreground: root.heroColor
          fontFamily: root.fontFamily
          iconComponent: Component {
            SnapshotIcon {
              iconSize: Style.font.display
              color: root.heroColor
            }
          }
        }

        Text {
          visible: snapshots.actionStatus !== ""
          width: parent.width
          text: snapshots.actionStatus
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Failures only. Ungranted configs are reported on their own row
        // further down, where the fix sits next to the explanation.
        Column {
          id: faultColumn
          width: parent.width
          spacing: Style.space(6)
          visible: faults.length > 0

          readonly property var faults: (snapshots.issues || []).filter(function(i) {
            return i.level === "critical" || i.level === "warn"
          })

          Repeater {
            model: faultColumn.faults
            Row {
              required property var modelData
              width: faultColumn.width
              spacing: Style.space(8)

              Rectangle {
                width: Style.space(4)
                height: Style.space(4)
                radius: width / 2
                color: root.levelColor(modelData.level)
                y: Style.space(5)
              }

              Text {
                width: parent.width - Style.space(12)
                text: modelData.text
                color: root.levelColor(modelData.level)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      Flickable {
        id: panelFlick
        anchors.top: headerColumn.bottom
        anchors.topMargin: Style.space(12)
        anchors.bottom: footerColumn.top
        anchors.bottomMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Repeater {
            model: snapshots.configs
            ConfigSection {
              required property var modelData
              width: column.width
              config: modelData
            }
          }
        }
      }

      Column {
        id: footerColumn
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(6)

        PanelSeparator { foreground: root.foreground }

        ActionRow {
          width: parent.width
          kind: "create"
          label: "Create a snapshot now"
          hint: "runs omarchy-snapshot create in a terminal"
        }

        ActionRow {
          width: parent.width
          kind: "restore"
          label: "Restore from a snapshot…"
          hint: "opens the limine restore tool"
          destructive: true
        }

        Text {
          width: parent.width
          text: "enter browse · y copy · c create · shift+R restore"
          color: Qt.darker(root.dim, 1.15)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirming
        message: root.confirmKind === "restore"
          ? "Open the restore tool? It rewrites which snapshot this machine boots into."
          : "Grant your user read access to the '" + root.confirmConfig + "' config?\n\n" + snapshots.grantCommandFor(root.confirmConfig) + "\n\nThis replaces that config's ALLOW_USERS."
        confirmText: root.confirmKind === "restore" ? "Open" : "Run in a terminal"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelConfirm()
        onConfirmed: root.acceptConfirm()
      }
    }
  }

  // ------------------------------------------------------------ components

  component ConfigSection: Column {
    id: section
    property var config: null

    readonly property var rows: Model.itemsForConfig(root.items, config ? config.name : "")
    readonly property int hidden: Model.hiddenCount(config, snapshots.snapshotsPerConfig)

    spacing: Style.space(8)

    PanelSectionHeader {
      text: (section.config ? section.config.name.toUpperCase() : "") +
            (section.config ? "  " + section.config.subvolume : "")
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    // Two lines rather than one long row: at panel width a single line elides
    // away exactly the retention numbers it exists to show.
    Column {
      width: parent.width
      spacing: Style.space(2)

      Text {
        width: parent.width
        visible: text !== ""
        text: section.config ? Model.configMeta(section.config, snapshots.status.now) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: text !== ""
        text: {
          if (!section.config) return ""
          var bits = []
          var policy = Model.configPolicy(section.config)
          if (policy) bits.push(policy)
          var usage = Model.usageText(section.config)
          if (usage) bits.push(usage)
          return bits.join(" · ")
        }
        color: Qt.darker(root.dim, 1.15)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      Repeater {
        model: section.rows
        Loader {
          required property var modelData
          width: section.width
          sourceComponent: modelData.kind === "grant" ? grantComponent : snapshotComponent
          onLoaded: {
            item.entry = modelData
            item.width = section.width
          }
        }
      }
    }

    Text {
      visible: section.hidden > 0
      text: "+ " + section.hidden + " older"
      color: Qt.darker(root.dim, 1.15)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Component {
    id: snapshotComponent

    CursorSurface {
      id: snapRow
      property var entry: null

      hasCursor: root.cursorActive && entry && root.selectedIndex === entry.navIndex
      foreground: root.foreground
      implicitHeight: snapContent.implicitHeight + Style.space(8)

      onEntryChanged: if (entry) root.registerRow(entry.navIndex, snapRow)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onEntered: {
          root.cursorActive = true
          if (snapRow.entry) root.selectedIndex = snapRow.entry.navIndex
        }
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) snapshots.copyPath(snapRow.entry)
          else snapshots.browse(snapRow.entry)
        }
      }

      Row {
        id: snapContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)

        Text {
          text: snapRow.entry ? "#" + snapRow.entry.number : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          width: Style.space(38)
        }

        Column {
          width: parent.width - Style.space(38) - Style.space(70) - Style.space(20)
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: snapRow.entry ? Model.clockText(snapRow.entry.epoch) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: snapRow.entry ? Model.snapshotDetail(snapRow.entry) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          width: Style.space(70)
          horizontalAlignment: Text.AlignRight
          text: snapRow.entry ? Model.relativeAge(snapshots.status.now - snapRow.entry.epoch) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  Component {
    id: grantComponent

    CursorSurface {
      id: grantRow
      property var entry: null

      hasCursor: root.cursorActive && entry && root.selectedIndex === entry.navIndex
      foreground: root.foreground
      implicitHeight: grantContent.implicitHeight + Style.space(10)

      onEntryChanged: if (entry) root.registerRow(entry.navIndex, grantRow)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: {
          root.cursorActive = true
          if (grantRow.entry) root.selectedIndex = grantRow.entry.navIndex
        }
        onClicked: if (grantRow.entry) root.askGrant(grantRow.entry.config)
      }

      Column {
        id: grantContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: "Needs read access"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          // Say why rather than just that it failed: snapper is doing exactly
          // what it was configured to do, and the fix is one config setting.
          text: "snapper only shows this config to users in its ALLOW_USERS. Enter to grant read access."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property string kind: ""
    property string label: ""
    property string hint: ""
    property bool destructive: false

    readonly property var entry: Model.itemOfKind(root.items, kind)

    hasCursor: root.cursorActive && entry && root.selectedIndex === entry.navIndex
    foreground: destructive ? root.urgent : root.foreground
    implicitHeight: actionContent.implicitHeight + Style.space(10)

    onEntryChanged: if (entry) root.registerRow(entry.navIndex, actionRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        if (actionRow.entry) root.selectedIndex = actionRow.entry.navIndex
      }
      onClicked: {
        if (actionRow.kind === "create") snapshots.createSnapshot()
        else if (actionRow.kind === "restore") root.askRestore()
      }
    }

    Column {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: actionRow.label
        color: actionRow.destructive ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        text: actionRow.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
