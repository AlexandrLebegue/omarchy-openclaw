import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Markdown.js" as Markdown

Panel {
  id: root

  moduleName: "alexandrlebegue.openclaw"
  ipcTarget: "alexandrlebegue.openclaw"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool notificationsEnabled: root.setting("notifications", true) !== false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property string focusSection: "sessions"
  property string pendingFocus: "sessions"
  property int sessionCursor: 0
  property bool settingsOpen: false
  property bool helpOpen: false
  property int settingsCursor: 0

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property var settingsRows: [
    { key: "notifications", label: strings.t("settings.notifications"), type: "bool", defaultValue: true },
    { key: "mainConversationsOnly", label: strings.t("settings.mainOnly"), type: "bool", defaultValue: false },
    { key: "maxSessions", label: strings.t("settings.maxSessions"), type: "choice", defaultValue: 20, options: [10, 20, 30, 50, 100] },
    { key: "refreshIntervalSec", label: strings.t("settings.refresh"), type: "choice", defaultValue: 60, options: [30, 60, 120, 300] },
    { key: "close", label: strings.t("settings.close"), type: "action" }
  ]

  readonly property var shortcutRows: [
    { key: "Tab / Shift+Tab", label: strings.t("help.focus") },
    { key: "↑ / ↓", label: strings.t("help.move") },
    { key: "Entrée", label: strings.t("help.enter") },
    { key: "i", label: strings.t("help.input") },
    { key: "r", label: strings.t("help.refresh") },
    { key: "n", label: strings.t("help.notifications") },
    { key: "x", label: strings.t("help.stop") },
    { key: "s / ,", label: strings.t("help.settings") },
    { key: "F1 / ?", label: strings.t("help.help") },
    { key: "Échap", label: strings.t("help.close") },
    { key: "Clic droit", label: strings.t("help.rightClick") },
    { key: "Super + Alt + O", label: strings.t("help.global") }
  ]

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
    function onMessagesChanged() {
      root.scrollChatToBottom()
    }
    function onSelectedKeyChanged() {
      root.syncSessionCursor()
      root.scrollChatToBottom()
    }
    function onSessionsChanged() {
      if (service.sessions.length === 0) {
        root.sessionCursor = 0
        return
      }
      root.sessionCursor = Math.max(0, Math.min(root.sessionCursor, service.sessions.length - 1))
      if (sessionList) sessionList.currentIndex = root.sessionCursor
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

  function clamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value))
  }

  function syncSessionCursor() {
    if (service.sessions.length === 0) {
      sessionCursor = 0
      return
    }
    var found = -1
    for (var i = 0; i < service.sessions.length; i++) {
      if (service.sessions[i].key === service.selectedKey) { found = i; break }
    }
    if (found >= 0) sessionCursor = found
    sessionCursor = clamp(sessionCursor, 0, service.sessions.length - 1)
    if (sessionList) sessionList.currentIndex = sessionCursor
  }

  function focusSectionNow(section) {
    focusSection = section
    if (section === "input") {
      Qt.callLater(function() { input.forceActiveFocus() })
    } else {
      Qt.callLater(function() { catcher.forceActiveFocus() })
    }
    if (section === "sessions") syncSessionCursor()
  }

  function cycleFocus(direction) {
    var order = ["sessions", "chat", "input"]
    var index = order.indexOf(focusSection)
    if (index < 0) index = 0
    index = (index + direction + order.length) % order.length
    focusSectionNow(order[index])
  }

  function openPanel(section) {
    pendingFocus = section || "sessions"
    if (!opened) open()
    else focusSectionNow(pendingFocus)
  }

  function togglePanel(section) {
    if (opened) close()
    else openPanel(section || "sessions")
  }

  function moveSession(dy) {
    if (service.sessions.length === 0) return
    sessionCursor = clamp(sessionCursor + dy, 0, service.sessions.length - 1)
    if (sessionList) {
      sessionList.currentIndex = sessionCursor
      sessionList.positionViewAtIndex(sessionCursor, ListView.Contain)
    }
    cursorSelectTimer.restart()
  }

  function selectCursorSession() {
    if (service.sessions.length === 0) return
    var session = service.sessions[sessionCursor]
    if (!session) return
    service.selectSession(session.key)
    focusSectionNow("input")
  }

  function scrollChat(dy) {
    var step = Style.space(56)
    var maximum = Math.max(0, messageList.contentHeight - messageList.height)
    messageList.contentY = clamp(messageList.contentY + dy * step, 0, maximum)
  }

  function openSettings() {
    settingsOpen = true
    helpOpen = false
    settingsCursor = 0
    input.focus = false
    Qt.callLater(function() { catcher.forceActiveFocus() })
  }

  function closeSettings() {
    settingsOpen = false
    focusSectionNow("sessions")
  }

  function toggleHelp() {
    helpOpen = !helpOpen
    if (helpOpen) {
      settingsOpen = false
      input.focus = false
      Qt.callLater(function() { catcher.forceActiveFocus() })
    } else {
      focusSectionNow("sessions")
    }
  }

  function settingDisplay(row) {
    if (row.type === "bool") return root.setting(row.key, row.defaultValue) ? strings.t("settings.on") : strings.t("settings.off")
    if (row.type === "choice") return String(root.setting(row.key, row.defaultValue))
    return ""
  }

  function toggleSetting(index) {
    var row = settingsRows[index]
    if (!row) return
    if (row.type === "action") { closeSettings(); return }
    if (row.type === "bool") {
      persistSetting(row.key, !root.setting(row.key, row.defaultValue))
      return
    }
    if (row.type === "choice") {
      var options = row.options || []
      var current = root.setting(row.key, row.defaultValue)
      var position = options.indexOf(current)
      if (position < 0) position = 0
      persistSetting(row.key, options[(position + 1) % options.length])
    }
  }

  function moveSettings(dy) {
    settingsCursor = clamp(settingsCursor + dy, 0, settingsRows.length - 1)
  }

  function persistSetting(key, value) {
    var next = Object.assign({}, root.settings)
    next[key] = value
    root.settings = next
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (host && typeof host.updateEntryInline === "function") {
      try { host.updateEntryInline(root.moduleName, next); return } catch (e) {}
    }
    settingsProcess.command = ["omarchy", "bar", "set", root.moduleName, key, JSON.stringify(value), "--json"]
    settingsProcess.running = true
  }

  function toggleNotifications() {
    persistSetting("notifications", !root.notificationsEnabled)
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
      focusSection = pendingFocus
      pendingFocus = "sessions"
      settingsOpen = false
      helpOpen = false
      syncSessionCursor()
      Qt.callLater(function() {
        if (focusSection === "input") input.forceActiveFocus()
        else catcher.forceActiveFocus()
      })
    } else {
      settingsOpen = false
      helpOpen = false
      input.focus = false
    }
  }

  Timer {
    id: cursorSelectTimer
    interval: 180
    onTriggered: {
      if (!root.opened || root.focusSection !== "sessions") return
      var session = service.sessions[root.sessionCursor]
      if (session && session.key !== service.selectedKey) service.selectSession(session.key)
    }
  }

  function scrollChatToBottom() {
    if (!messageList || messageList.count === 0) return
    messageList.positionViewAtEnd()
    scrollRetry.restart()
  }

  Timer {
    id: scrollRetry
    interval: 50
    repeat: false
    onTriggered: {
      if (messageList && messageList.count > 0) messageList.positionViewAtEnd()
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
      if (buttonCode === Qt.RightButton) root.openPanel("input")
      else if (buttonCode === Qt.MiddleButton) service.refresh()
      else root.togglePanel("sessions")
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
        source: Qt.resolvedUrl("assets/openclaw.png")
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
    margin: Style.space(8)
    contentWidth: panel.fittedContentWidth(Style.space(720))
    contentHeight: panel.fittedContentHeight(Style.space(620), Style.space(720))

    FocusCatcher {
      id: catcher
      anchors.fill: parent
      blocked: root.focusSection === "input" && !root.settingsOpen && !root.helpOpen
      onHelpRequested: root.toggleHelp()
      onCloseRequested: {
        if (root.helpOpen) {
          root.helpOpen = false
          root.focusSectionNow("sessions")
        } else if (root.settingsOpen) {
          root.closeSettings()
        } else {
          root.close()
        }
      }
      onMoveRequested: function(dx, dy) {
        if (root.helpOpen) return
        if (root.settingsOpen) { root.moveSettings(dy); return }
        if (root.focusSection === "sessions") root.moveSession(dy)
        else if (root.focusSection === "chat") root.scrollChat(dy)
      }
      onActivateRequested: {
        if (root.helpOpen) return
        if (root.settingsOpen) { root.toggleSetting(root.settingsCursor); return }
        if (root.focusSection === "sessions") root.selectCursorSession()
        else if (root.focusSection === "chat") root.focusSectionNow("input")
      }
      onDeleteRequested: {
        if (!root.helpOpen && !root.settingsOpen && root.focusSection !== "input" && service.selectedActive)
          service.abort()
      }
      onTextKey: function(text) {
        if (root.helpOpen) {
          if (text === "?") root.toggleHelp()
          return
        }
        if (root.settingsOpen) {
          if (text === "s" || text === "S" || text === ",") root.closeSettings()
          return
        }
        if (text === "r" || text === "R") service.refresh()
        else if (text === "i" || text === "I") root.focusSectionNow("input")
        else if (text === "s" || text === "S" || text === ",") root.openSettings()
        else if (text === "?") root.toggleHelp()
        else if (text === "n" || text === "N") root.toggleNotifications()
        else if (text === "q" || text === "Q") root.close()
        else if (text.length === 1) {
          root.focusSectionNow("input")
          input.text += text
          input.cursorPosition = input.text.length
        }
      }
      onTabRequested: function(direction) {
        if (!root.helpOpen && !root.settingsOpen) root.cycleFocus(direction)
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
              source: Qt.resolvedUrl("assets/openclaw.png")
              color: root.foreground
            }
          }
          trailingControl: Component {
            Row {
              spacing: Style.space(6)

              BorderSurface {
                id: notifyControl
                height: Style.space(30)
                implicitWidth: notifyRow.implicitWidth + Style.space(14)
                color: root.notificationsEnabled ? Util.alpha(root.accent, 0.10) : "transparent"
                borderSpec: Border.controlSpec(root.notificationsEnabled ? "selected" : "normal", root.foreground, root.accent)
                radius: Style.cornerRadius

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.toggleNotifications()
                }

                Row {
                  id: notifyRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: strings.t("panel.notification")
                    textFormat: Text.PlainText
                    height: notifySwitch.height
                    verticalAlignment: Text.AlignVCenter
                    color: root.notificationsEnabled ? root.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: root.notificationsEnabled
                  }

                  ToggleSwitch {
                    id: notifySwitch
                    checked: root.notificationsEnabled
                    trackHeight: Style.space(18)
                    cursorPad: 0
                    cursorRing: false
                    foreground: root.foreground
                    accent: root.accent
                    onToggled: root.toggleNotifications()
                    PanelToolTip {
                      visible: notifySwitch.containsMouse
                      text: strings.t("panel.notificationHint")
                      fontFamily: root.fontFamily
                    }
                  }
                }
              }

              Button {
                text: strings.t("panel.settings")
                iconText: "⚙"
                bordered: true
                focusable: false
                height: Style.space(30)
                horizontalPadding: Style.space(8)
                verticalPadding: 0
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                fontFamily: root.fontFamily
                foreground: root.foreground
                accent: root.accent
                tooltipText: strings.t("panel.settings")
                onClicked: root.openSettings()
              }

              Button {
                text: strings.t("panel.help")
                iconText: "?"
                bordered: true
                focusable: false
                height: Style.space(30)
                horizontalPadding: Style.space(8)
                verticalPadding: 0
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                fontFamily: root.fontFamily
                foreground: root.foreground
                accent: root.accent
                tooltipText: strings.t("panel.shortcuts")
                onClicked: root.toggleHelp()
              }
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
            Layout.preferredWidth: Style.space(210)
            Layout.fillHeight: true
            spacing: Style.space(6)

            Text {
              text: strings.t("panel.agents")
              textFormat: Text.PlainText
              color: root.focusSection === "sessions" ? root.accent : root.dim
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
                readonly property bool cursor: root.focusSection === "sessions" && index === root.sessionCursor
                readonly property bool hovered: sessionMouse.containsMouse

                BorderSurface {
                  anchors.fill: parent
                  color: sessionRow.selected
                    ? Util.alpha(root.accent, 0.12)
                    : (sessionRow.cursor ? Util.alpha(root.foreground, 0.06)
                      : (sessionRow.hovered ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"))
                  borderSpec: sessionRow.cursor
                    ? Border.controlSpec("focus", root.foreground, root.accent)
                    : Border.none()
                  radius: Style.cornerRadius
                }

                Rectangle {
                  visible: sessionRow.selected
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Style.space(2)
                  radius: width / 2
                  color: root.accent
                }

                Row {
                  id: sessionContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Item {
                    width: Style.space(30)
                    height: width
                    anchors.verticalCenter: parent.verticalCenter

                    AgentAvatar {
                      anchors.fill: parent
                      size: parent.width
                      name: modelData.agentName || modelData.agentId || ""
                      emoji: modelData.agentEmoji || ""
                      avatar: modelData.agentAvatarFile || modelData.agentAvatar || ""
                      foreground: root.foreground
                      accent: root.accent
                    }

                    Rectangle {
                      visible: modelData.active
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      color: root.accent
                      border.width: 1
                      border.color: Color.popups.background
                    }
                  }

                  Column {
                    width: parent.width - Style.space(30) - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Row {
                      width: parent.width
                      spacing: Style.space(4)

                      Text {
                        width: parent.width - unreadBadge.width - (unreadBadge.visible ? parent.spacing : 0)
                        text: modelData.agentName || modelData.agentId || modelData.title || modelData.key
                        textFormat: Text.PlainText
                        color: sessionRow.selected ? root.accent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Rectangle {
                        id: unreadBadge
                        visible: service.unreadFor(modelData.key) > 0
                        implicitWidth: unreadText.implicitWidth + Style.space(8)
                        implicitHeight: unreadText.implicitHeight + Style.space(2)
                        radius: height / 2
                        color: root.accent

                        Text {
                          id: unreadText
                          anchors.centerIn: parent
                          text: service.unreadFor(modelData.key) > 99 ? "99+" : String(service.unreadFor(modelData.key))
                          textFormat: Text.PlainText
                          color: Color.background
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }

                    Item {
                      width: parent.width
                      height: sessionTitle.implicitHeight

                      Text {
                        id: sessionTitle
                        width: parent.width - (timeLabel.visible ? timeLabel.width + Style.space(6) : 0)
                        text: modelData.title || modelData.key
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      Text {
                        id: timeLabel
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.formatTime(modelData.lastActivityAt)
                        textFormat: Text.PlainText
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                MouseArea {
                  id: sessionMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.sessionCursor = index
                    service.selectSession(modelData.key)
                  }
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

              AgentAvatar {
                Layout.preferredWidth: Style.space(30)
                Layout.preferredHeight: Style.space(30)
                size: Style.space(30)
                name: service.selectedSession ? (service.selectedSession.agentName || service.selectedSession.agentId || "") : ""
                emoji: service.selectedSession ? (service.selectedSession.agentEmoji || "") : ""
                avatar: service.selectedSession ? (service.selectedSession.agentAvatarFile || service.selectedSession.agentAvatar || "") : ""
                foreground: root.foreground
                accent: root.accent
              }

              Column {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: service.selectedSession
                    ? (service.selectedSession.agentName || service.selectedSession.agentId || service.selectedSession.title)
                    : strings.t("panel.noSessions")
                  textFormat: Text.PlainText
                  color: root.focusSection === "chat" ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: service.selectedSession ? service.selectedSession.title : ""
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
                topMargin: Style.space(4)
                bottomMargin: Style.space(4)
                model: service.messages
                onCountChanged: root.scrollChatToBottom()
                onContentHeightChanged: root.scrollChatToBottom()
                onModelChanged: root.scrollChatToBottom()
                onVisibleChanged: if (visible) root.scrollChatToBottom()

                ScrollBar.vertical: ScrollBar {
                  id: messageScrollBar
                  policy: ScrollBar.AlwaysOn
                  visible: messageList.contentHeight > messageList.height
                  width: Style.space(6)
                  padding: 0
                  contentItem: Rectangle {
                    implicitWidth: Style.space(4)
                    radius: width / 2
                    color: messageScrollBar.pressed
                      ? root.accent
                      : (messageScrollBar.hovered ? Util.alpha(root.accent, 0.75) : Util.alpha(root.foreground, 0.35))
                  }
                  background: Rectangle {
                    implicitWidth: Style.space(6)
                    radius: width / 2
                    color: Util.alpha(root.foreground, 0.06)
                  }
                }

                delegate: Item {
                  id: messageItem
                  width: ListView.view.width - Style.space(16)
                  height: messageColumn.implicitHeight + Style.space(10)

                  readonly property bool isUser: modelData.role === "user"
                  readonly property bool isSystem: modelData.role === "system" || modelData.role === "tool"
                  readonly property color bubbleColor: isUser
                    ? Util.alpha(root.accent, 0.16)
                    : (isSystem ? Util.alpha(root.foreground, 0.04) : Util.alpha(root.accent, 0.08))
                  readonly property color bubbleBorder: isUser
                    ? Util.alpha(root.accent, 0.34)
                    : (isSystem ? Util.alpha(root.foreground, 0.10) : Util.alpha(root.accent, 0.20))

                  Column {
                    id: messageColumn
                    width: parent.width
                    spacing: Style.space(3)

                    Text {
                      width: parent.width
                      horizontalAlignment: messageItem.isUser ? Text.AlignRight : Text.AlignLeft
                      text: messageItem.isUser
                        ? strings.t("panel.you")
                        : (messageItem.isSystem
                          ? strings.t("panel.system")
                          : (service.selectedSession
                            ? String(service.selectedSession.agentName || service.selectedSession.agentId || strings.t("panel.assistant")).toUpperCase()
                            : strings.t("panel.assistant")))
                      textFormat: Text.PlainText
                      color: messageItem.isUser ? root.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.0
                    }

                    Rectangle {
                      id: messageBubble
                      width: Math.min(parent.width * 0.82, Style.space(460))
                      height: messageText.implicitHeight + Style.space(16)
                      anchors.right: messageItem.isUser ? parent.right : undefined
                      anchors.left: messageItem.isUser ? undefined : parent.left
                      radius: Style.cornerRadius
                      color: messageItem.bubbleColor
                      border.width: 1
                      border.color: messageItem.bubbleBorder

                      Text {
                        id: messageText
                        width: parent.width - Style.space(16)
                        anchors.centerIn: parent
                        text: Markdown.format(modelData.text)
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        color: messageItem.isSystem ? root.dim : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.italic: messageItem.isSystem
                        lineHeight: 1.3
                        lineHeightMode: Text.ProportionalHeight
                        verticalAlignment: Text.AlignTop
                      }
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
              Layout.fillWidth: true
              text: service.sending
                ? strings.t("panel.sending")
                : (service.selectedActive ? strings.t("panel.running") : strings.t("panel.keyHint"))
              textFormat: Text.PlainText
              color: service.selectedActive || service.sending ? root.accent : root.dim
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
                Keys.priority: Keys.BeforeItem
                onAccepted: root.submit()
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_F1) {
                    root.toggleHelp()
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                    var backward = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)
                    root.cycleFocus(backward ? -1 : 1)
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Escape) {
                    if (root.helpOpen) {
                      root.helpOpen = false
                      root.focusSectionNow("sessions")
                    } else if (root.settingsOpen) {
                      root.closeSettings()
                    } else {
                      root.close()
                    }
                    event.accepted = true
                  }
                }
              }

              Button {
                text: service.sending ? strings.t("panel.sending") : strings.t("panel.send")
                bordered: true
                focusable: false
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

      Rectangle {
        id: overlay
        anchors.fill: parent
        visible: root.settingsOpen || root.helpOpen
        z: 20
        color: Color.popups.background
        border.width: 1
        border.color: Util.alpha(root.foreground, 0.18)
        radius: Style.cornerRadius

        MouseArea {
          anchors.fill: parent
          onClicked: {}
        }

        Column {
          id: overlayContent
          anchors.fill: parent
          anchors.margins: Style.space(16)
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: root.settingsOpen ? strings.t("settings.title") : strings.t("help.title")
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            width: parent.width
            text: root.settingsOpen ? strings.t("settings.hint") : strings.t("help.hint")
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.settingsRows
              delegate: Item {
                id: settingRow
                width: overlayContent.width
                height: settingLabel.implicitHeight + Style.space(10)
                readonly property bool cursor: index === root.settingsCursor

                Rectangle {
                  anchors.fill: parent
                  color: settingRow.cursor ? Util.alpha(root.accent, 0.14) : "transparent"
                  radius: Style.cornerRadius
                }

                Text {
                  id: settingLabel
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - settingValue.width - Style.space(24)
                  text: (settingRow.cursor ? "› " : "  ") + modelData.label
                  textFormat: Text.PlainText
                  color: settingRow.cursor ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: settingRow.cursor
                  elide: Text.ElideRight
                }

                Text {
                  id: settingValue
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.settingDisplay(modelData)
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.settingsCursor = index
                    root.toggleSetting(index)
                  }
                }
              }
            }
          }

          Column {
            visible: root.helpOpen
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.shortcutRows
              delegate: Row {
                width: overlayContent.width
                spacing: Style.space(12)

                Text {
                  width: Style.space(150)
                  text: modelData.key
                  textFormat: Text.PlainText
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  width: parent.width - Style.space(162)
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
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

  Process {
    id: settingsProcess
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("openclaw settings update failed", exitCode)
    }
  }
}
