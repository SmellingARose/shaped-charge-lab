import QtQuick
import ShapedCharge

// Floating transport bar: play / scrub / step through recorded frames, live while a run records.
Rectangle {
    id: root
    implicitHeight: 52
    radius: 26
    color: Qt.rgba(0.063, 0.075, 0.094, 0.92)
    border.color: Theme.hairlineStrong
    readonly property bool hasFrames: SimController.frameCount > 0
    readonly property real fracShown: SimController.frameCount > 1 ? SimController.frameIndex / (SimController.frameCount - 1) : 0

    Row {
        id: left
        x: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4
        IconButton { icon: "back"; size: 30; tip: "Previous frame"; enabled: root.hasFrames; onClicked: SimController.stepFrame(-1) }
        IconButton {
            icon: SimController.playing ? "pause" : "play"
            primary: true
            size: 36
            tip: SimController.playing ? "Pause (Space)" : "Play (Space)"
            enabled: root.hasFrames
            onClicked: SimController.playing = !SimController.playing
        }
        IconButton { icon: "forward"; size: 30; tip: "Next frame"; enabled: root.hasFrames; onClicked: SimController.stepFrame(1) }
    }

    Item {
        id: scrub
        anchors.left: left.right
        anchors.leftMargin: 14
        anchors.right: right.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        height: 30
        opacity: root.hasFrames ? 1 : 0.4

        Rectangle { y: 13; width: parent.width; height: 4; radius: 2; color: Theme.raised2 }
        Rectangle {    // recorded so far (grows while running)
            y: 13; height: 4; radius: 2
            width: parent.width * (SimController.running ? Math.max(0.02, SimController.progress) : (root.hasFrames ? 1 : 0))
            color: Qt.rgba(0.913, 0.922, 0.945, 0.18)
            Behavior on width { NumberAnimation { duration: 200 } }
        }
        Rectangle {    // played
            y: 13; height: 4; radius: 2
            width: root.fracShown * parent.width * (SimController.running ? Math.max(0.02, SimController.progress) : 1)
            color: Theme.accent
        }
        Rectangle {
            visible: root.hasFrames
            x: root.fracShown * parent.width * (SimController.running ? Math.max(0.02, SimController.progress) : 1) - 7
            y: 8; width: 14; height: 14; radius: 7
            color: Theme.text
            border.color: Theme.accent
            border.width: 2
        }
        MouseArea {
            anchors.fill: parent
            enabled: root.hasFrames
            cursorShape: Qt.PointingHandCursor
            preventStealing: true
            function seek(mx) {
                const span = scrub.width * (SimController.running ? Math.max(0.02, SimController.progress) : 1)
                SimController.playing = false
                SimController.frameIndex = Math.round(Math.max(0, Math.min(1, mx / span)) * (SimController.frameCount - 1))
            }
            onPressed: (m) => seek(m.x)
            onPositionChanged: (m) => { if (pressed) seek(m.x) }
        }
    }

    Row {
        id: right
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10
        Rectangle {
            visible: SimController.running && SimController.live && !SimController.playing
            anchors.verticalCenter: parent.verticalCenter
            width: liveText.implicitWidth + 16; height: 20; radius: 10
            color: Qt.rgba(0.898, 0.396, 0.357, 0.16)
            Text { id: liveText; anchors.centerIn: parent; text: "LIVE"; color: Theme.danger; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1 }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.hasFrames ? (SimController.frameIndex + 1) + " / " + SimController.frameCount : "no frames yet"
            color: Theme.textDim
            font.family: Theme.mono
            font.pixelSize: Theme.fontSmall
        }
        Segmented {
            anchors.verticalCenter: parent.verticalCenter
            compact: true
            options: ["½×", "1×", "2×"]
            currentIndex: SimController.playbackFps <= 15 ? 0 : (SimController.playbackFps >= 60 ? 2 : 1)
            onActivated: (i) => SimController.playbackFps = [15, 30, 60][i]
        }
        IconButton {
            icon: "loop"; size: 28; tip: "Loop playback"
            checked: SimController.loop
            onClicked: SimController.loop = !SimController.loop
        }
    }
}
