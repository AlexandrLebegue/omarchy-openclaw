import QtQuick

// Keyboard dispatcher for the OpenClaw panel. Based on Omarchy's
// PanelKeyCatcher, with F1 added and every handled key consumed so the
// layer-shell surface never leaks it to another handler.
Item {
  id: root

  property bool blocked: false

  signal moveRequested(int dx, int dy)
  signal activateRequested()
  signal closeRequested()
  signal deleteRequested()
  signal tabRequested(int direction)
  signal textKey(string text, int modifiers)
  signal helpRequested()

  focus: true
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (root.blocked) return

    if (event.key === Qt.Key_F1) {
      root.helpRequested()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Escape) {
      root.closeRequested()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      var direction = (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1
      root.tabRequested(direction)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Down || event.text === "j") {
      root.moveRequested(0, 1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Up || event.text === "k") {
      root.moveRequested(0, -1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Right || event.text === "l") {
      root.moveRequested(1, 0)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Left || event.text === "h") {
      root.moveRequested(-1, 0)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.activateRequested()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Space) {
      root.activateRequested()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Delete || event.text === "x" || event.text === "X") {
      root.deleteRequested()
      event.accepted = true
      return
    }
    if (event.text && event.text.length === 1) {
      root.textKey(event.text, event.modifiers)
      event.accepted = true
    }
  }
}
