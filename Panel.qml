import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Hamachi bar widget: icon in the bar, popup with online toggle, own address,
// joined networks (each with its own online/offline button) and peers.
// All hamachi calls go through hamachi-ctl.py, which returns JSON.
Panel {
  id: root
  moduleName: "io.github.danfimov.hamachi"
  ipcTarget: "io.github.danfimov.hamachi"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string helper: Qt.resolvedUrl("hamachi-ctl.py").toString().replace(/^file:\/\//, "")
  readonly property int refreshIntervalSec: Math.max(5, parseInt(setting("refreshIntervalSec", 15), 10) || 15)

  property var hs: ({ installed: true, daemon: true, permission: true, online: false, networks: [] })
  property bool busy: actionProc.running
  property string message: ""
  property bool messageIsError: false
  // "" | "join" | "create" | "nick": which inline form is open
  property string formMode: ""
  // Unsent form input per mode ({ first, secret }), kept in memory only, so
  // closing the panel to copy a password elsewhere doesn't lose the network ID.
  // Cleared when the form is submitted or cancelled.
  property var drafts: ({})
  // network id waiting for a second click to confirm leave/delete
  property string confirmId: ""

  readonly property bool usable: hs.installed && hs.daemon && hs.permission
  readonly property bool online: usable && hs.online === true
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // nf-md-lan_connect / nf-md-lan_disconnect
  readonly property string glyphOn: "󰌘"
  readonly property string glyphOff: "󰌙"

  function onlinePeers(net) {
    var n = 0
    for (var i = 0; i < (net.peers || []).length; i++) if (net.peers[i].online) n++
    return n
  }

  function statusLine() {
    if (!hs.installed) return strings.t("notInstalled")
    if (!hs.daemon) return strings.t("daemonStopped")
    if (!hs.permission) return strings.t("noPermission")
    if (busy) return strings.t("connecting")
    return online ? strings.t("online") : strings.t("offline")
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.running = true
  }

  function act(args, secret) {
    if (actionProc.running) return
    message = ""
    // The password travels in the environment, not in argv (visible in ps).
    actionProc.environment = secret ? { HAMACHI_PASS: String(secret) } : { HAMACHI_PASS: null }
    actionProc.command = ["python3", root.helper].concat(args)
    actionProc.running = true
  }

  function openForm(mode) {
    formMode = formMode === mode ? "" : mode
    message = ""
  }

  function submitForm(first, secret) {
    var value = String(first || "").trim()
    if (value === "") return
    if (formMode === "join") act(["join", value], secret)
    else if (formMode === "create") act(["create", value], secret)
    else if (formMode === "nick") act(["set-nick", value])
    clearDraft(formMode)
    formMode = ""
  }

  function cancelForm() {
    clearDraft(formMode)
    formMode = ""
  }

  function saveDraft(mode, first, secret) {
    if (mode !== "") drafts[mode] = { first: String(first), secret: String(secret) }
  }

  function clearDraft(mode) {
    delete drafts[mode]
  }

  function leaveOrDelete(net) {
    var id = String(net.id)
    if (confirmId !== id) { confirmId = id; confirmTimer.restart(); return }
    confirmId = ""
    act([net.isOwner ? "delete" : "leave", id])
  }

  function toggleOnline() {
    if (!usable || busy) return
    act([online ? "logout" : "login"])
  }

  function copy(text) {
    if (!text) return
    Quickshell.execDetached(["wl-copy", "--", String(text)])
    message = strings.t("copied").arg(text)
    messageIsError = false
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Process {
    id: statusProc
    command: ["python3", root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.hs = JSON.parse(String(text || "{}")) } catch (e) {}
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = {}
        try { r = JSON.parse(String(text || "{}")) } catch (e) {}
        root.message = String(r.message || r.error || "")
        root.messageIsError = r.ok !== true
        // hamachi needs a moment before list reflects joins/leaves
        root.refresh(); lateRefresh.restart()
      }
    }
  }

  Timer { id: lateRefresh; interval: 2500; onTriggered: root.refresh() }
  Timer { id: confirmTimer; interval: 4000; onTriggered: root.confirmId = "" }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function login(): string { root.act(["login"]); return "ok" }
    function logout(): string { root.act(["logout"]); return "ok" }
    function status(): string { return root.online ? "online" : "offline" }
    function form(mode: string): void { root.open(); root.formMode = mode }
    function join(id: string, password: string): string { root.act(["join", id], password); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.online ? root.glyphOn : root.glyphOff
    dimmed: !root.online
    tooltipText: "Hamachi: " + root.statusLine() + (root.online && root.hs.address ? "\n" + root.hs.address : "")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleOnline()
      else if (b === Qt.MiddleButton) root.copy(root.hs.address)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      blocked: root.formMode !== ""
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.toggleOnline()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.toggleOnline()
        else if (root.online && (t === "j" || t === "J")) root.openForm("join")
        else if (root.online && (t === "c" || t === "C")) root.openForm("create")
        else if (root.online && (t === "n" || t === "N")) root.openForm("nick")
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Hamachi"
            meta: root.statusLine()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.online ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.online ? root.glyphOn : root.glyphOff
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                visible: root.usable
                checked: root.online
                busy: root.busy
                foreground: root.foreground
                onToggled: root.toggleOnline()
              }
            }
          }

          // Problems: daemon stopped / no permission
          Column {
            visible: !root.usable
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              visible: !root.hs.permission
              width: parent.width
              wrapMode: Text.WordWrap
              text: strings.t("noPermissionHelp")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              visible: root.hs.installed && !root.hs.daemon
              spacing: Style.space(8)
              PanelActionButton {
                iconText: ""
                tooltipText: strings.t("startDaemon")
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.busy
                onClicked: root.act(["start-daemon"])
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("startDaemon")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // Toolbar: join / create / nickname
          Row {
            visible: root.online
            spacing: Style.space(6)
            Repeater {
              model: [
                { mode: "join", icon: "\uF0C1", label: strings.t("join") },
                { mode: "create", icon: "\uF067", label: strings.t("create") },
                { mode: "nick", icon: "\uF2BD", label: strings.t("nickname") }
              ]
              Button {
                required property var modelData
                text: modelData.label
                iconText: modelData.icon
                selected: root.formMode === modelData.mode
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                enabled: !root.busy
                onClicked: root.openForm(modelData.mode)
              }
            }
          }

          Column {
            id: form
            visible: root.online && root.formMode !== ""
            width: parent.width
            spacing: Style.space(6)
            readonly property bool wantsPassword: root.formMode === "join" || root.formMode === "create"

            property bool restoring: false

            function restore() {
              if (!visible) return
              var d = root.drafts[root.formMode]
              restoring = true
              firstField.text = d ? d.first : (root.formMode === "nick" ? String(root.hs.nickname || "") : "")
              secretField.text = d ? d.secret : ""
              restoring = false
              // Back with the password in the clipboard: land straight in the password field.
              var toSecret = wantsPassword && firstField.text !== "" && secretField.text === "" && !!d
              Qt.callLater(function() {
                if (toSecret) secretField.forceActiveFocus()
                else { firstField.forceActiveFocus(); firstField.selectAll() }
              })
            }
            function save() {
              if (!restoring) root.saveDraft(root.formMode, firstField.text, secretField.text)
            }

            onVisibleChanged: restore()
            Component.onCompleted: restore()
            Connections {
              target: root
              function onFormModeChanged() { form.restore() }
            }

            TextField {
              id: firstField
              width: parent.width
              placeholderText: root.formMode === "nick" ? strings.t("nickPlaceholder") : strings.t("networkIdPlaceholder")
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: form.save()
              onAccepted: form.wantsPassword ? secretField.forceActiveFocus() : root.submitForm(text, "")
              Keys.onEscapePressed: function(e) { root.cancelForm(); e.accepted = true }
            }
            TextField {
              id: secretField
              visible: form.wantsPassword
              width: parent.width
              password: true
              placeholderText: root.formMode === "create" ? strings.t("passwordNew") : strings.t("passwordOptional")
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: form.save()
              onAccepted: root.submitForm(firstField.text, text)
              Keys.onEscapePressed: function(e) { root.cancelForm(); e.accepted = true }
            }
            Row {
              spacing: Style.space(6)
              Button {
                text: root.formMode === "join" ? strings.t("join") : (root.formMode === "create" ? strings.t("create") : strings.t("save"))
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                enabled: firstField.text.trim() !== "" && !root.busy
                onClicked: root.submitForm(firstField.text, secretField.text)
              }
              Button {
                text: strings.t("cancel")
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.cancelForm()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.message !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.message
            color: root.messageIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            visible: root.online
            width: parent.width
            spacing: Style.spacing.labelGap
            InfoPair { label: strings.t("address"); value: root.hs.address || "—"; copyValue: root.hs.address || "" }
            InfoPair { label: strings.t("nickname"); value: root.hs.nickname || "—"; copyValue: root.hs.nickname || "" }
            InfoPair { label: strings.t("clientId"); value: root.hs.clientId || "—"; copyValue: root.hs.clientId || "" }
          }

          PanelSeparator { visible: root.online; foreground: root.foreground }

          PanelSectionHeader {
            visible: root.online
            text: strings.t("networks")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.online && (root.hs.networks || []).length === 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: strings.t("noNetworks")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.online ? (root.hs.networks || []) : []
            NetworkBlock {
              required property var modelData
              width: column.width
              net: modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.online
            width: parent.width
            wrapMode: Text.WordWrap
            text: strings.t("hint")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component NetworkBlock: Column {
    id: block
    property var net: ({})
    spacing: Style.space(4)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: block.net.online ? "󰌘" : "󰌙"
        color: block.net.online ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: String(block.net.name || block.net.id)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: String(block.net.id) + " · " + strings.tn("members", root.onlinePeers(block.net)).arg(Commons.I18n.formatNumber(root.onlinePeers(block.net)))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: block.net.online ? "" : ""
        tooltipText: block.net.online ? strings.t("goOffline") : strings.t("goOnline")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.busy
        onClicked: root.act([block.net.online ? "go-offline" : "go-online", String(block.net.id)])
      }

      PanelActionButton {
        readonly property bool armed: root.confirmId === String(block.net.id)
        iconText: block.net.isOwner ? "\uF1F8" : "\uF08B"
        tooltipText: armed ? strings.t("clickAgain")
                           : (block.net.isOwner ? strings.t("deleteNetwork") : strings.t("leaveNetwork"))
        foreground: armed ? root.urgent : root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: !root.busy
        onClicked: root.leaveOrDelete(block.net)
      }
    }

    Repeater {
      model: block.net.peers || []
      PeerRow {
        required property var modelData
        width: block.width
        peer: modelData
      }
    }
  }

  component PeerRow: CursorSurface {
    id: row
    property var peer: ({})
    hasCursor: mouse.containsMouse
    foreground: root.foreground
    implicitHeight: peerLayout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.peer.ip ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.copy(row.peer.ip)
    }

    RowLayout {
      id: peerLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(8); height: width; radius: width / 2
        color: row.peer.online ? Commons.Color.accent : (row.peer.warn ? root.urgent : root.dim)
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: String(row.peer.nick || row.peer.id)
        color: row.peer.online ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        text: row.peer.online ? (String(row.peer.ip) + (row.peer.conn ? " · " + row.peer.conn : "")) : strings.t("offlinePeer")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component InfoPair: Item {
    id: pair
    property string label: ""
    property string value: ""
    property string copyValue: ""
    width: parent.width
    implicitHeight: valueText.implicitHeight

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      text: pair.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: valueText
      textFormat: Text.PlainText
      anchors.right: parent.right
      text: pair.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      MouseArea {
        anchors.fill: parent
        cursorShape: pair.copyValue ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.copy(pair.copyValue)
      }
    }
  }
}
