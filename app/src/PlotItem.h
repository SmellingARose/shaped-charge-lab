// Lightweight antialiased chart: a scatter or line series, highlighted points, a vertical rule.
#pragma once

#include <QColor>
#include <QPointF>
#include <QQuickPaintedItem>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

class PlotItem : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantList points MEMBER m_points NOTIFY changed)       // scatter dots
    Q_PROPERTY(QVariantList line MEMBER m_line NOTIFY changed)           // polyline (with soft area fill)
    Q_PROPERTY(QVariantList markers MEMBER m_markers NOTIFY changed)     // emphasised points (squares)
    Q_PROPERTY(QPointF highlight MEMBER m_highlight NOTIFY changed)      // labelled point (x < 0 = none)
    Q_PROPERTY(QString highlightLabel MEMBER m_highlightLabel NOTIFY changed)
    Q_PROPERTY(double ruleX MEMBER m_ruleX NOTIFY changed)               // vertical dashed rule (NaN = none)
    Q_PROPERTY(double xMin MEMBER m_xMin NOTIFY changed)
    Q_PROPERTY(double xMax MEMBER m_xMax NOTIFY changed)
    Q_PROPERTY(double yMin MEMBER m_yMin NOTIFY changed)
    Q_PROPERTY(double yMax MEMBER m_yMax NOTIFY changed)
    Q_PROPERTY(bool autoY MEMBER m_autoY NOTIFY changed)
    Q_PROPERTY(bool autoX MEMBER m_autoX NOTIFY changed)
    Q_PROPERTY(QString xLabel MEMBER m_xLabel NOTIFY changed)
    Q_PROPERTY(QString yLabel MEMBER m_yLabel NOTIFY changed)
    Q_PROPERTY(QColor pointColor MEMBER m_pointColor NOTIFY changed)
    Q_PROPERTY(QColor dimPointColor MEMBER m_dimPointColor NOTIFY changed)
    Q_PROPERTY(double dimBelowY MEMBER m_dimBelowY NOTIFY changed)       // dots below this y use the dim colour
    Q_PROPERTY(QColor lineColor MEMBER m_lineColor NOTIFY changed)
    Q_PROPERTY(QColor markerColor MEMBER m_markerColor NOTIFY changed)
    Q_PROPERTY(QColor textColor MEMBER m_textColor NOTIFY changed)
    Q_PROPERTY(QColor gridColor MEMBER m_gridColor NOTIFY changed)

public:
    explicit PlotItem(QQuickItem* parent = nullptr);
    void paint(QPainter* p) override;

signals:
    void changed();

private:
    QVariantList m_points, m_line, m_markers;
    QPointF m_highlight{-1, -1};
    QString m_highlightLabel;
    double m_ruleX = qQNaN();
    double m_xMin = 0, m_xMax = 1, m_yMin = 0, m_yMax = 1;
    bool m_autoY = false, m_autoX = false;
    QString m_xLabel, m_yLabel;
    QColor m_pointColor{"#E58A5E"}, m_dimPointColor{"#5B606C"}, m_lineColor{"#F2A541"}, m_markerColor{"#8FB3D9"};
    QColor m_textColor{"#8A90A0"}, m_gridColor{"#22262E"};
    double m_dimBelowY = -1e9;
};
