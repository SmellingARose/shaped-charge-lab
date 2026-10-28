// Shaped Charge Lab — simulation interface.
//
// This header is the contract between the simulation core (core/) and the cross-platform
// app (app/). The app only talks to the core through these types. Changing anything here
// is a coordinated change: update both sides in the same commit.
//
// Units everywhere: mm, µs, mg  →  km/s, g/cm³, GPa, MJ/kg.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace scl {

// ---------------------------------------------------------------- configuration

enum class Geometry { Conical, Linear };
enum class LinerMaterial { Copper, Tantalum, Aluminum };
enum class TargetMaterial { ArmorSteel, Aluminum6061 };

enum class Backend { Auto, CPU, Metal, HIP };

struct Asymmetry {
    float initiationOffsetMM = 0;   // detonator off the axis
    float wallVariation = 0;        // fraction; liner thicker on one side (cos θ)
};

struct Config {
    Geometry geometry = Geometry::Conical;
    float chargeDiameter = 40;      // mm (CD)
    float coneAngleDeg = 60;        // full apex angle
    float linerThicknessFrac = 0.025f;
    float headHeightCD = 0.5f;      // explosive behind the cone apex
    float standoffCD = 3;
    float targetThicknessCD = 4;
    float targetRadiusCD = 0.4f;
    LinerMaterial liner = LinerMaterial::Copper;
    TargetMaterial target = TargetMaterial::ArmorSteel;
    int layers = 2;                 // particles across the liner wall (resolution); explosive and target use 2× spacing
    int jetRefinement = 3;          // max split generations (compute budget)
    float breakupStretch = 6;       // jet elongation at which it particulates (λ)
    float detonationVelocity = 8;   // km/s
    float approachSpeed = 0;        // m/s, charge moving toward the target when it fires
    Asymmetry asymmetry;
};

/// One slider's physical range plus the band that corresponds to real hardware.
/// The UI draws `realisticLow..realisticHigh` as a band and `realistic` as a tick labelled "realistic".
struct ParameterRange {
    const char* key;                // matches the Config field name
    float min, max;
    float realisticLow, realisticHigh;
    float realistic;                // single most representative value
    const char* note;               // one line shown under the slider
};

/// All tunable parameters with their realistic bands. See core/src/ranges.cpp for sources.
const std::vector<ParameterRange>& parameterRanges();

// ---------------------------------------------------------------- devices

struct Device {
    Backend backend;
    std::string name;               // "Apple M4 GPU", "NVIDIA RTX 4090", "AMD Ryzen 9 7950X (32 threads)"
    int computeUnits = 0;           // GPU CUs/SMs, or CPU hardware threads
    int performanceCores = 0;       // CPU only; 0 when unknown
    uint64_t memoryBytes = 0;
};

/// Devices usable on this machine, fastest first. Always contains at least one CPU entry.
std::vector<Device> listDevices();

// ---------------------------------------------------------------- render data

/// 3D particle, quantised to 12 bytes so whole runs fit in memory.
struct Particle3D {
    uint16_t x, y, z;               // position within FrameInfo bounds, 0..65535
    uint8_t speed;                  // ×10/255 km/s
    uint8_t temperature;            // 300 + ×4000/255 K
    uint8_t pressure;               // log2(1+p)/log2(201)×255, GPa
    uint8_t plasticStrain;          // ×4/255
    uint8_t material;               // 0 explosive, 1 liner, 2 target
    uint8_t flags;                  // bit0 live, bit1 gas, bit2 damaged, bit3 coarse, bits4–6 split generation
};
static_assert(sizeof(Particle3D) == 12, "Particle3D must stay 12 bytes");

/// Geometry needed to place and size particles and draw the scene (charge, ground grid, standoff band).
struct SceneInfo {
    Geometry geometry;
    float chargeLength, chargeRadius, chargeDiameter;
    float zFace, zBack, targetRadius;   // target front/back face and radius, mm
    float boundsMin[3], boundsSpanXY, boundsSpanZ;  // Particle3D quantisation
    float spacingFine, spacingCoarse;   // mm, Particle3D display size (shrinks 2^(−1/3) per generation)
    LinerMaterial liner;
    TargetMaterial target;
};

// ---------------------------------------------------------------- stats & analysis

enum class Phase { Ready, Detonation, LinerCollapse, JetStretching, JetParticulating, Penetrating, Complete };

struct Stats {
    float time = 0;                 // µs
    Phase phase = Phase::Ready;
    float tipSpeed = 0;             // km/s
    float tipTravel = 0;            // mm past the charge face
    float penetration = 0;          // mm
    int fragments = 0;
    double msPerStep = 0;
    double stepsPerSecond = 0;
    int particles = 0, activeParticles = 0;
    bool done = false;
};

/// Measured jet as an ideal stretching rod (virtual origin z_vo, t_vo).
struct JetProfile {
    float vTip, vTail, zVirtualOrigin, tVirtualOrigin, tMeasured, jetMassFraction;
    float chargeLength, chargeDiameter, rhoJet;
};

struct CurvePoint { float standoffCD, penetrationCD; };

/// 1D modified-Bernoulli penetration of the measured jet versus standoff.
std::vector<CurvePoint> penetrationCurve(const JetProfile&, const Config&, float driftSpeedKmS, float maxCD = 10, float stepCD = 0.1f);

struct JetSample { float zFromFace, vz; bool isJet; };

// ---------------------------------------------------------------- simulation

/// Every run is a full 3D simulation (no symmetry assumed). It runs on a background thread and stores
/// frames as it goes: the app shows the newest frame while it runs ("live") and can scrub or play back
/// any recorded frame at any time, during or after the run.
struct Frame {
    float time;                     // µs
    Stats stats;
    std::vector<Particle3D> particles;
};

class Run {
public:
    virtual ~Run() = default;
    virtual void cancel() = 0;                       // stops; keeps frames so far
    virtual void setPaused(bool) = 0;
    virtual void setCpuThreads(int threads) = 0;     // CPU backend only
    virtual bool running() const = 0;
    virtual size_t frameCount() const = 0;
    virtual bool frame(size_t index, Frame& out) const = 0;
    virtual SceneInfo scene() const = 0;
    virtual Stats progress() const = 0;              // latest solver state
    virtual Device device() const = 0;
    virtual std::vector<JetSample> linerSamples(size_t maxCount) const = 0;  // latest frame
    virtual bool jetProfile(JetProfile& out) const = 0;                      // false until the jet has formed
};

struct RunOptions {
    Backend backend = Backend::Auto;
    const Device* device = nullptr;                  // nullptr = fastest for `backend`
    float frameIntervalUs = 0.5f;                    // simulated time between stored frames
    size_t memoryBudgetBytes = size_t(3) << 30;      // older frames are thinned when exceeded
};

/// Rough particle count and wall-clock estimate for the UI before starting.
struct RunEstimate { size_t particles; double minutes; };
RunEstimate estimateRun(const Config&, const Device&);

/// `onFrame` and `onDone` are called on the run's thread; marshal to the UI thread yourself.
std::unique_ptr<Run> startRun(const Config&, const RunOptions&,
                              std::function<void(size_t frameIndex)> onFrame,
                              std::function<void(float penetrationMM, bool completed)> onDone);

}  // namespace scl
