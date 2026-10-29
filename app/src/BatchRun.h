// Unattended runs from the command line: set parameters, optionally find the optimal standoff first, run to the
// end, and export every recorded frame of the 3D view as PNG (for a video).
#pragma once
#include <QFile>
#include <QObject>
#include <QStringList>
#include <QTimer>

class QQuickWindow;
class SimController;

class BatchRun : public QObject {
    Q_OBJECT
public:
    struct Options {
        QStringList set;            // key=value, as SimController::setParam
        bool optimalStandoff = false;
        QString videoDir;           // empty: no export
        double frameMemoryGB = 0;   // 0: default
    };
    BatchRun(SimController* sim, QQuickWindow* window, Options o, QObject* parent = nullptr);

private:
    enum class Stage { Measure, Run, Export, Done };
    void tick();
    void startRun();
    void exportFrames();
    void log(const QString& line);

    SimController* sim_;
    QQuickWindow* window_;
    Options o_;
    Stage stage_;
    bool stopping_ = false;
    QTimer timer_;
    QFile log_;
};
