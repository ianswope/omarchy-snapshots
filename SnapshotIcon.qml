import QtQuick
import qs.Commons

// A stack of slabs: the machine's history, most recent on top. Drawn with plain
// rectangles rather than Shape paths because the bar renders this around 12px,
// where straight edges stay crisp and a drawn outline turns to mush.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // Dims the layers underneath the top one. The newest snapshot is the one that
  // matters at a glance; the rest are depth.
  property real tailOpacity: 0.45

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real slabHeight: Math.max(1, Math.round(root.iconSize * 0.16))
  readonly property real gap: Math.max(1, Math.round(root.iconSize * 0.11))
  readonly property real stackHeight: slabHeight * 3 + gap * 2

  Item {
    width: parent.width
    height: root.stackHeight
    anchors.centerIn: parent

    Slab {
      inset: 0
      slabOpacity: 1.0
      y: 0
    }
    Slab {
      inset: root.iconSize * 0.13
      slabOpacity: root.tailOpacity
      y: root.slabHeight + root.gap
    }
    Slab {
      inset: root.iconSize * 0.26
      slabOpacity: root.tailOpacity * 0.6
      y: (root.slabHeight + root.gap) * 2
    }
  }

  component Slab: Rectangle {
    property real inset: 0
    property real slabOpacity: 1.0

    x: inset / 2
    width: root.iconSize - inset
    height: root.slabHeight
    radius: Math.min(height / 2, Style.space(2))
    color: root.color
    opacity: slabOpacity
    antialiasing: true
  }
}
