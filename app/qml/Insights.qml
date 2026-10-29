import QtQuick
import ShapedCharge

// Right-hand panel: the jet's velocity profile, penetration versus standoff, and run diagnostics.
Rectangle {
    id: root
    color: Theme.panel

    Flickable {
        anchors.fill: parent
        anchors.margins: 14
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col
            width: parent.width
            spacing: 12

            Text { text: "Insights"; color: Theme.text; font.pixelSize: Theme.fontTitle; font.weight: Font.DemiBold; topPadding: 4 }

            // ---- velocity profile
            Rectangle {
                width: parent.width
                height: 230
                radius: Theme.radius
                color: Theme.card
                border.color: Theme.hairline
                Column {
                    x: 14; y: 12; width: parent.width - 28
                    spacing: 2
                    Text { text: "Jet velocity along the axis"; color: Theme.text; font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold }
                    Text {
                        width: parent.width
                        text: "Each dot is a piece of the liner. The slope from tip to tail is what stretches the jet."
                        wrapMode: Text.WordWrap
                        color: Theme.textFaint; font.pixelSize: Theme.fontSmall
                    }
                }
                PlotItem {
                    x: 6; y: 60; width: parent.width - 12; height: parent.height - 66
                    points: SimController.jetSamples
                    autoX: true
                    xMin: -20; xMax: 60
                    yMin: 0; yMax: 9
                    dimBelowY: 2
                    xLabel: "mm past the charge face"
                    yLabel: "km/s"
                    pointColor: Theme.copper
                    dimPointColor: "#4E5462"
                    textColor: Theme.textFaint
                    gridColor: Theme.hairline
                }
                Text {
                    visible: SimController.jetSamples.length === 0
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: 20
                    text: "Appears once the liner moves"
                    color: Theme.textFaint; font.pixelSize: Theme.fontSmall
                }
            }

            // ---- penetration vs standoff
            Rectangle {
                width: parent.width
                height: 268
                radius: Theme.radius
                color: Theme.card
                border.color: Theme.hairline
                Column {
                    x: 14; y: 12; width: parent.width - 28
                    spacing: 2
                    Text { text: "Penetration vs standoff"; color: Theme.text; font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold }
                    Text {
                        width: parent.width
                        text: SimController.jetSummary.length ? SimController.jetSummary
                              : "Computed from the jet this charge actually forms. Run once to measure it."
                        wrapMode: Text.WordWrap
                        color: Theme.textFaint; font.pixelSize: Theme.fontSmall
                    }
                }
                PlotItem {
                    id: curvePlot
                    x: 6; y: 60; width: parent.width - 12; height: parent.height - 92
                    line: SimController.curve
                    markers: SimController.results
                    highlight: SimController.optimum
                    highlightLabel: SimController.optimum.x >= 0 ? "best " + SimController.optimum.x.toFixed(1) + " CD" : ""
                    ruleX: SimController.standoff
                    xMin: 0; xMax: 10; yMin: 0; yMax: 2; autoY: true
                    xLabel: "standoff (CD)"
                    yLabel: "depth (CD)"
                    lineColor: Theme.accent
                    markerColor: Theme.steel
                    textColor: Theme.textFaint
                    gridColor: Theme.hairline
                }
                Row {
                    x: 14
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 12
                    spacing: 14
                    Repeater {
                        model: [
                            { c: Theme.accent, t: "1D model", sq: false },
                            { c: Theme.steel, t: "3D runs", sq: true },
                            { c: Theme.textFaint, t: "current standoff", sq: false }
                        ]
                        delegate: Row {
                            required property var modelData
                            spacing: 5
                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8; height: modelData.sq ? 8 : 3; radius: modelData.sq ? 1 : 1.5; color: modelData.c }
                            Text { text: modelData.t; color: Theme.textDim; font.pixelSize: 10 }
                        }
                    }
                }
            }

            // ---- run diagnostics
            Rectangle {
                width: parent.width
                implicitHeight: diag.implicitHeight + 24
                radius: Theme.radius
                color: Theme.card
                border.color: Theme.hairline
                Column {
                    id: diag
                    x: 14; y: 12; width: parent.width - 28
                    spacing: 8
                    Text { text: "Run"; color: Theme.text; font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold }
                    Grid {
                        columns: 2
                        columnSpacing: 12
                        rowSpacing: 6
                        width: parent.width
                        Repeater {
                            model: [
                                ["Device", SimController.hasRun ? SimController.runDevice : "—"],
                                ["Simulated", SimController.hasRun ? SimController.simTime.toFixed(1) + " µs" : "—"],
                                ["Step time", SimController.hasRun ? SimController.msPerStep.toFixed(1) + " ms" : "—"],
                                ["Particles", SimController.hasRun ? (SimController.particleCount / 1000).toFixed(0) + "k" : "—"],
                                ["Frames", SimController.frameCount + (SimController.memoryMB > 0 ? " · " + SimController.memoryMB + " MB" : "")]
                            ]
                            delegate: Item {
                                required property var modelData
                                width: (diag.width - 12) / 2
                                height: 30
                                Column {
                                    spacing: 1
                                    Text { text: modelData[0]; color: Theme.textFaint; font.pixelSize: 10 }
                                    Text { text: modelData[1]; color: Theme.text; font.pixelSize: Theme.fontSmall; elide: Text.ElideRight; width: (diag.width - 12) / 2 }
                                }
                            }
                        }
                    }
                    Row {
                        visible: SimController.refinementExhausted
                        spacing: 8
                        Icon { name: "warning"; color: Theme.warn; width: 14; height: 14 }
                        Text {
                            width: diag.width - 24
                            text: "Ran out of refinement slots. Results are under-refined; lower the resolution or refinement levels."
                            wrapMode: Text.WordWrap
                            color: Theme.warn; font.pixelSize: Theme.fontSmall
                        }
                    }
                }
            }
        }
    }
}
