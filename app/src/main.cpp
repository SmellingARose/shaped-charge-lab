#include <QCommandLineParser>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTimer>

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
    cli.addOptions({shot, quitAfter, autoRun});
    cli.process(app);

    QQmlApplicationEngine engine;
    engine.setInitialProperties({{QStringLiteral("autoRun"), cli.isSet(autoRun)}});
    engine.loadFromModule("ShapedCharge", "Main");
    if (engine.rootObjects().isEmpty()) return 1;

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
