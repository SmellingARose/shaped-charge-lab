import QtQuick
import ShapedCharge

// Explainer over the 3D view: what phase the charge is in, what that means, and the key numbers.
Rectangle {
    id: root
    implicitHeight: col.implicitHeight + 28
    radius: Theme.radius
    color: Qt.rgba(0.043, 0.051, 0.067, 0.78)
    border.color: Theme.hairline

    readonly property color phaseColor: Theme.phaseColor(SimController.phase)

    Column {
        id: col
        x: 16; y: 14
        width: parent.width - 32
        spacing: 10

        Row {
            spacing: 10
            Rectangle {
                height: 22
                width: phaseLabel.implicitWidth + 22
                radius: 11
                color: Qt.rgba(root.phaseColor.r, root.phaseColor.g, root.phaseColor.b, 0.16)
                border.color: Qt.rgba(root.phaseColor.r, root.phaseColor.g, root.phaseColor.b, 0.55)
                Behavior on color { ColorAnimation { duration: 250 } }
                Rectangle {
                    x: 9; anchors.verticalCenter: parent.verticalCenter
                    width: 6; height: 6; radius: 3
                    color: root.phaseColor
                    SequentialAnimation on opacity {
                        running: SimController.running
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 600 }
                        NumberAnimation { to: 1; duration: 600 }
                    }
                }
                Text {
                    id: phaseLabel
                    x: 19; anchors.verticalCenter: parent.verticalCenter
                    text: SimController.phase
                    color: root.phaseColor
                    font.pixelSize: Theme.fontSmall
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.4
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "t = " + SimController.frameTime.toFixed(2) + " µs"
                color: Theme.text
                font.family: Theme.mono
                font.pixelSize: Theme.fontLabel
            }
        }

        Text {
            width: parent.width
            text: SimController.phaseText
            wrapMode: Text.WordWrap
            color: Theme.textDim
            font.pixelSize: Theme.fontBody
            lineHeight: 1.2
        }

        Row {
            spacing: 22
            visible: SimController.hasRun
            Repeater {
                model: [
                    { k: "Jet tip", v: SimController.tipSpeed.toFixed(2) + " km/s" },
                    { k: "Tip travel", v: SimController.tipTravel.toFixed(0) + " mm" },
                    { k: "Crater", v: SimController.penetration.toFixed(1) + " mm" }
                ]
                delegate: Column {
                    required property var modelData
                    spacing: 2
                    Text { text: modelData.k; color: Theme.textFaint; font.pixelSize: 10; font.letterSpacing: 0.6 }
                    Text { text: modelData.v; color: Theme.text; font.family: Theme.mono; font.pixelSize: Theme.fontBody }
                }
            }
        }
    }
}
