import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

Item {
  id: root

  // Injected by the Omarchy shell service loader.
  property var shell: null

  property var settings: ({})
  property var settingsKey: ""
  property string bridgeKey: ""
  property bool configured: false
  property bool panelOpen: false
  property var openPanels: []

  // Connection / gateway
  property string status: "starting"
  property string detail: ""
  property string lastError: ""
  property var gatewayInfo: null
  property string pairingRequestId: ""
  property string pairingCommand: ""

  // Sessions
  property var sessions: []
  property int activeCount: 0
  property string selectedKey: ""

  // Transcript
  property var messages: []
  property bool sending: false
  property bool loadingHistory: false
  property string pendingUserText: ""

  // Unread bookkeeping keyed by session key.
  property var unreadBySession: ({})
  readonly property int unread: {
    var total = 0
    for (var key in unreadBySession) total += Number(unreadBySession[key]) || 0
    return total
  }

  signal finished(var session, string preview)
  signal pairingRequired(string requestId, string command)

  readonly property string bridgePath: decodeURIComponent(String(Qt.resolvedUrl("bridge.mjs")).replace(/^file:\/\//, ""))
  readonly property string pluginDir: bridgePath.substring(0, bridgePath.lastIndexOf("/"))
  readonly property string iconPath: decodeURIComponent(String(Qt.resolvedUrl("assets/openclaw.png")).replace(/^file:\/\//, ""))
  readonly property string iconInstallScript: decodeURIComponent(String(Qt.resolvedUrl("install-icon.sh")).replace(/^file:\/\//, ""))
  readonly property string nodePath: String(setting("nodePath", "/usr/bin/node"))
  readonly property string gatewayUrl: String(setting("gatewayUrl", ""))
  readonly property string gatewayToken: String(setting("gatewayToken", ""))
  readonly property int maxSessions: Math.max(3, Math.min(100, parseInt(String(setting("maxSessions", 20)), 10) || 20))
  readonly property int refreshIntervalSec: Math.max(15, Math.min(600, parseInt(String(setting("refreshIntervalSec", 60)), 10) || 60))
  readonly property bool notificationsEnabled: setting("notifications", true) !== false
  readonly property bool notifyOnlyWhenClosed: setting("notifyOnlyWhenClosed", false) === true

  readonly property var selectedSession: {
    for (var i = 0; i < sessions.length; i++)
      if (sessions[i].key === selectedKey) return sessions[i]
    return null
  }
  readonly property bool selectedActive: selectedSession ? selectedSession.active === true : false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function shorten(value, max) {
    var text = String(value || "").replace(/\s+/g, " ").trim()
    return text.length > max ? text.slice(0, max) + "…" : text
  }

  function applySettings(value) {
    var next = value && typeof value === "object" ? value : ({})
    var key = JSON.stringify(next)
    var bridgeSettings = JSON.stringify([
      String(next.gatewayUrl || ""),
      String(next.gatewayToken || ""),
      Number(next.maxSessions || 20),
      String(next.nodePath || "/usr/bin/node")
    ])
    var changed = key !== settingsKey
    if (changed) {
      settings = next
      settingsKey = key
    }
    if (!configured) {
      configured = true
      bridgeKey = bridgeSettings
      bridge.running = true
    } else if (bridgeSettings !== bridgeKey) {
      bridgeKey = bridgeSettings
      if (bridge.running) bridge.running = false
      restartTimer.restart()
    }
  }

  function panelOpened(panel) {
    if (openPanels.indexOf(panel) < 0) openPanels = openPanels.concat([panel])
    panelOpen = openPanels.length > 0
  }

  function panelClosed(panel) {
    openPanels = openPanels.filter(function(item) { return item !== panel })
    panelOpen = openPanels.length > 0
  }

  function unreadFor(key) {
    return Number(unreadBySession[String(key)] || 0)
  }

  function markRead(key) {
    if (!key || !unreadBySession[String(key)]) return
    var next = Object.assign({}, unreadBySession)
    delete next[String(key)]
    unreadBySession = next
  }

  function sendCommand(command) {
    if (!bridge.running || !bridge.stdinEnabled) return false
    bridge.write(JSON.stringify(command) + "\n")
    return true
  }

  function refresh() {
    sendCommand({ op: "refresh" })
  }

  function reconnect() {
    sendCommand({ op: "reconnect" })
  }

  function selectSession(key) {
    key = String(key || "")
    if (!key) return
    selectedKey = key
    markRead(key)
    loadingHistory = true
    sendCommand({ op: "select", sessionKey: key })
  }

  function sendMessage(text) {
    var clean = String(text || "").trim()
    if (!clean || !selectedKey || sending || status !== "online") return false
    pendingUserText = clean
    sending = true
    sendTimeout.restart()
    messages = messages.concat([{
      id: "local-" + Date.now(),
      role: "user",
      text: clean,
      ts: Date.now(),
      local: true
    }])
    sendCommand({
      op: "send",
      id: ++requestSeq,
      sessionKey: selectedKey,
      message: clean
    })
    return true
  }

  function abort() {
    if (!selectedKey) return
    sendCommand({ op: "abort", id: ++requestSeq, sessionKey: selectedKey })
  }

  function reconcileSelection() {
    if (sessions.length === 0) {
      selectedKey = ""
      messages = []
      loadingHistory = false
      return
    }
    var found = false
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i].key === selectedKey) { found = true; break }
    }
    if (!found) {
      var preferred = null
      for (var j = 0; j < sessions.length; j++) {
        if (sessions[j].active) { preferred = sessions[j]; break }
      }
      if (!preferred) preferred = sessions[0]
      selectSession(preferred.key)
    } else if (!selectedActive) {
      sending = false
    }
  }

  function mergePending(serverMessages) {
    var list = Array.isArray(serverMessages) ? serverMessages.slice() : []
    if (!pendingUserText) return list
    var found = false
    for (var i = Math.max(0, list.length - 8); i < list.length; i++) {
      if (list[i].role === "user" && list[i].text === pendingUserText) { found = true; break }
    }
    if (found) {
      pendingUserText = ""
    } else {
      list.push({
        id: "local-" + selectedKey,
        role: "user",
        text: pendingUserText,
        ts: Date.now(),
        local: true
      })
    }
    return list
  }

  function handleLine(line) {
    var msg
    try {
      msg = JSON.parse(String(line || ""))
    } catch (e) {
      console.warn("openclaw", "bad bridge line", line)
      return
    }

    if (msg.type === "status") {
      status = String(msg.status || "unknown")
      detail = String(msg.detail || "")
      if (status === "online") lastError = ""
      return
    }

    if (msg.type === "hello") {
      gatewayInfo = msg
      status = "online"
      lastError = ""
      if (selectedKey) sendCommand({ op: "select", sessionKey: selectedKey })
      return
    }

    if (msg.type === "sessions") {
      sessions = Array.isArray(msg.sessions) ? msg.sessions : []
      activeCount = Number(msg.activeCount) || 0
      reconcileSelection()
      return
    }

    if (msg.type === "history") {
      if (String(msg.sessionKey || "") !== selectedKey) return
      messages = mergePending(msg.messages)
      loadingHistory = false
      if (msg.session && msg.session.active !== true) sending = false
      return
    }

    if (msg.type === "finished") {
      handleFinished(msg.session || {}, String(msg.preview || ""))
      return
    }

    if (msg.type === "pairing") {
      var requestId = String(msg.requestId || "")
      var changed = requestId !== pairingRequestId
      pairingRequestId = requestId
      pairingCommand = String(msg.command || "")
      status = "pairing"
      detail = requestId
      if (changed) pairingRequired(requestId, pairingCommand)
      return
    }

    if (msg.type === "error") {
      lastError = String(msg.message || "Erreur OpenClaw")
      if (status !== "online") status = "error"
      return
    }

    if (msg.type === "result") {
      if (msg.id === requestSeq) {
        sending = false
        sendTimeout.stop()
        if (msg.ok !== true) lastError = String(msg.error || "Envoi refusé")
      }
      return
    }
  }

  function handleFinished(session, preview) {
    var key = String(session.key || "")
    if (!key) return
    var addUnread = key !== selectedKey || !panelOpen
    if (addUnread) {
      var next = Object.assign({}, unreadBySession)
      next[key] = Number(next[key] || 0) + 1
      unreadBySession = next
    }
    finished(session, preview)
    if (!notificationsEnabled) return
    if (notifyOnlyWhenClosed && panelOpen) return
    var agent = String(session.agentId || "").trim()
    var name = agent || shorten(String(session.title || "OpenClaw"), 40)
    var title = strings.t("notify.finishedTitle").arg(name)
    var detail = shorten(String(session.title || ""), 80)
    var body = preview || strings.t("notify.finishedBody")
    if (detail && detail !== name) body = detail + " · " + body
    queueNotification(title, body)
  }

  function queueNotification(title, body) {
    notifyQueue = notifyQueue.concat([{ title: String(title), body: String(body) }])
    drainNotifications()
  }

  function drainNotifications() {
    if (notifier.running || notifyQueue.length === 0) return
    var next = notifyQueue[0]
    notifyQueue = notifyQueue.slice(1)
    notifier.command = [
      "omarchy", "notification", "send",
      "--app-name", "OpenClaw",
      "-i", "openclaw",
      "-u", "normal",
      next.title, next.body,
      "--exec", "omarchy-shell", "alexandrlebegue.openclaw", "open"
    ]
    notifier.running = true
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var notifyQueue: []
  property int requestSeq: 0

  Timer {
    id: sendTimeout
    interval: 180000
    onTriggered: {
      root.sending = false
      root.lastError = strings.t("error.timeout")
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.status === "online"
    onTriggered: root.refresh()
  }

  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: {
      if (root.configured && !bridge.running) bridge.running = true
    }
  }

  Process {
    id: bridge
    command: [root.nodePath, root.bridgePath]
    workingDirectory: root.pluginDir
    running: false
    stdinEnabled: true
    environment: {
      var env = {
        OC_STATE_DIR: Quickshell.env("HOME") + "/.local/state/omarchy-openclaw",
        OC_MAX_SESSIONS: String(root.maxSessions)
      }
      if (root.gatewayUrl.trim() !== "") env.OC_GATEWAY_URL = root.gatewayUrl.trim()
      if (root.gatewayToken.trim() !== "") env.OC_GATEWAY_TOKEN = root.gatewayToken.trim()
      return env
    }
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "")
        if (text.length > 0) console.warn("openclaw", text)
      }
    }
    onExited: function(exitCode) {
      root.status = "offline"
      root.detail = "bridge " + exitCode
      if (!root.lastError) root.lastError = strings.t("error.bridge")
      restartTimer.restart()
    }
  }

  Process {
    id: notifier
    onExited: root.drainNotifications()
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "")
        if (text.length > 0) console.warn("openclaw notify", text)
      }
    }
  }

  Process {
    id: iconInstaller
    command: ["sh", root.iconInstallScript, root.iconPath]
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("openclaw icon install failed", exitCode)
    }
  }

  Component.onCompleted: iconInstaller.running = true
}
