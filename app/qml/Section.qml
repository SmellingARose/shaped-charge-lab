import QtQuick

// Collapsible card for a group of parameters.
Rectangle {
    id: root
    property string title: ""
    property string subtitle: ""
    property bool expanded: true
    default property alias content: body.data

    width: parent ? parent.width : 300
    implicitHeight: header.height + (expanded ? body.implicitHeight + 16 : 0)
    height: implicitHeight
    radius: Theme.radius
    color: Theme.card
    border.color: Theme.hairline
    clip: true
    Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

    Item {
        id: header
        width: parent.width
        height: 42
        Text {
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            text: root.title
            color: Theme.text
            font.pixelSize: Theme.fontBody
            font.weight: Font.DemiBold
        }
        Text {
            anchors.right: chevron.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: root.subtitle
            color: Theme.textFaint
            font.pixelSize: Theme.fontSmall
        }
        Icon {
            id: chevron
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 14; height: 14
            name: "chevron"
            color: Theme.textDim
            rotation: root.expanded ? 0 : -90
            Behavior on rotation { NumberAnimation { duration: 160 } }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.expanded = !root.expanded
        }
    }
    Column {
        id: body
        y: header.height
        x: 14
        width: parent.width - 28
        spacing: 16
        opacity: root.expanded ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }
}
