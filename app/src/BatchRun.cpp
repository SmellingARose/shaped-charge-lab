#include "BatchRun.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QImage>
#include <QQuickWindow>
#include <cmath>
#include "SimController.h"

BatchRun::BatchRun(SimController* sim, QQuickWindow* window, Options o, QObject* parent)
    : QObject(parent), sim_(sim), window_(window), o_(std::move(o)) {
    if (!o_.videoDir.isEmpty()) QDir().mkpath(o_.videoDir);
    // GUI builds have no console on Windows: progress goes to a log file next to the frames (and to stderr)
    log_.setFileName(QDir(o_.videoDir.isEmpty() ? QDir::currentPath() : o_.videoDir).filePath(QStringLiteral("batch.log")));
    log_.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate);
    if (o_.frameMemoryGB > 0) sim_->setFrameMemoryBudget(size_t(o_.frameMemoryGB * double(size_t(1) << 30)));
    for (const QString& kv : o_.set) {
        const int eq = kv.indexOf(QLatin1Char('='));
        if (eq <= 0) { log(QStringLiteral("ignored --set %1 (expected key=value)").arg(kv)); continue; }
        sim_->setParam(kv.left(eq), kv.mid(eq + 1).toDouble());
        log(QStringLiteral("set %1").arg(kv));
    }
    stage_ = o_.optimalStandoff ? Stage::Measure : Stage::Run;
    log(QStringLiteral("device: %1").arg(sim_->devices().value(sim_->deviceIndex())));
    log(QStringLiteral("estimate: %1").arg(sim_->estimate()));
    connect(&timer_, &QTimer::timeout, this, &BatchRun::tick);
    timer_.start(250);
    QTimer::singleShot(0, this, &BatchRun::startRun);
}

void BatchRun::log(const QString& line) {
    const QString s = QDateTime::currentDateTime().toString(QStringLiteral("hh:mm:ss ")) + line + QLatin1Char('\n');
    log_.write(s.toUtf8());
    log_.flush();
    fputs(s.toUtf8().constData(), stderr);
}

void BatchRun::startRun() {
    log(stage_ == Stage::Measure ? QStringLiteral("measuring the jet (stops once it is measured)")
                                 : QStringLiteral("full run at standoff %1 CD").arg(sim_->standoff(), 0, 'f', 2));
    sim_->start();
}

void BatchRun::tick() {
    static int beat = 0;
    if (stage_ == Stage::Measure) {
        // The jet is measured before it reaches the target, so the target's distance does not change it
        if (!stopping_ && sim_->optimum().x() >= 0) {
            const double best = std::round(sim_->optimum().x() * 20) / 20;   // the standoff slider's 0.05 CD steps
            log(QStringLiteral("jet: %1; optimal standoff %2 CD").arg(sim_->jetSummary()).arg(best, 0, 'f', 2));
            stopping_ = true;
            sim_->stop();
            sim_->setParam(QStringLiteral("standoffCD"), best);
        }
        if (stopping_ && !sim_->running()) {
            stopping_ = false;
            stage_ = Stage::Run;
            startRun();
        }
    } else if (stage_ == Stage::Run) {
        if (++beat % 40 == 0)
            log(QStringLiteral("t %1 us, %2 particles, %3 ms/step, %4 frames, %5")
                    .arg(sim_->simTime(), 0, 'f', 1).arg(sim_->particleCount()).arg(sim_->msPerStep(), 0, 'f', 1)
                    .arg(sim_->frameCount()).arg(sim_->phase()));
        if (sim_->hasRun() && !sim_->running()) {
            log(QStringLiteral("run finished: t %1 us, penetration %2 mm, %3 frames")
                    .arg(sim_->simTime(), 0, 'f', 1).arg(sim_->penetration(), 0, 'f', 1).arg(sim_->frameCount()));
            stage_ = Stage::Export;
            timer_.stop();
            if (o_.videoDir.isEmpty()) { stage_ = Stage::Done; QCoreApplication::quit(); return; }
            QTimer::singleShot(500, this, &BatchRun::exportFrames);
        }
    }
}

void BatchRun::exportFrames() {
    const int n = sim_->frameCount();
    QDir dir(o_.videoDir);
    for (int i = 0; i < n; i++) {
        sim_->setFrameIndex(i);
        QCoreApplication::processEvents();   // bindings (explainer text, numbers) follow the frame
        const QImage img = window_->grabWindow();   // renders the scene synchronously with this frame
        img.save(dir.filePath(QStringLiteral("frame_%1.png").arg(i, 5, 10, QLatin1Char('0'))));
        if (i % 25 == 0 || i == n - 1) log(QStringLiteral("exported frame %1 of %2 (%3x%4)").arg(i + 1).arg(n).arg(img.width()).arg(img.height()));
    }
    log(QStringLiteral("done"));
    stage_ = Stage::Done;
    QCoreApplication::quit();
}
