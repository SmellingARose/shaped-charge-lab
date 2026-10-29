// 3D view of a simulation frame, rendered through Qt RHI (Metal / Direct3D 12 / Vulkan from one code path).
#pragma once

#include <QPointer>
#include <QQuickRhiItem>
#include <QVector3D>
#include <QtQml/qqmlregistration.h>

#include "SimController.h"

class ParticleView : public QQuickRhiItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(SimController* controller READ controller WRITE setController NOTIFY controllerChanged)
    Q_PROPERTY(int colorMode MEMBER m_colorMode NOTIFY viewChanged)          // 0 material, 1 speed, 2 pressure, 3 temperature, 4 strain
    Q_PROPERTY(double cutaway MEMBER m_cutaway NOTIFY viewChanged)           // degrees of the wedge removed
    Q_PROPERTY(bool showGas MEMBER m_showGas NOTIFY viewChanged)
    Q_PROPERTY(bool showExplosive MEMBER m_showExplosive NOTIFY viewChanged)
    Q_PROPERTY(bool showTarget MEMBER m_showTarget NOTIFY viewChanged)
    Q_PROPERTY(bool showGrid MEMBER m_showGrid NOTIFY viewChanged)
    Q_PROPERTY(bool bloom MEMBER m_bloom NOTIFY viewChanged)
    Q_PROPERTY(bool follow MEMBER m_follow NOTIFY viewChanged)

public:
    explicit ParticleView(QQuickItem* parent = nullptr);
    QQuickRhiItemRenderer* createRenderer() override;

    SimController* controller() const { return m_controller; }
    void setController(SimController* c);

    Q_INVOKABLE void resetCamera();

    struct Camera {
        float yaw = -0.55f, pitch = 0.28f, distance = 8.0f;
        QVector3D target{0, 0, 0};
        bool userMoved = false;
    };

signals:
    void controllerChanged();
    void viewChanged();

protected:
    void mousePressEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void wheelEvent(QWheelEvent*) override;

private:
    friend class ParticleRenderer;
    QPointer<SimController> m_controller;
    int m_colorMode = 0;
    double m_cutaway = 90;
    bool m_showGas = true, m_showExplosive = true, m_showTarget = true, m_showGrid = true, m_bloom = true, m_follow = false;
    Camera m_cam;
    QPointF m_lastPos;
    Qt::MouseButton m_button = Qt::NoButton;
    bool m_resetRequested = true;
};
