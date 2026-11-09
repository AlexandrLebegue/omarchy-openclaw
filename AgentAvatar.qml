import QtQuick
import QtQuick.Effects
import qs.Commons

// Circular agent avatar. Uses the OpenClaw agent identity avatar when it is a
// data/http/file image, otherwise the identity emoji or the agent initial.
Item {
  id: root

  property string name: ""
  property string emoji: ""
  property string avatar: ""
  property real size: 28
  property color foreground: Color.foreground
  property color accent: Color.accent

  readonly property string imageSource: {
    var value = String(avatar || "")
    if (/^data:image\//i.test(value)) return value
    if (/^https?:\/\//i.test(value)) return value
    if (/^file:\/\//i.test(value)) return value
    if (value.charAt(0) === "/") return "file://" + value
    return ""
  }
  readonly property bool hasImage: imageSource !== ""
  readonly property string initial: {
    var text = String(name || "").trim()
    return text.length > 0 ? text.slice(0, 1).toUpperCase() : "?"
  }

  implicitWidth: size
  implicitHeight: size

  Rectangle {
    anchors.fill: parent
    visible: !root.hasImage
    radius: width / 2
    color: Util.alpha(root.accent, 0.16)
    border.width: 1
    border.color: Util.alpha(root.accent, 0.38)

    Text {
      anchors.centerIn: parent
      text: root.emoji || root.initial
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Math.max(10, Math.round(root.size * 0.42))
      font.bold: true
    }
  }

  Item {
    anchors.fill: parent
    visible: root.hasImage

    Rectangle {
      id: circleMask
      anchors.fill: parent
      radius: width / 2
      color: "white"
      visible: false
      layer.enabled: true
    }

    Image {
      anchors.fill: parent
      source: root.imageSource
      sourceSize: Qt.size(Math.round(root.size * 2), Math.round(root.size * 2))
      fillMode: Image.PreserveAspectCrop
      smooth: true
      layer.enabled: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: circleMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }
    }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      border.width: 1
      border.color: Util.alpha(root.accent, 0.38)
    }
  }
}
