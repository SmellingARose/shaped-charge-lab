import QtQuick

// Round icon button with hover and pressed states and an optional tooltip line.
Rectangle {
    id: root
    property string icon: "play"
    property string tip: ""
    property bool primary: false
    property bool checked: false
    property int size: 32
    signal clicked()

    implicitWidth: size
    implicitHeight: size
    radius: size / 2
    opacity: enabled ? 1 : 0.35
    color: primary ? (area.pressed ? Theme.accent : area.containsMouse ? Theme.accentHover : Theme.accent)
                   : (checked ? Theme.accentSoft : area.pressed ? Theme.raised2 : area.containsMouse ? Theme.raised : "transparent")
    border.color: primary ? "transparent" : (checked ? Theme.accent : Theme.hairlineStrong)
    border.width: primary ? 0 : 1
    Behavior on color { ColorAnimation { duration: 120 } }

    Icon {
        anchors.centerIn: parent
        width: root.size * 0.48
        height: width
        name: root.icon
        color: root.primary ? Theme.accentInk : (root.checked ? Theme.accent : Theme.text)
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
    Rectangle {
        visible: area.containsMouse && root.tip.length > 0
        y: -height - 6
        anchors.horizontalCenter: parent.horizontalCenter
        width: tipText.implicitWidth + 14
        height: 22
        radius: 6
        color: Theme.raised2
        border.color: Theme.hairlineStrong
        z: 10
        Text { id: tipText; anchors.centerIn: parent; text: root.tip; color: Theme.text; font.pixelSize: Theme.fontSmall }
    }
}
