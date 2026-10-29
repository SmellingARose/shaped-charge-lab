import QtQuick
import QtQuick.Window
import ShapedCharge

Window {
    id: win
    property bool autoRun: false
    width: 1480
    height: 920
    minimumWidth: 1100
    minimumHeight: 700
    visible: true
    color: Theme.bg
    title: "Shaped Charge Lab"

    readonly property var groups: ["Charge", "Explosive", "Target", "Imperfections", "Resolution", "Jet model"]
    readonly property var groupNotes: ({ "Charge": "geometry", "Explosive": "drive", "Target": "armor",
                                         "Imperfections": "asymmetry", "Resolution": "accuracy vs time", "Jet model": "breakup" })

    Component.onCompleted: if (autoRun) SimController.start()

    Shortcut { sequence: "Space"; onActivated: SimController.playing = !SimController.playing }
    Shortcut { sequence: "R"; onActivated: SimController.running ? SimController.stop() : SimController.start() }
    Shortcut { sequence: "Left"; onActivated: SimController.stepFrame(-1) }
    Shortcut { sequence: "Right"; onActivated: SimController.stepFrame(1) }
    Shortcut { sequence: "F"; onActivated: view.follow = !view.follow }
    Shortcut { sequence: "C"; onActivated: view.resetCamera() }
    Shortcut { sequence: "1"; onActivated: view.colorMode = 0 }
    Shortcut { sequence: "2"; onActivated: view.colorMode = 1 }
    Shortcut { sequence: "3"; onActivated: view.colorMode = 2 }
    Shortcut { sequence: "4"; onActivated: view.colorMode = 3 }
    Shortcut { sequence: "5"; onActivated: view.colorMode = 4 }

    // ------------------------------------------------------------ sidebar
    Rectangle {
        id: sidebar
        width: 336
        height: parent.height
        color: Theme.panel
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.hairline }

        Column {
            id: brand
            x: 18; y: 18
            width: parent.width - 36
            spacing: 2
            Row {
                spacing: 10
                Rectangle {
                    width: 26; height: 26; radius: 8
                    color: Theme.accentSoft
                    border.color: Qt.rgba(0.949, 0.647, 0.255, 0.5)
                    Icon { anchors.centerIn: parent; width: 16; height: 16; name: "spark"; color: Theme.accent }
                }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Shaped Charge Lab"; color: Theme.text; font.pixelSize: 17; font.weight: Font.DemiBold }
            }
            Text { leftPadding: 36; text: "Full 3D hydrocode · jet formation and penetration"; color: Theme.textFaint; font.pixelSize: Theme.fontSmall }
        }

        // run card
        Rectangle {
            id: runCard
            x: 14; y: brand.y + brand.height + 16
            width: parent.width - 28
            implicitHeight: runCol.implicitHeight + 28
            height: implicitHeight
            radius: Theme.radius
            color: Theme.card
            border.color: Theme.hairline

            Column {
                id: runCol
                x: 14; y: 14
                width: parent.width - 28
                spacing: 12

                Text { text: "Compute on"; color: Theme.textFaint; font.pixelSize: 10; font.letterSpacing: 0.8 }
                Column {
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: SimController.devices
                        delegate: Rectangle {
                            required property int index
                            required property string modelData
                            width: runCol.width
                            height: 30
                            radius: Theme.radiusSmall
                            color: index === SimController.deviceIndex ? Theme.raised : (devArea.containsMouse ? Qt.rgba(1, 1, 1, 0.03) : "transparent")
                            border.color: index === SimController.deviceIndex ? Theme.hairlineStrong : "transparent"
                            Rectangle {
                                x: 10; anchors.verticalCenter: parent.verticalCenter
                                width: 12; height: 12; radius: 6
                                color: "transparent"
                                border.color: index === SimController.deviceIndex ? Theme.accent : Theme.textFaint
                                border.width: 1.5
                                Rectangle { anchors.centerIn: parent; width: 6; height: 6; radius: 3; color: Theme.accent; visible: index === SimController.deviceIndex }
                            }
                            Text { x: 30; anchors.verticalCenter: parent.verticalCenter; text: modelData; color: Theme.text; font.pixelSize: Theme.fontLabel; elide: Text.ElideRight; width: parent.width - 40 }
                            MouseArea { id: devArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; enabled: !SimController.running; onClicked: SimController.deviceIndex = index }
                        }
                    }
                }
                ParamSlider {
                    visible: SimController.deviceIsCpu
                    p: ({ label: "CPU threads", unit: "", scale: 1, decimals: 0, step: 1, min: 1, max: SimController.maxCpuThreads,
                          realLow: Math.max(1, SimController.maxCpuThreads - 2), realHigh: SimController.maxCpuThreads,
                          realistic: SimController.maxCpuThreads, note: "More threads run faster; leave a couple free to keep the rest of the computer responsive.",
                          value: SimController.cpuThreads })
                    onCommitted: (v) => SimController.cpuThreads = Math.round(v)
                }

                // big action button
                Rectangle {
                    id: runButton
                    width: parent.width
                    height: 44
                    radius: 22
                    readonly property bool busy: SimController.running
                    color: busy ? (runArea.containsMouse ? Theme.raised2 : Theme.raised) : (runArea.pressed ? Theme.accent : runArea.containsMouse ? Theme.accentHover : Theme.accent)
                    border.color: busy ? Theme.hairlineStrong : "transparent"
                    Behavior on color { ColorAnimation { duration: 140 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Icon { anchors.verticalCenter: parent.verticalCenter; width: 14; height: 14; name: runButton.busy ? "stop" : "play"; color: runButton.busy ? Theme.text : Theme.accentInk }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: runButton.busy ? "Stop · " + SimController.simTime.toFixed(1) + " µs" : (SimController.hasRun ? "Run again" : "Run simulation")
                            color: runButton.busy ? Theme.text : Theme.accentInk
                            font.pixelSize: Theme.fontBody
                            font.weight: Font.DemiBold
                        }
                    }
                    MouseArea { id: runArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: SimController.running ? SimController.stop() : SimController.start() }
                }
                Rectangle {    // run progress
                    visible: SimController.running
                    width: parent.width; height: 4; radius: 2
                    color: Theme.raised2
                    Rectangle {
                        width: parent.width * SimController.progress
                        height: parent.height; radius: 2
                        color: Theme.accent
                        Behavior on width { NumberAnimation { duration: 250 } }
                    }
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: SimController.running ? (SimController.msPerStep.toFixed(1) + " ms per step · " + SimController.frameCount + " frames recorded")
                                                : SimController.estimate
                    color: Theme.textFaint
                    font.pixelSize: Theme.fontSmall
                }
            }
        }

        // parameters
        Flickable {
            id: paramScroll
            anchors.top: runCard.bottom
            anchors.topMargin: 12
            anchors.bottom: footer.top
            x: 14
            width: parent.width - 28
            contentHeight: params.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: params
                width: paramScroll.width
                spacing: 10
                Repeater {
                    model: win.groups
                    delegate: Section {
                        required property string modelData
                        required property int index
                        title: modelData
                        subtitle: win.groupNotes[modelData]
                        expanded: index < 3
                        Segmented {
                            visible: modelData === "Charge"
                            width: parent.width
                            options: ["Copper", "Tantalum", "Aluminum"]
                            currentIndex: SimController.liner
                            onActivated: (i) => SimController.liner = i
                        }
                        Segmented {
                            visible: modelData === "Target"
                            width: parent.width
                            options: ["Armor steel", "Aluminum 6061"]
                            currentIndex: SimController.target
                            onActivated: (i) => SimController.target = i
                        }
                        Repeater {
                            model: SimController.params.filter(x => x.group === modelData)
                            delegate: ParamSlider {
                                required property var modelData
                                p: modelData
                                onCommitted: (v) => SimController.setParam(p.key, v)
                            }
                        }
                    }
                }
            }
        }

        Item {
            id: footer
            anchors.bottom: parent.bottom
            width: parent.width
            height: 44
            Rectangle { width: parent.width; height: 1; color: Theme.hairline }
            Text {
                x: 18; anchors.verticalCenter: parent.verticalCenter
                text: "Reset parameters"
                color: resetArea.containsMouse ? Theme.text : Theme.textDim
                font.pixelSize: Theme.fontSmall
                MouseArea { id: resetArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: SimController.resetParams() }
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 18; anchors.verticalCenter: parent.verticalCenter
                text: "R run · Space play · ← → step"
                color: Theme.textFaint
                font.pixelSize: 10
            }
        }
    }

    // ------------------------------------------------------------ 3D view
    Item {
        id: stage
        anchors.left: sidebar.right
        anchors.right: insights.left
        height: parent.height

        ParticleView {
            id: view
            anchors.fill: parent
            controller: SimController
        }

        // Beside the view controls when the stage is wide enough, otherwise underneath them
        Hud {
            readonly property real roomBeside: stage.width - viewControls.width - 48
            readonly property bool beside: roomBeside >= 300
            x: 16
            y: beside ? 16 : viewControls.y + viewControls.height + 12
            width: Math.min(440, beside ? roomBeside : stage.width - 32)
        }

        // view controls
        Column {
            id: viewControls
            anchors.right: parent.right
            anchors.rightMargin: 16
            y: 16
            spacing: 8
            Segmented {
                anchors.right: parent.right
                options: ["Material", "Speed", "Pressure", "Temp", "Strain"]
                currentIndex: view.colorMode
                onActivated: (i) => view.colorMode = i
            }
            Row {
                anchors.right: parent.right
                spacing: 6
                Toggle { text: "Gas"; checked: view.showGas; onToggled: (on) => view.showGas = on }
                Toggle { text: "Explosive"; checked: view.showExplosive; onToggled: (on) => view.showExplosive = on }
                Toggle { text: "Target"; checked: view.showTarget; onToggled: (on) => view.showTarget = on }
                Toggle { text: "Grid"; checked: view.showGrid; onToggled: (on) => view.showGrid = on }
            }
            Row {
                anchors.right: parent.right
                spacing: 6
                Toggle { text: "Bloom"; checked: view.bloom; onToggled: (on) => view.bloom = on }
                Toggle { text: "Follow jet"; checked: view.follow; onToggled: (on) => view.follow = on }
                IconButton { icon: "camera"; size: 26; tip: "Reset camera (C)"; onClicked: view.resetCamera() }
            }
            Rectangle {
                anchors.right: parent.right
                width: 236; height: 34; radius: 17
                color: Qt.rgba(0.063, 0.075, 0.094, 0.85)
                border.color: Theme.hairline
                Text { x: 14; anchors.verticalCenter: parent.verticalCenter; text: "Cutaway"; color: Theme.textDim; font.pixelSize: Theme.fontSmall }
                Item {
                    id: cutTrack
                    x: 76; width: 112; height: parent.height
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; radius: 2; color: Theme.raised2 }
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width * view.cutaway / 180; height: 4; radius: 2; color: Theme.accent }
                    Rectangle { x: parent.width * view.cutaway / 180 - 6; anchors.verticalCenter: parent.verticalCenter; width: 12; height: 12; radius: 6; color: Theme.text }
                    MouseArea {
                        anchors.fill: parent
                        preventStealing: true
                        cursorShape: Qt.PointingHandCursor
                        function set(mx) { view.cutaway = Math.round(Math.max(0, Math.min(1, mx / cutTrack.width)) * 18) * 10 }
                        onPressed: (m) => set(m.x)
                        onPositionChanged: (m) => { if (pressed) set(m.x) }
                    }
                }
                Text { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; text: view.cutaway.toFixed(0) + "°"; color: Theme.text; font.family: Theme.mono; font.pixelSize: Theme.fontSmall }
            }
        }

        // colour legend
        Rectangle {
            visible: view.colorMode > 0
            x: 16
            anchors.bottom: timeline.top
            anchors.bottomMargin: 12
            width: 250; height: 46; radius: Theme.radiusSmall
            color: Qt.rgba(0.063, 0.075, 0.094, 0.85)
            border.color: Theme.hairline
            readonly property var ranges: [["", "", ""], ["Speed", "0", "8.5 km/s"], ["Pressure", "0", "60 GPa (log)"], ["Temperature", "300", "1600 K"], ["Plastic strain", "0", "3"]]
            Text { x: 12; y: 7; text: parent.ranges[view.colorMode][0]; color: Theme.textDim; font.pixelSize: 10 }
            Rectangle {
                x: 12; y: 22; width: parent.width - 24; height: 6; radius: 3
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "#30123b" }
                    GradientStop { position: 0.2; color: "#4686fb" }
                    GradientStop { position: 0.4; color: "#1ae4b6" }
                    GradientStop { position: 0.6; color: "#a2fc3c" }
                    GradientStop { position: 0.8; color: "#fb8022" }
                    GradientStop { position: 1.0; color: "#7a0403" }
                }
            }
            Text { x: 12; y: 30; text: parent.ranges[view.colorMode][1]; color: Theme.textFaint; font.pixelSize: 10 }
            Text { anchors.right: parent.right; anchors.rightMargin: 12; y: 30; text: parent.ranges[view.colorMode][2]; color: Theme.textFaint; font.pixelSize: 10 }
        }

        Timeline {
            id: timeline
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            width: Math.min(760, parent.width - 32)
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.bottom: timeline.top
            anchors.bottomMargin: 14
            text: "Drag to orbit · right-drag to pan · scroll to zoom"
            color: Theme.textFaint
            font.pixelSize: 10
        }
    }

    // ------------------------------------------------------------ insights
    Insights {
        id: insights
        anchors.right: parent.right
        width: 352
        height: parent.height
        Rectangle { width: 1; height: parent.height; color: Theme.hairline }
    }
}
