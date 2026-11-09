import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root

  moduleName: "alexandrlebegue.openclaw"
  ipcTarget: "alexandrlebegue.openclaw"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property bool serviceResolved: false
  property var service: ({
    status: "starting",
    detail: "",
    lastError: "",
    gatewayInfo: null,
    pairingRequestId: "",
    pairingCommand: "",
    sessions: [],
    activeCount: 0,
    selectedKey: "",
    messages: [],
    sending: false,
    loadingHistory: false,
    selectedSession: null,
    selectedActive: false,
    unread: 0,
    refresh: function() {},
    reconnect: function() {},
    selectSession: function(key) {},
    sendMessage: function(text) { return false },
    abort: function() {},
    unreadFor: function(key) { return 0 },
    queueNotification: function(title, body) {},
    applySettings: function(value) {},
    panelOpened: function(panel) {},
    panelClosed: function(panel) {}
  })

  function resolveService() {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    var found = null
    if (host && typeof host.serviceFor === "function") {
      try { found = host.serviceFor(root.moduleName) } catch (e) { found = null }
    }
    if (found && found !== service) {
      service = found
      serviceResolved = true
      service.applySettings(root.settings)
      if (root.opened) service.panelOpened(root)
    }
  }

  Component.onCompleted: resolveService()

  onSettingsChanged: if (serviceResolved) service.applySettings(root.settings)

  Component.onDestruction: if (serviceResolved) service.panelClosed(root)

  Timer {
    interval: 500
    repeat: true
    running: !root.serviceResolved
    onTriggered: root.resolveService()
  }

  Connections {
    target: root.serviceResolved ? root.service : null
    function onPairingRequired(requestId, command) {
      var body = strings.t("notify.pairingBody")
      if (command) body = body + " " + command
      root.service.queueNotification(strings.t("notify.pairingTitle"), body)
    }
  }

  function statusText() {
    if (service.status === "online") return strings.t("status.online")
    if (service.status === "pairing") return strings.t("status.pairing")
    if (service.status === "connecting" || service.status === "starting") return strings.t("status.connecting")
    if (service.status === "error") return strings.t("status.error")
    return strings.t("status.offline")
  }

  function statusMeta() {
    if (service.status === "online") {
      var version = service.gatewayInfo && service.gatewayInfo.server ? service.gatewayInfo.server.version : ""
      return version ? "Gateway " + version : strings.t("status.online")
    }
    return statusText()
  }

  function activityDetail() {
    if (service.activeCount <= 0) return ""
    return strings.tn("panel.active", service.activeCount).arg(service.activeCount)
  }

  function bannerTitle() {
    if (service.status === "pairing") return strings.t("panel.pairingTitle")
    if (service.status === "error" || service.status === "offline") return strings.t("panel.offlineTitle")
    return strings.t("panel.connectingTitle")
  }

  function tooltipText() {
    if (service.status !== "online") return "OpenClaw · " + statusText()
    var parts = ["OpenClaw", strings.t("panel.tooltipOnline")]
    if (service.activeCount > 0) parts.push(strings.tn("panel.active", service.activeCount).arg(service.activeCount))
    if (service.unread > 0) parts.push(strings.tn("panel.unread", service.unread).arg(service.unread))
    return parts.join(" · ")
  }

  function formatTime(ms) {
    var value = Number(ms) || 0
    if (value <= 0) return ""
    var date = new Date(value)
    var now = new Date()
    if (date.toDateString() === now.toDateString()) return Qt.formatTime(date, "HH:mm")
    return Qt.formatDate(date, "dd/MM")
  }

  function moveSelection(dy) {
    if (service.sessions.length === 0) return
    var index = 0
    for (var i = 0; i < service.sessions.length; i++) {
      if (service.sessions[i].key === service.selectedKey) { index = i; break }
    }
    index = Math.max(0, Math.min(service.sessions.length - 1, index + dy))
    service.selectSession(service.sessions[index].key)
  }

  function activateSelection() {
    if (!input.activeFocus) input.forceActiveFocus()
  }

  function submit() {
    if (input.text.trim() === "") return
    if (service.sendMessage(input.text)) input.text = ""
  }

  function copyPairingCommand() {
    if (service.pairingCommand === "") return
    copyProcess.command = ["wl-copy", service.pairingCommand]
    copyProcess.running = true
  }

  onOpenedChanged: {
    if (serviceResolved) {
      if (opened) service.panelOpened(root)
      else service.panelClosed(root)
    }
    if (opened) {
      if (serviceResolved) service.refresh()
      Qt.callLater(function() { input.forceActiveFocus() })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    fixedWidth: root.bar && root.bar.vertical ? -1 : content.implicitWidth + Style.space(16)
    tooltipText: root.tooltipText()
    active: service.activeCount > 0 || service.unread > 0
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(4)

      TintedIcon {
        width: Style.space(15)
        height: width
        anchors.verticalCenter: parent.verticalCenter
        iconSize: width
        source: Qt.resolvedUrl("assets/openclaw.svg")
        color: button.active ? (root.bar ? root.bar.urgent : Color.urgent) : root.foreground
      }

      Rectangle {
        visible: service.activeCount > 0
        width: Style.space(5)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.accent
        SequentialAnimation on opacity {
          running: service.activeCount > 0
          loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: Style.duration(800); easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: Style.duration(800); easing.type: Easing.InOutQuad }
        }
      }

      Text {
        visible: service.unread > 0 && !(root.bar ? root.bar.vertical : false)
        anchors.verticalCenter: parent.verticalCenter
        text: service.unread > 99 ? "99+" : String(service.unread)
        textFormat: Text.PlainText
        color: button.active ? root.bar.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: catcher
    contentWidth: panel.fittedContentWidth(Style.space(820))
    contentHeight: panel.fittedContentHeight(Style.space(620), Style.space(720))

    PanelKeyCatcher {
      id: catcher
      anchors.fill: parent
      blocked: input.activeFocus
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onActivateRequested: root.activateSelection()
      onReturnRequested: root.activateSelection()
      onTextKey: function(text) {
        if (text === "r" || text === "R") service.refresh()
        else if (text === "i" || text === "I") input.forceActiveFocus()
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(12)

        PanelHero {
          Layout.fillWidth: true
          title: "OpenClaw"
          meta: root.statusMeta()
          detail: root.activityDetail()
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            TintedIcon {
              implicitWidth: Style.font.display
              implicitHeight: Style.font.display
              iconSize: Style.font.display
              source: Qt.resolvedUrl("assets/openclaw.svg")
              color: root.foreground
            }
          }
        }

        BorderSurface {
          Layout.fillWidth: true
          visible: service.status !== "online" || service.lastError !== ""
          Layout.preferredHeight: banner.implicitHeight + Style.space(20)
          color: Style.controlFill(false, false, root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
          radius: Style.cornerRadius

          Column {
            id: banner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.bannerTitle()
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              visible: service.status === "pairing"
              width: parent.width
              text: strings.t("panel.pairingBody")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: service.pairingCommand !== ""
              width: parent.width
              text: service.pairingCommand
              textFormat: Text.PlainText
              color: root.accent
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Text {
              visible: service.lastError !== ""
              width: parent.width
              text: service.lastError
              textFormat: Text.PlainText
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            RowLayout {
              visible: service.pairingCommand !== ""
              spacing: Style.space(8)

              Button {
                text: strings.t("panel.copyCommand")
                bordered: true
                focusable: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                accent: root.accent
                onClicked: root.copyPairingCommand()
              }

              Button {
                text: strings.t("panel.retry")
                bordered: true
                focusable: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                accent: root.accent
                onClicked: service.reconnect()
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(14)

          ColumnLayout {
            Layout.preferredWidth: Style.space(230)
            Layout.fillHeight: true
            spacing: Style.space(6)

            Text {
              text: strings.t("panel.agents")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }

            ListView {
              id: sessionList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              spacing: Style.space(4)
              model: service.sessions

              delegate: Item {
                id: sessionRow
                width: ListView.view.width
                height: sessionContent.implicitHeight + Style.space(14)

                readonly property bool selected: modelData.key === service.selectedKey
                readonly property bool hovered: sessionMouse.containsMouse

                BorderSurface {
                  anchors.fill: parent
                  color: sessionRow.selected
                    ? Style.selectedStateColor(root.foreground, root.accent)
                    : (sessionRow.hovered ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
                  borderSpec: sessionRow.selected
                    ? Border.controlSpec("selected", root.foreground, root.accent)
                    : Border.none()
                  radius: Style.cornerRadius
                }

                Column {
                  id: sessionContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(26)
                  spacing: Style.space(2)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Rectangle {
                      width: Style.space(6)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: modelData.active ? root.accent : root.dim
                      opacity: modelData.active ? 1 : 0.55
                    }

                    Text {
                      width: parent.width - Style.space(12)
                      text: modelData.title || modelData.key
                      textFormat: Text.PlainText
                      color: sessionRow.selected ? root.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: sessionRow.selected
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    width: parent.width
                    text: modelData.active
                      ? strings.t("panel.running")
                      : (modelData.agentId || modelData.model || modelData.channel || "")
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  visible: service.unreadFor(modelData.key) > 0
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.rightMargin: Style.space(8)
                  anchors.topMargin: Style.space(7)
                  text: service.unreadFor(modelData.key) > 99 ? "99+" : String(service.unreadFor(modelData.key))
                  textFormat: Text.PlainText
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: sessionMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: service.selectSession(modelData.key)
                }
              }
            }

            Text {
              visible: service.sessions.length === 0
              Layout.fillWidth: true
              text: strings.t("panel.noSessions")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Rectangle {
            Layout.fillHeight: true
            width: 1
            color: Style.normalBorderColor
            opacity: 0.55
          }

          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.space(8)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Column {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: service.selectedSession ? service.selectedSession.title : strings.t("panel.noSessions")
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: service.selectedSession
                    ? [service.selectedSession.agentId, service.selectedSession.model].filter(function(value) { return value !== "" }).join(" · ")
                    : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              PanelActionButton {
                visible: service.selectedActive
                iconText: "■"
                tooltipText: strings.t("panel.stop")
                foreground: root.dim
                hoverColor: Color.urgent
                onClicked: service.abort()
              }
            }

            Item {
              Layout.fillWidth: true
              Layout.fillHeight: true

              ListView {
                id: messageList
                anchors.fill: parent
                clip: true
                spacing: Style.space(8)
                model: service.messages
                onCountChanged: Qt.callLater(function() {
                  if (messageList.count > 0) messageList.positionViewAtEnd()
                })

                delegate: Item {
                  id: messageItem
                  width: ListView.view.width
                  height: messageBubble.height + Style.space(2)

                  readonly property bool isUser: modelData.role === "user"
                  readonly property bool isSystem: modelData.role === "system" || modelData.role === "tool"

                  Rectangle {
                    id: messageBubble
                    width: ListView.view.width * (messageItem.isUser ? 0.86 : 0.94)
                    height: messageText.implicitHeight + Style.space(16)
                    anchors.right: messageItem.isUser ? parent.right : undefined
                    anchors.left: messageItem.isUser ? undefined : parent.left
                    radius: Style.cornerRadius
                    color: messageItem.isUser
                      ? Style.selectedStateColor(root.foreground, root.accent)
                      : Style.controlFill(false, false, root.foreground, root.accent)
                    opacity: messageItem.isSystem ? 0.75 : 1

                    Text {
                      id: messageText
                      anchors.fill: parent
                      anchors.margins: Style.space(8)
                      text: modelData.text
                      textFormat: Text.PlainText
                      wrapMode: Text.Wrap
                      color: messageItem.isSystem ? root.dim : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.italic: messageItem.isSystem
                      verticalAlignment: Text.AlignTop
                    }
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                visible: messageList.count === 0
                text: service.loadingHistory ? strings.t("panel.loading") : strings.t("panel.noMessages")
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              visible: service.selectedActive || service.sending
              Layout.fillWidth: true
              text: service.sending ? strings.t("panel.sending") : strings.t("panel.running")
              textFormat: Text.PlainText
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              TextField {
                id: input
                Layout.fillWidth: true
                placeholderText: service.selectedKey !== ""
                  ? strings.t("panel.inputPlaceholder")
                  : strings.t("panel.pickAgent")
                enabled: service.selectedKey !== "" && service.status === "online"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onAccepted: root.submit()
                Keys.onEscapePressed: function(event) {
                  root.close()
                  event.accepted = true
                }
              }

              Button {
                text: service.sending ? strings.t("panel.sending") : strings.t("panel.send")
                bordered: true
                focusable: true
                enabled: input.text.trim() !== "" && !service.sending && service.status === "online"
                fontFamily: root.fontFamily
                foreground: root.foreground
                accent: root.accent
                onClicked: root.submit()
              }
            }
          }
        }
      }
    }
  }

  Process {
    id: copyProcess
    command: []
  }
}
