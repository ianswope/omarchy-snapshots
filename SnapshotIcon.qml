import QtQuick
import qs.Commons

// A stack of cards receding up and to the right: copies of the same thing at
// different points in time. Drawn with rounded rectangles rather than Shape
// paths because the bar renders this around 12px, where a stroked outline turns
// to mush. Three evenly-spaced horizontal bars were the first attempt and read
// as a hamburger menu at that size, which is why the cards are offset on both
// axes instead.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // The cards behind the front one are depth, not content: keeping them faint
  // is what stops the glyph reading as a solid block at small sizes.
  property real tailOpacity: 0.45

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real step: Math.max(1, Math.round(iconSize * 0.16))
  readonly property real cardSize: iconSize - step * 2

  // Front card at the bottom-left, each earlier one stepped up and right.
  Card {
    depth: 2
    cardOpacity: root.tailOpacity * 0.55
  }

  Card {
    depth: 1
    cardOpacity: root.tailOpacity
  }

  Card {
    depth: 0
    cardOpacity: 1.0
  }

  component Card: Rectangle {
    property int depth: 0
    property real cardOpacity: 1.0

    x: root.step * depth
    y: root.step * (2 - depth)
    width: root.cardSize
    height: root.cardSize
    radius: Math.max(1, Math.round(root.iconSize * 0.14))
    color: "transparent"
    border.width: Math.max(1, Math.round(root.iconSize * 0.09))
    border.color: root.color
    opacity: cardOpacity
    antialiasing: true
  }
}
