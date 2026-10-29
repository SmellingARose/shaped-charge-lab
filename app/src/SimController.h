// Bridges the simulation core (scl::Run) to QML: parameters, runs, live frames, playback and chart data.
#pragma once

#include <QObject>
#include <QPointF>
#include <QTimer>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>
#include <memory>
#include <mutex>
#include <vector>

#include "scl/api.hpp"

/// The frame the 3D view should draw: particles plus the scene geometry they belong to.
struct ViewFrame {
    std::vector<scl::Particle3D> particles;
    scl::SceneInfo scene{};
    float tipTravel = 0;
};

class SimController : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // parameters (sliders) and pickers
    Q_PROPERTY(QVariantList params READ params NOTIFY paramsChanged)
    Q_PROPERTY(int liner READ liner WRITE setLiner NOTIFY configChanged)
    Q_PROPERTY(int target READ target WRITE setTarget NOTIFY configChanged)
    Q_PROPERTY(QStringList devices READ devices CONSTANT)
    Q_PROPERTY(int deviceIndex READ deviceIndex WRITE setDeviceIndex NOTIFY deviceChanged)
    Q_PROPERTY(bool deviceIsCpu READ deviceIsCpu NOTIFY deviceChanged)
    Q_PROPERTY(int cpuThreads READ cpuThreads WRITE setCpuThreads NOTIFY deviceChanged)
    Q_PROPERTY(int maxCpuThreads READ maxCpuThreads CONSTANT)
    Q_PROPERTY(QString estimate READ estimate NOTIFY configChanged)

    // run state
    Q_PROPERTY(bool running READ running NOTIFY runStateChanged)
    Q_PROPERTY(bool hasRun READ hasRun NOTIFY runStateChanged)
    Q_PROPERTY(QString runDevice READ runDevice NOTIFY runStateChanged)
    Q_PROPERTY(double progress READ progress NOTIFY statsChanged)
    Q_PROPERTY(double simTime READ simTime NOTIFY statsChanged)
    Q_PROPERTY(double msPerStep READ msPerStep NOTIFY statsChanged)
    Q_PROPERTY(int particleCount READ particleCount NOTIFY statsChanged)
    Q_PROPERTY(bool refinementExhausted READ refinementExhausted NOTIFY statsChanged)
    Q_PROPERTY(int memoryMB READ memoryMB NOTIFY statsChanged)

    // the frame being shown (live or playback)
    Q_PROPERTY(int frameCount READ frameCount NOTIFY framesChanged)
    Q_PROPERTY(int frameIndex READ frameIndex WRITE setFrameIndex NOTIFY frameChanged)
    Q_PROPERTY(bool live READ live NOTIFY frameChanged)
    Q_PROPERTY(double frameTime READ frameTime NOTIFY frameChanged)
    Q_PROPERTY(QString phase READ phase NOTIFY frameChanged)
    Q_PROPERTY(QString phaseText READ phaseText NOTIFY frameChanged)
    Q_PROPERTY(double tipSpeed READ tipSpeed NOTIFY frameChanged)
    Q_PROPERTY(double tipTravel READ tipTravel NOTIFY frameChanged)
    Q_PROPERTY(double penetration READ penetration NOTIFY frameChanged)
    Q_PROPERTY(bool playing READ playing WRITE setPlaying NOTIFY playingChanged)
    Q_PROPERTY(bool loop MEMBER m_loop NOTIFY playingChanged)
    Q_PROPERTY(double playbackFps READ playbackFps WRITE setPlaybackFps NOTIFY playingChanged)

    // charts
    Q_PROPERTY(QVariantList jetSamples READ jetSamples NOTIFY chartsChanged)
    Q_PROPERTY(QVariantList curve READ curve NOTIFY chartsChanged)
    Q_PROPERTY(QPointF optimum READ optimum NOTIFY chartsChanged)
    Q_PROPERTY(QVariantList results READ results NOTIFY chartsChanged)
    Q_PROPERTY(double standoff READ standoff NOTIFY configChanged)
    Q_PROPERTY(double approachSpeed READ approachSpeed NOTIFY configChanged)
    Q_PROPERTY(QVariantList optimumVsSpeed READ optimumVsSpeed NOTIFY chartsChanged)   // (m/s, best standoff CD)
    Q_PROPERTY(QPointF bestNow READ bestNow NOTIFY chartsChanged)                      // at the current approach speed
    Q_PROPERTY(QString bestSummary READ bestSummary NOTIFY chartsChanged)
    Q_PROPERTY(QString jetSummary READ jetSummary NOTIFY chartsChanged)

public:
    explicit SimController(QObject* parent = nullptr);
    ~SimController() override;

    QVariantList params() const;
    int liner() const { return int(m_cfg.liner); }
    int target() const { return int(m_cfg.target); }
    void setLiner(int v);
    void setTarget(int v);
    QStringList devices() const;
    int deviceIndex() const { return m_deviceIndex; }
    void setDeviceIndex(int i);
    bool deviceIsCpu() const;
    int cpuThreads() const { return m_cpuThreads; }
    void setCpuThreads(int t);
    int maxCpuThreads() const;
    QString estimate() const;

    bool running() const { return m_run && m_run->running(); }
    bool hasRun() const { return bool(m_run); }
    QString runDevice() const;
    double progress() const { return m_progress; }
    double simTime() const { return m_stats.time; }
    double msPerStep() const { return m_stats.msPerStep; }
    int particleCount() const { return m_stats.particles; }
    bool refinementExhausted() const { return m_stats.refinementExhausted; }
    int memoryMB() const;

    int frameCount() const { return m_frameCount; }
    int frameIndex() const { return m_frameIndex; }
    void setFrameIndex(int i);
    bool live() const { return m_live; }
    double frameTime() const { return m_frameStats.time; }
    QString phase() const;
    QString phaseText() const;
    double tipSpeed() const { return m_frameStats.tipSpeed; }
    double tipTravel() const { return std::max(0.0f, m_frameStats.tipTravel); }
    double penetration() const { return m_frameStats.penetration; }
    bool playing() const { return m_playing; }
    void setPlaying(bool p);
    double playbackFps() const { return m_fps; }
    void setPlaybackFps(double f);

    QVariantList jetSamples() const { return m_jetSamples; }
    QVariantList curve() const { return m_curve; }
    QPointF optimum() const { return m_optimum; }
    QVariantList results() const { return m_results; }
    double standoff() const { return m_cfg.standoffCD; }
    double approachSpeed() const { return m_cfg.approachSpeed; }
    QVariantList optimumVsSpeed() const { return m_optimumVsSpeed; }
    QPointF bestNow() const { return m_bestNow; }
    QString bestSummary() const { return m_bestSummary; }
    QString jetSummary() const;

    Q_INVOKABLE void setParam(const QString& key, double value);
    Q_INVOKABLE void resetParams();
    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void stepFrame(int delta);
    /// Memory for recorded frames (older frames are thinned beyond it); default 3 GB.
    void setFrameMemoryBudget(size_t bytes) { m_frameBudget = bytes; }

    /// Latest frame for the renderer (thread-safe; returns the same pointer until the frame changes).
    std::shared_ptr<const ViewFrame> viewFrame() const;

signals:
    void paramsChanged();
    void configChanged();
    void deviceChanged();
    void runStateChanged();
    void statsChanged();
    void framesChanged();
    void frameChanged();
    void playingChanged();
    void chartsChanged();
    void viewFrameChanged();

private:
    void refreshPreview();
    void showFrame(int index);
    void poll();
    void updateCurve();
    double paramValue(const QString& key) const;

    scl::Config m_cfg;
    float m_driftSpeed = 20;     // m/s, 1D model only
    std::vector<scl::Device> m_devices;
    int m_deviceIndex = 0;
    int m_cpuThreads = 1;
    size_t m_frameBudget = size_t(3) << 30;
    int m_runGeneration = 0;   // identifies the current run to its queued callbacks

    std::unique_ptr<scl::Run> m_run;
    scl::Config m_runCfg;
    scl::Stats m_stats{};
    double m_progress = 0;
    int m_frameCount = 0;
    int m_frameIndex = 0;
    bool m_live = true;
    scl::Stats m_frameStats{};
    bool m_playing = false;
    bool m_loop = true;
    double m_fps = 30;
    QTimer m_poll, m_playTimer;

    bool m_haveJet = false;
    scl::JetProfile m_jet{};
    float m_jetApproach = 0;   // approach speed the jet was measured at (m/s); the charts shift it to the current one
    QVariantList m_jetSamples, m_curve, m_results, m_optimumVsSpeed;
    QPointF m_optimum{-1, -1}, m_bestNow{-1, -1};
    QString m_bestSummary;

    mutable std::mutex m_frameMutex;
    std::shared_ptr<const ViewFrame> m_viewFrame;
};
