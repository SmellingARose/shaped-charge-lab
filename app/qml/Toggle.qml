import QtQuick

// Compact on/off chip.
Rectangle {
    id: root
    property string text: ""
    property bool checked: true
    signal toggled(bool on)

    implicitHeight: 26
    implicitWidth: label.implicitWidth + 30
    radius: 13
    color: checked ? Theme.accentSoft : (area.containsMouse ? Theme.raised : "transparent")
    border.color: checked ? Qt.rgba(0.949, 0.647, 0.255, 0.55) : Theme.hairlineStrong
    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        width: 6; height: 6; radius: 3
        color: root.checked ? Theme.accent : Theme.textFaint
    }
    Text {
        id: label
        x: 21
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        font.pixelSize: Theme.fontSmall
        color: root.checked ? Theme.text : Theme.textDim
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.checked = !root.checked; root.toggled(root.checked) }
    }
}
