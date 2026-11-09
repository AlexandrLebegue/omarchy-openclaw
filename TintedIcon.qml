import QtQuick
import QtQuick.Effects

// Paint a monochrome SVG in the current theme colour. MultiEffect's
// colorization preserves the source's lightness, so a black glyph stays black
// on a dark bar; masking a foreground-filled rectangle with the glyph's alpha
// keeps the icon readable in every theme.
Item {
  id: root

  property url source
  property color color: "white"
  property real iconSize: 16

  implicitWidth: iconSize
  implicitHeight: iconSize

  Image {
    id: maskImage
    anchors.fill: parent
    source: root.source
    sourceSize: Qt.size(Math.round(root.iconSize * 2), Math.round(root.iconSize * 2))
    smooth: true
    visible: false
    layer.enabled: true
  }

  Rectangle {
    anchors.fill: parent
    color: root.color
    layer.enabled: true
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: maskImage
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
    }
  }
}
