import QtQuick

// Parameter slider showing where real hardware sits: a tinted band for the realistic range and a
// labelled tick for the most representative value (click the tick to jump to it).
Item {
    id: root
    required property var p
    property real value: p.value
    property bool dragging: false
    signal committed(real v)

    implicitHeight: column.implicitHeight
    width: parent ? parent.width : 280

    function frac(v) { return Math.max(0, Math.min(1, (v - p.min) / (p.max - p.min))) }
    function snap(v) {
        const s = p.step
        v = Math.max(p.min, Math.min(p.max, v))
        return s > 0 ? Math.round((v - p.min) / s) * s + p.min : v
    }
    function show(v) { return (v * p.scale).toFixed(p.decimals) + (p.unit.length ? (p.unit === "°" || p.unit === "×" || p.unit === "%" ? "" : " ") + p.unit : "") }
    readonly property bool realistic: value >= p.realLow - 1e-9 && value <= p.realHigh + 1e-9

    Column {
        id: column
        width: parent.width
        spacing: 7

        Item {
            width: parent.width
            height: 18
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.p.label
                color: Theme.text
                font.pixelSize: Theme.fontLabel
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Rectangle {
                    visible: !root.realistic
                    anchors.verticalCenter: parent.verticalCenter
                    width: offText.implicitWidth + 10; height: 16; radius: 8
                    color: Qt.rgba(0.91, 0.71, 0.30, 0.12)
                    Text { id: offText; anchors.centerIn: parent; text: "outside real range"; color: Theme.warn; font.pixelSize: 10 }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.show(root.value)
                    color: root.dragging ? Theme.accent : Theme.text
                    font.family: Theme.mono
                    font.pixelSize: Theme.fontLabel
                }
            }
        }

        Item {
            id: track
            width: parent.width
            height: 26

            Rectangle {   // rail
                id: rail
                y: 13
                width: parent.width; height: 4; radius: 2
                color: Theme.raised2
            }
            Rectangle {   // realistic band
                x: root.frac(root.p.realLow) * track.width
                y: 11
                width: Math.max(3, (root.frac(root.p.realHigh) - root.frac(root.p.realLow)) * track.width)
                height: 8; radius: 4
                color: Theme.accentSoft
                border.color: Theme.accentBand
            }
            Rectangle {   // fill
                y: 13
                width: root.frac(root.value) * track.width
                height: 4; radius: 2
                color: Qt.rgba(0.913, 0.922, 0.945, 0.55)
            }
            Item {        // realistic tick (clickable)
                id: tick
                x: root.frac(root.p.realistic) * track.width - 8
                width: 16; height: 26
                Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: 1; width: 2; height: 9; radius: 1; color: Theme.accent }
                MouseArea {
                    id: tickArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.value = root.p.realistic; root.committed(root.value) }
                }
                Rectangle {
                    visible: tickArea.containsMouse
                    y: -24
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: tickTip.implicitWidth + 12; height: 20; radius: 5
                    color: Theme.raised2
                    border.color: Theme.hairlineStrong
                    z: 5
                    Text { id: tickTip; anchors.centerIn: parent; text: "Realistic: " + root.show(root.p.realistic); color: Theme.text; font.pixelSize: 10 }
                }
            }
            Rectangle {   // handle
                x: root.frac(root.value) * track.width - width / 2
                y: 15 - height / 2
                width: dragArea.pressed ? 16 : 14
                height: width
                radius: width / 2
                color: Theme.text
                border.color: dragArea.containsMouse || dragArea.pressed ? Theme.accent : Theme.bg
                border.width: 2
                Behavior on width { NumberAnimation { duration: 90 } }
            }
            MouseArea {
                id: dragArea
                anchors.fill: parent
                anchors.topMargin: 10
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.PointingHandCursor
                function apply(mx) { root.value = root.snap(root.p.min + Math.max(0, Math.min(1, mx / track.width)) * (root.p.max - root.p.min)) }
                onPressed: (m) => { root.dragging = true; apply(m.x) }
                onPositionChanged: (m) => { if (pressed) apply(m.x) }
                onReleased: { root.dragging = false; root.committed(root.value) }
                onDoubleClicked: { root.value = root.p.realistic; root.committed(root.value) }
            }
        }

        Text {
            width: parent.width
            text: root.p.note
            wrapMode: Text.WordWrap
            color: Theme.textFaint
            font.pixelSize: Theme.fontSmall
            lineHeight: 1.15
        }
    }
}
