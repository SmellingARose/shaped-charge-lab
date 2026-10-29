import QtQuick

// Small vector icons drawn on a canvas, so they stay crisp at any scale without image assets.
Canvas {
    id: icon
    property string name: "play"
    property color color: Theme.text
    implicitWidth: 16
    implicitHeight: 16
    onNameChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
        const c = getContext("2d")
        c.reset()
        const w = width, h = height
        c.fillStyle = color
        c.strokeStyle = color
        c.lineWidth = Math.max(1.5, w / 10)
        c.lineCap = "round"
        c.lineJoin = "round"
        c.beginPath()
        switch (name) {
        case "play":
            c.moveTo(w * 0.28, h * 0.18); c.lineTo(w * 0.82, h * 0.5); c.lineTo(w * 0.28, h * 0.82); c.closePath(); c.fill(); break
        case "pause":
            c.rect(w * 0.24, h * 0.2, w * 0.18, h * 0.6); c.rect(w * 0.58, h * 0.2, w * 0.18, h * 0.6); c.fill(); break
        case "stop":
            c.rect(w * 0.24, h * 0.24, w * 0.52, h * 0.52); c.fill(); break
        case "back":
            c.moveTo(w * 0.78, h * 0.22); c.lineTo(w * 0.38, h * 0.5); c.lineTo(w * 0.78, h * 0.78); c.closePath(); c.fill()
            c.beginPath(); c.rect(w * 0.2, h * 0.22, w * 0.12, h * 0.56); c.fill(); break
        case "forward":
            c.moveTo(w * 0.22, h * 0.22); c.lineTo(w * 0.62, h * 0.5); c.lineTo(w * 0.22, h * 0.78); c.closePath(); c.fill()
            c.beginPath(); c.rect(w * 0.68, h * 0.22, w * 0.12, h * 0.56); c.fill(); break
        case "chevron":
            c.moveTo(w * 0.3, h * 0.4); c.lineTo(w * 0.5, h * 0.6); c.lineTo(w * 0.7, h * 0.4); c.stroke(); break
        case "loop":
            c.arc(w * 0.5, h * 0.5, w * 0.3, Math.PI * 0.15, Math.PI * 1.75); c.stroke()
            c.beginPath(); c.moveTo(w * 0.78, h * 0.2); c.lineTo(w * 0.8, h * 0.42); c.lineTo(w * 0.58, h * 0.4); c.stroke(); break
        case "camera":
            c.arc(w * 0.5, h * 0.5, w * 0.32, 0, Math.PI * 2); c.stroke()
            c.beginPath(); c.arc(w * 0.5, h * 0.5, w * 0.1, 0, Math.PI * 2); c.fill(); break
        case "warning":
            c.moveTo(w * 0.5, h * 0.12); c.lineTo(w * 0.92, h * 0.86); c.lineTo(w * 0.08, h * 0.86); c.closePath(); c.stroke()
            c.beginPath(); c.moveTo(w * 0.5, h * 0.4); c.lineTo(w * 0.5, h * 0.6); c.stroke()
            c.beginPath(); c.arc(w * 0.5, h * 0.73, w * 0.04, 0, Math.PI * 2); c.fill(); break
        case "reset":
            c.arc(w * 0.5, h * 0.52, w * 0.3, Math.PI * 1.25, Math.PI * 3.0); c.stroke()
            c.beginPath(); c.moveTo(w * 0.2, h * 0.16); c.lineTo(w * 0.27, h * 0.36); c.lineTo(w * 0.47, h * 0.3); c.stroke(); break
        case "spark":
            for (let k = 0; k < 8; k++) {
                const a = k * Math.PI / 4, r0 = k % 2 ? w * 0.18 : w * 0.1, r1 = k % 2 ? w * 0.34 : w * 0.46
                c.moveTo(w / 2 + Math.cos(a) * r0, h / 2 + Math.sin(a) * r0); c.lineTo(w / 2 + Math.cos(a) * r1, h / 2 + Math.sin(a) * r1)
            }
            c.stroke(); break
        }
    }
}
