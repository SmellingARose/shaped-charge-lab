#include "PlotItem.h"

#include <QPainter>
#include <QPainterPath>
#include <algorithm>
#include <cmath>

namespace {

/// "Nice" tick step for a span (1, 2 or 5 × 10^k).
double niceStep(double span, int target) {
    const double raw = span / std::max(target, 1);
    const double mag = std::pow(10.0, std::floor(std::log10(raw)));
    const double f = raw / mag;
    return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * mag;
}

QString fmt(double v, double step) {
    const int dec = step >= 1 ? 0 : step >= 0.1 ? 1 : 2;
    return QString::number(v, 'f', dec);
}

}  // namespace

PlotItem::PlotItem(QQuickItem* parent) : QQuickPaintedItem(parent) {
    setAntialiasing(true);
    connect(this, &PlotItem::changed, this, [this] { update(); });
}

void PlotItem::paint(QPainter* p) {
    p->setRenderHint(QPainter::Antialiasing);
    double x0 = m_xMin, x1 = m_xMax, y0 = m_yMin, y1 = m_yMax;
    auto grow = [&](const QVariantList& l) {
        for (const QVariant& v : l) {
            const QPointF q = v.toPointF();
            if (m_autoX) { x0 = std::min(x0, q.x()); x1 = std::max(x1, q.x()); }
            if (m_autoY) y1 = std::max(y1, q.y() * 1.1);
        }
    };
    grow(m_points); grow(m_line); grow(m_markers);
    if (x1 <= x0) x1 = x0 + 1;
    if (y1 <= y0) y1 = y0 + 1;

    QFont f = p->font();
    f.setPixelSize(10);
    p->setFont(f);
    const QFontMetrics fm(f);
    const double left = 34, bottom = 22, top = 8, right = 8;
    const QRectF area(left, top, width() - left - right, height() - top - bottom);
    if (area.width() < 20 || area.height() < 20) return;
    auto X = [&](double v) { return area.left() + (v - x0) / (x1 - x0) * area.width(); };
    auto Y = [&](double v) { return area.bottom() - (v - y0) / (y1 - y0) * area.height(); };

    // grid and ticks
    const double ys = niceStep(y1 - y0, 4), xs = niceStep(x1 - x0, 5);
    p->setPen(QPen(m_gridColor, 1));
    for (double v = std::ceil(y0 / ys) * ys; v <= y1 + 1e-9; v += ys) {
        p->drawLine(QPointF(area.left(), Y(v)), QPointF(area.right(), Y(v)));
        p->setPen(m_textColor);
        p->drawText(QRectF(0, Y(v) - 7, left - 6, 14), Qt::AlignRight | Qt::AlignVCenter, fmt(v, ys));
        p->setPen(QPen(m_gridColor, 1));
    }
    p->setPen(m_textColor);
    for (double v = std::ceil(x0 / xs) * xs; v <= x1 + 1e-9; v += xs)
        p->drawText(QRectF(X(v) - 20, area.bottom() + 4, 40, 14), Qt::AlignHCenter | Qt::AlignTop, fmt(v, xs));
    if (!m_xLabel.isEmpty())   // inside the plot, just above the axis, so it never collides with tick labels
        p->drawText(QRectF(area.left(), area.bottom() - 16, area.width() - 2, 14), Qt::AlignRight | Qt::AlignBottom, m_xLabel);
    if (!m_yLabel.isEmpty()) p->drawText(QRectF(area.left() + 4, area.top(), 200, 14), Qt::AlignLeft | Qt::AlignTop, m_yLabel);

    p->save();
    p->setClipRect(area.adjusted(-4, -4, 4, 4));
    // line with a soft area fill
    if (m_line.size() > 1) {
        QPainterPath path, fill;
        for (int i = 0; i < m_line.size(); i++) {
            const QPointF q = m_line[i].toPointF();
            const QPointF s(X(q.x()), Y(q.y()));
            if (i == 0) { path.moveTo(s); fill.moveTo(s.x(), area.bottom()); fill.lineTo(s); }
            else { path.lineTo(s); fill.lineTo(s); }
        }
        fill.lineTo(X(m_line.last().toPointF().x()), area.bottom());
        fill.closeSubpath();
        QColor a = m_lineColor;
        a.setAlphaF(0.12);
        p->fillPath(fill, a);
        p->setPen(QPen(m_lineColor, 2, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p->drawPath(path);
    }
    // scatter
    p->setPen(Qt::NoPen);
    for (const QVariant& v : m_points) {
        const QPointF q = v.toPointF();
        p->setBrush(q.y() < m_dimBelowY ? m_dimPointColor : m_pointColor);
        p->drawEllipse(QPointF(X(q.x()), Y(q.y())), 1.6, 1.6);
    }
    // vertical rule
    if (!std::isnan(m_ruleX)) {
        QPen pen(m_textColor, 1, Qt::DashLine);
        pen.setDashPattern({3, 3});
        p->setPen(pen);
        p->drawLine(QPointF(X(m_ruleX), area.top()), QPointF(X(m_ruleX), area.bottom()));
    }
    // emphasised points
    p->setPen(QPen(QColor("#0E1014"), 1.5));
    p->setBrush(m_markerColor);
    for (const QVariant& v : m_markers) {
        const QPointF q = v.toPointF();
        p->drawRect(QRectF(X(q.x()) - 4, Y(q.y()) - 4, 8, 8));
    }
    p->restore();
    // labelled highlight
    if (m_highlight.x() >= 0) {
        const QPointF s(X(m_highlight.x()), Y(m_highlight.y()));
        p->setPen(QPen(QColor("#0E1014"), 2));
        p->setBrush(m_lineColor);
        p->drawEllipse(s, 4.5, 4.5);
        if (!m_highlightLabel.isEmpty()) {
            QFont bf = f;
            bf.setBold(true);
            p->setFont(bf);
            p->setPen(m_lineColor);
            const int w = QFontMetrics(bf).horizontalAdvance(m_highlightLabel);
            const double tx = std::clamp(s.x() - w / 2.0, area.left(), area.right() - w);
            p->drawText(QPointF(tx, std::max(s.y() - 9, area.top() + 10)), m_highlightLabel);
        }
    }
}
