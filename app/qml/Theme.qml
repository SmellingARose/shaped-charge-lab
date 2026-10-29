pragma Singleton
import QtQuick

// Visual tokens: a dark studio palette with one warm accent (the detonation amber).
QtObject {
    readonly property color bg: "#0B0D11"
    readonly property color panel: "#101318"
    readonly property color card: "#151920"
    readonly property color raised: "#1C212A"
    readonly property color raised2: "#252B36"
    readonly property color hairline: "#20252E"
    readonly property color hairlineStrong: "#2E3542"

    readonly property color text: "#E9EBF1"
    readonly property color textDim: "#A2A9B8"
    readonly property color textFaint: "#666E7E"

    readonly property color accent: "#F2A541"
    readonly property color accentHover: "#F7B862"
    readonly property color accentInk: "#2A1A04"
    readonly property color accentSoft: Qt.rgba(0.949, 0.647, 0.255, 0.16)
    readonly property color accentBand: Qt.rgba(0.949, 0.647, 0.255, 0.38)
    readonly property color copper: "#E58A5E"
    readonly property color steel: "#8FB3D9"
    readonly property color good: "#5CC28A"
    readonly property color warn: "#E8B44D"
    readonly property color danger: "#E5655B"

    readonly property int radius: 10
    readonly property int radiusSmall: 7

    readonly property string mono: Qt.platform.os === "osx" ? "Menlo" : (Qt.platform.os === "windows" ? "Cascadia Mono" : "monospace")
    readonly property int fontBody: 13
    readonly property int fontSmall: 11
    readonly property int fontLabel: 12
    readonly property int fontTitle: 15

    function phaseColor(phase) {
        switch (phase) {
        case "Detonation": return accent
        case "Liner collapse":
        case "Jet stretching":
        case "Jet breakup": return copper
        case "Penetration": return steel
        case "Complete": return good
        default: return textDim
        }
    }
}
