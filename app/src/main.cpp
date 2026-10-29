#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>
#include "BatchRun.h"
#include "SimController.h"

int main(int argc, char* argv[]) {
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("Shaped Charge Lab"));
    QGuiApplication::setOrganizationName(QStringLiteral("Shaped Charge Lab"));
    QGuiApplication::setApplicationVersion(QStringLiteral(SCL_VERSION));
    QQuickStyle::setStyle(QStringLiteral("Basic"));   // every control is styled by the app itself

    // --screenshot <file> --quit-after <seconds> [--run]: used by CI smoke tests and for docs images
    QCommandLineParser cli;
    cli.addHelpOption();
    cli.addVersionOption();
    QCommandLineOption shot("screenshot", "Save a window screenshot to <file>.", "file");
    QCommandLineOption quitAfter("quit-after", "Quit after <seconds>.", "seconds");
    QCommandLineOption autoRun("run", "Start a run on launch.");
    // Unattended runs: --set key=value ... [--optimal-standoff] [--video <dir>] (see BatchRun.h)
    QCommandLineOption set("set", "Set a parameter before running (repeatable), e.g. layers=4.", "key=value");
    QCommandLineOption optimal("optimal-standoff", "Measure the jet first, then run at the standoff that drills deepest.");
    QCommandLineOption video("video", "Run to the end, then save every frame of the 3D view as PNG in <dir>; then quit.", "dir");
    QCommandLineOption windowSize("window", "Window size, e.g. 1920x1080.", "WxH");
    QCommandLineOption frameMemory("frame-memory-gb", "Memory for recorded frames (default 3).", "GB");
    cli.addOptions({shot, quitAfter, autoRun, set, optimal, video, windowSize, frameMemory});
    cli.process(app);

    const bool batch = cli.isSet(set) || cli.isSet(optimal) || cli.isSet(video);
    QVariantMap initial{{QStringLiteral("autoRun"), cli.isSet(autoRun) && !batch},
                        {QStringLiteral("videoMode"), cli.isSet(video)}};
    if (cli.isSet(windowSize)) {
        const QStringList wh = cli.value(windowSize).split(QLatin1Char('x'));
        if (wh.size() == 2) { initial[QStringLiteral("width")] = wh[0].toInt(); initial[QStringLiteral("height")] = wh[1].toInt(); }
    }
    QQmlApplicationEngine engine;
    engine.setInitialProperties(initial);
    engine.loadFromModule("ShapedCharge", "Main");
    if (engine.rootObjects().isEmpty()) return 1;
    auto* window = qobject_cast<QQuickWindow*>(engine.rootObjects().first());

    if (batch) {
        BatchRun::Options o;
        o.set = cli.values(set);
        o.optimalStandoff = cli.isSet(optimal);
        o.videoDir = cli.value(video);
        o.frameMemoryGB = cli.value(frameMemory).toDouble();
        new BatchRun(engine.singletonInstance<SimController*>("ShapedCharge", "SimController"), window, o, &app);
    }

    if (cli.isSet(quitAfter)) {
        const int ms = int(cli.value(quitAfter).toDouble() * 1000);
        const QString path = cli.value(shot);
        QTimer::singleShot(ms, &app, [&engine, path] {
            if (!path.isEmpty())
                if (auto* w = qobject_cast<QQuickWindow*>(engine.rootObjects().first())) w->grabWindow().save(path);
            QCoreApplication::quit();
        });
    }
    return app.exec();
}
