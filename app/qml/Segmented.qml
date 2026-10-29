import QtQuick

// Segmented control with a sliding highlight.
Rectangle {
    id: root
    property var options: []
    property int currentIndex: 0
    property bool compact: false
    signal activated(int index)

    implicitHeight: compact ? 26 : 30
    implicitWidth: row.implicitWidth + 6
    radius: Theme.radiusSmall
    color: Theme.raised
    border.color: Theme.hairline

    Rectangle {
        id: pill
        y: 3
        height: parent.height - 6
        radius: Theme.radiusSmall - 2
        color: Theme.raised2
        border.color: Theme.hairlineStrong
        x: repeater.count > 0 && repeater.itemAt(root.currentIndex) ? repeater.itemAt(root.currentIndex).x + 3 : 3
        width: repeater.count > 0 && repeater.itemAt(root.currentIndex) ? repeater.itemAt(root.currentIndex).width : 0
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }
    Row {
        id: row
        x: 3
        height: parent.height
        Repeater {
            id: repeater
            model: root.options
            delegate: Item {
                required property int index
                required property var modelData
                width: Math.max(label.implicitWidth + (root.compact ? 16 : 22), (root.width - 6) / Math.max(1, repeater.count))
                height: row.height
                Text {
                    id: label
                    anchors.centerIn: parent
                    text: modelData
                    font.pixelSize: root.compact ? Theme.fontSmall : Theme.fontLabel
                    font.weight: index === root.currentIndex ? Font.DemiBold : Font.Normal
                    color: index === root.currentIndex ? Theme.text : Theme.textDim
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.currentIndex = index; root.activated(index) }
                }
            }
        }
    }
}
