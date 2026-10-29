#include "ParticleView.h"

#include <QFile>
#include <QMatrix4x4>
#include <QMouseEvent>
#include <QWheelEvent>
#include <rhi/qrhi.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#include "SimController.h"

namespace {

constexpr float kMmToWorld = 0.02f;   // 1 world unit = 50 mm
constexpr int kBloomLevels = 5;

/// Per-instance data uploaded to the GPU: world position plus the packed fields of scl::Particle3D.
struct Instance {
    float x, y, z;
    uint32_t fields;   // speed | temperature << 8 | pressure << 16 | strain << 24
    uint32_t mat;      // material | flags << 8
};
static_assert(sizeof(Instance) == 20, "instance layout is shared with particle.vert / gas.vert");

/// std140 uniform block shared by the scene shaders.
struct SceneUniforms {
    float view[16], proj[16], invView[16];
    float a[4], b[4], c[4], d[4], e[4], f[4];
};

/// std140 uniform block for full-screen passes.
struct PassUniforms {
    float flags[4];   // ndc y sign, flip uv, bloom strength, exposure
    float extra[4];
};

QShader loadShader(const char* name) {
    QFile f(QStringLiteral(":/shaders/") + QLatin1String(name) + QStringLiteral(".qsb"));
    if (!f.open(QIODevice::ReadOnly)) {
        qWarning("missing shader %s", name);
        return {};
    }
    return QShader::fromSerialized(f.readAll());
}

}  // namespace

class ParticleRenderer : public QQuickRhiItemRenderer {
public:
    void initialize(QRhiCommandBuffer* cb) override;
    void synchronize(QQuickRhiItem* item) override;
    void render(QRhiCommandBuffer* cb) override;

private:
    void createTargets(QSize size);
    QRhiGraphicsPipeline* makePipeline(const char* vs, const char* fs, QRhiShaderResourceBindings* srb,
                                       QRhiRenderPassDescriptor* rp, bool instanced, int blend, bool depthTest,
                                       bool depthWrite, QRhiGraphicsPipeline::Topology topo);
    void decodeFrame(QRhiResourceUpdateBatch* u);

    QRhi* m_rhi = nullptr;
    std::unique_ptr<QRhiBuffer> m_quad, m_instances, m_sceneUbo, m_passUbo;
    std::unique_ptr<QRhiSampler> m_sampler;
    std::unique_ptr<QRhiTexture> m_hdr;
    std::unique_ptr<QRhiRenderBuffer> m_depth;
    std::unique_ptr<QRhiTextureRenderTarget> m_hdrRt;
    std::unique_ptr<QRhiRenderPassDescriptor> m_hdrRp;
    std::unique_ptr<QRhiTexture> m_bloom[kBloomLevels];
    std::unique_ptr<QRhiTextureRenderTarget> m_bloomRt[kBloomLevels];
    std::unique_ptr<QRhiRenderPassDescriptor> m_bloomRp;
    std::unique_ptr<QRhiShaderResourceBindings> m_sceneSrb, m_bgSrb, m_prefilterSrb, m_compositeSrb;
    std::unique_ptr<QRhiShaderResourceBindings> m_downSrb[kBloomLevels], m_upSrb[kBloomLevels];
    std::unique_ptr<QRhiGraphicsPipeline> m_bgPs, m_groundPs, m_spherePs, m_gasPs, m_prefilterPs, m_downPs, m_upPs, m_compositePs;
    QSize m_size;
    QRhiRenderPassDescriptor* m_itemRp = nullptr;

    // state copied from the item
    std::shared_ptr<const ViewFrame> m_frame, m_uploaded;
    ParticleView::Camera m_cam;
    int m_colorMode = 0;
    float m_cutaway = 90;
    bool m_showGas = true, m_showExplosive = true, m_showTarget = true, m_showGrid = true, m_bloomOn = true;
    int m_instanceCount = 0;
    size_t m_instanceCapacity = 0;
    std::vector<Instance> m_staging;
    bool m_quadUploaded = false;
};

// ---------------------------------------------------------------- item

ParticleView::ParticleView(QQuickItem* parent) : QQuickRhiItem(parent) {
    setAcceptedMouseButtons(Qt::AllButtons);
    setFlag(ItemAcceptsInputMethod, false);
    connect(this, &ParticleView::viewChanged, this, &QQuickItem::update);
}

QQuickRhiItemRenderer* ParticleView::createRenderer() { return new ParticleRenderer; }

void ParticleView::setController(SimController* c) {
    if (m_controller == c) return;
    if (m_controller) disconnect(m_controller, nullptr, this, nullptr);
    m_controller = c;
    if (c) {
        connect(c, &SimController::viewFrameChanged, this, &QQuickItem::update);
        connect(c, &SimController::configChanged, this, [this] { if (!m_cam.userMoved) m_resetRequested = true; update(); });
    }
    emit controllerChanged();
    update();
}

void ParticleView::resetCamera() {
    m_cam = Camera{};
    m_resetRequested = true;
    update();
}

void ParticleView::mousePressEvent(QMouseEvent* e) {
    m_lastPos = e->position();
    m_button = e->button();
    e->accept();
}

void ParticleView::mouseMoveEvent(QMouseEvent* e) {
    const QPointF d = e->position() - m_lastPos;
    m_lastPos = e->position();
    m_cam.userMoved = true;
    const bool pan = m_button == Qt::RightButton || m_button == Qt::MiddleButton || (e->modifiers() & Qt::ShiftModifier);
    if (pan) {
        const float k = m_cam.distance * 0.0016f;
        const QVector3D right(std::cos(m_cam.yaw), 0, -std::sin(m_cam.yaw));
        m_cam.target -= right * float(d.x()) * k;
        m_cam.target.setY(m_cam.target.y() + float(d.y()) * k);
    } else {
        m_cam.yaw -= float(d.x()) * 0.006f;
        m_cam.pitch = std::clamp(m_cam.pitch + float(d.y()) * 0.006f, -1.45f, 1.45f);
    }
    update();
    e->accept();
}

void ParticleView::mouseReleaseEvent(QMouseEvent* e) {
    m_button = Qt::NoButton;
    e->accept();
}

void ParticleView::wheelEvent(QWheelEvent* e) {
    m_cam.userMoved = true;
    const QPoint px = e->pixelDelta();
    if (!px.isNull() && !(e->modifiers() & Qt::ControlModifier)) {
        // trackpad: two-finger drag orbits, pinch arrives as ctrl+wheel on macOS
        m_cam.yaw -= float(px.x()) * 0.004f;
        m_cam.pitch = std::clamp(m_cam.pitch + float(px.y()) * 0.004f, -1.45f, 1.45f);
    } else {
        const float steps = float(e->angleDelta().y()) / 120.0f;
        m_cam.distance = std::clamp(m_cam.distance * std::pow(0.88f, steps), 0.3f, 80.0f);
    }
    update();
    e->accept();
}

// ---------------------------------------------------------------- renderer

void ParticleRenderer::synchronize(QQuickRhiItem* item) {
    auto* v = static_cast<ParticleView*>(item);
    if (v->m_controller) m_frame = v->m_controller->viewFrame();
    if (m_frame && v->m_resetRequested) {
        // frame the charge and the standoff gap
        const scl::SceneInfo& s = m_frame->scene;
        const float left = -s.chargeLength * kMmToWorld;
        const float right = (s.zFace - s.chargeLength) * kMmToWorld + 0.6f * s.chargeDiameter * kMmToWorld;
        v->m_cam.target = QVector3D((left + right) / 2, -0.1f * s.chargeDiameter * kMmToWorld, 0);
        if (!v->m_cam.userMoved) {
            // fit the charge-to-target span horizontally, whatever the view's aspect ratio
            const float aspect = float(std::max(v->width(), 1.0) / std::max(v->height(), 1.0));
            const float vfov = 34.0f * float(M_PI) / 180.0f;
            const float hfov = 2 * std::atan(std::tan(vfov / 2) * aspect);
            v->m_cam.distance = std::max((right - left) * 0.5f / std::tan(hfov / 2) * 1.35f, 2.5f);
        }
        v->m_resetRequested = false;
    }
    if (v->m_follow && m_frame) {
        const float tipX = m_frame->tipTravel * kMmToWorld;
        v->m_cam.target.setX(v->m_cam.target.x() + (tipX - v->m_cam.target.x()) * 0.15f);
        v->update();
    }
    m_cam = v->m_cam;
    m_colorMode = v->m_colorMode;
    m_cutaway = float(v->m_cutaway);
    m_showGas = v->m_showGas;
    m_showExplosive = v->m_showExplosive;
    m_showTarget = v->m_showTarget;
    m_showGrid = v->m_showGrid;
    m_bloomOn = v->m_bloom;
}

void ParticleRenderer::initialize(QRhiCommandBuffer*) {
    if (m_rhi != rhi()) {
        m_rhi = rhi();
        m_size = QSize();
        m_quad.reset();
        m_instances.reset();
        m_instanceCapacity = 0;
        m_uploaded.reset();
    }
    if (!m_quad) {
        m_quad.reset(m_rhi->newBuffer(QRhiBuffer::Immutable, QRhiBuffer::VertexBuffer, 8 * sizeof(float)));
        m_quad->create();
        m_quadUploaded = false;
        m_sceneUbo.reset(m_rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(SceneUniforms)));
        m_sceneUbo->create();
        m_passUbo.reset(m_rhi->newBuffer(QRhiBuffer::Dynamic, QRhiBuffer::UniformBuffer, sizeof(PassUniforms)));
        m_passUbo->create();
        m_sampler.reset(m_rhi->newSampler(QRhiSampler::Linear, QRhiSampler::Linear, QRhiSampler::None,
                                          QRhiSampler::ClampToEdge, QRhiSampler::ClampToEdge));
        m_sampler->create();
    }
    const QSize sz = renderTarget()->pixelSize();
    if (sz != m_size || m_itemRp != renderTarget()->renderPassDescriptor()) createTargets(sz);
}

QRhiGraphicsPipeline* ParticleRenderer::makePipeline(const char* vs, const char* fs, QRhiShaderResourceBindings* srb,
                                                     QRhiRenderPassDescriptor* rp, bool instanced, int blend,
                                                     bool depthTest, bool depthWrite,
                                                     QRhiGraphicsPipeline::Topology topo) {
    QRhiGraphicsPipeline* ps = m_rhi->newGraphicsPipeline();
    ps->setShaderStages({{QRhiShaderStage::Vertex, loadShader(vs)}, {QRhiShaderStage::Fragment, loadShader(fs)}});
    QRhiVertexInputLayout layout;
    if (instanced) {
        layout.setBindings({{2 * sizeof(float)}, {sizeof(Instance), QRhiVertexInputBinding::PerInstance}});
        layout.setAttributes({{0, 0, QRhiVertexInputAttribute::Float2, 0},
                              {1, 1, QRhiVertexInputAttribute::Float3, 0},
                              {1, 2, QRhiVertexInputAttribute::UInt, 12},
                              {1, 3, QRhiVertexInputAttribute::UInt, 16}});
    }
    ps->setVertexInputLayout(layout);
    ps->setShaderResourceBindings(srb);
    ps->setRenderPassDescriptor(rp);
    ps->setTopology(topo);
    ps->setDepthTest(depthTest);
    ps->setDepthWrite(depthWrite);
    ps->setDepthOp(QRhiGraphicsPipeline::Less);
    if (blend) {
        QRhiGraphicsPipeline::TargetBlend tb;
        tb.enable = true;
        tb.srcColor = QRhiGraphicsPipeline::One;
        tb.dstColor = QRhiGraphicsPipeline::One;
        tb.srcAlpha = QRhiGraphicsPipeline::One;
        tb.dstAlpha = QRhiGraphicsPipeline::One;
        ps->setTargetBlends({tb});
    }
    ps->create();
    return ps;
}

void ParticleRenderer::createTargets(QSize sz) {
    m_size = sz;
    m_itemRp = renderTarget()->renderPassDescriptor();
    // HDR scene target with depth
    m_hdr.reset(m_rhi->newTexture(QRhiTexture::RGBA16F, sz, 1, QRhiTexture::RenderTarget));
    m_hdr->create();
    m_depth.reset(m_rhi->newRenderBuffer(QRhiRenderBuffer::DepthStencil, sz));
    m_depth->create();
    {
        QRhiTextureRenderTargetDescription desc{QRhiColorAttachment(m_hdr.get())};
        desc.setDepthStencilBuffer(m_depth.get());
        m_hdrRt.reset(m_rhi->newTextureRenderTarget(desc));
        m_hdrRp.reset(m_hdrRt->newCompatibleRenderPassDescriptor());
        m_hdrRt->setRenderPassDescriptor(m_hdrRp.get());
        m_hdrRt->create();
    }
    // bloom mip chain
    for (int k = 0; k < kBloomLevels; k++) {
        const QSize bs(std::max(sz.width() >> (k + 1), 2), std::max(sz.height() >> (k + 1), 2));
        m_bloom[k].reset(m_rhi->newTexture(QRhiTexture::RGBA16F, bs, 1, QRhiTexture::RenderTarget));
        m_bloom[k]->create();
        m_bloomRt[k].reset(m_rhi->newTextureRenderTarget({QRhiColorAttachment(m_bloom[k].get())},
                                                         QRhiTextureRenderTarget::PreserveColorContents));
        if (k == 0) m_bloomRp.reset(m_bloomRt[0]->newCompatibleRenderPassDescriptor());
        m_bloomRt[k]->setRenderPassDescriptor(m_bloomRp.get());
        m_bloomRt[k]->create();
    }
    // resource bindings
    const auto vf = QRhiShaderResourceBinding::VertexStage | QRhiShaderResourceBinding::FragmentStage;
    auto passSrb = [&](QRhiTexture* t) {
        QRhiShaderResourceBindings* b = m_rhi->newShaderResourceBindings();
        b->setBindings({QRhiShaderResourceBinding::uniformBuffer(0, vf, m_passUbo.get()),
                        QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage, t, m_sampler.get())});
        b->create();
        return b;
    };
    m_sceneSrb.reset(m_rhi->newShaderResourceBindings());
    m_sceneSrb->setBindings({QRhiShaderResourceBinding::uniformBuffer(0, vf, m_sceneUbo.get())});
    m_sceneSrb->create();
    m_bgSrb.reset(m_rhi->newShaderResourceBindings());
    m_bgSrb->setBindings({QRhiShaderResourceBinding::uniformBuffer(0, vf, m_passUbo.get())});
    m_bgSrb->create();
    m_prefilterSrb.reset(passSrb(m_hdr.get()));
    for (int k = 1; k < kBloomLevels; k++) m_downSrb[k].reset(passSrb(m_bloom[k - 1].get()));
    for (int k = 0; k < kBloomLevels - 1; k++) m_upSrb[k].reset(passSrb(m_bloom[k + 1].get()));
    m_compositeSrb.reset(m_rhi->newShaderResourceBindings());
    m_compositeSrb->setBindings({QRhiShaderResourceBinding::uniformBuffer(0, vf, m_passUbo.get()),
                                 QRhiShaderResourceBinding::sampledTexture(1, QRhiShaderResourceBinding::FragmentStage, m_hdr.get(), m_sampler.get()),
                                 QRhiShaderResourceBinding::sampledTexture(2, QRhiShaderResourceBinding::FragmentStage, m_bloom[0].get(), m_sampler.get())});
    m_compositeSrb->create();
    // pipelines
    using T = QRhiGraphicsPipeline;
    m_bgPs.reset(makePipeline("fullscreen.vert", "background.frag", m_bgSrb.get(), m_hdrRp.get(), false, 0, false, false, T::Triangles));
    m_groundPs.reset(makePipeline("ground.vert", "ground.frag", m_sceneSrb.get(), m_hdrRp.get(), false, 0, true, true, T::TriangleStrip));
    m_spherePs.reset(makePipeline("particle.vert", "particle.frag", m_sceneSrb.get(), m_hdrRp.get(), true, 0, true, true, T::TriangleStrip));
    m_gasPs.reset(makePipeline("gas.vert", "gas.frag", m_sceneSrb.get(), m_hdrRp.get(), true, 1, true, false, T::TriangleStrip));
    m_prefilterPs.reset(makePipeline("fullscreen.vert", "bloom_prefilter.frag", m_prefilterSrb.get(), m_bloomRp.get(), false, 0, false, false, T::Triangles));
    m_downPs.reset(makePipeline("fullscreen.vert", "bloom_down.frag", m_prefilterSrb.get(), m_bloomRp.get(), false, 0, false, false, T::Triangles));
    m_upPs.reset(makePipeline("fullscreen.vert", "bloom_up.frag", m_prefilterSrb.get(), m_bloomRp.get(), false, 1, false, false, T::Triangles));
    m_compositePs.reset(makePipeline("fullscreen.vert", "composite.frag", m_compositeSrb.get(), m_itemRp, false, 0, false, false, T::Triangles));
}

void ParticleRenderer::decodeFrame(QRhiResourceUpdateBatch* u) {
    if (!m_frame || m_frame == m_uploaded) return;
    m_uploaded = m_frame;
    const scl::SceneInfo& sc = m_frame->scene;
    const auto& src = m_frame->particles;
    m_staging.resize(src.size());
    const float sx = sc.boundsSpanXY / 65535.0f, sz = sc.boundsSpanZ / 65535.0f;
    for (size_t i = 0; i < src.size(); i++) {
        const scl::Particle3D& p = src[i];
        Instance& o = m_staging[i];
        const float x = sc.boundsMin[0] + float(p.x) * sx;
        const float y = sc.boundsMin[1] + float(p.y) * sx;
        const float z = sc.boundsMin[2] + float(p.z) * sz;
        // world: axis of the charge along +x, the charge face at the origin
        o.x = (z - sc.chargeLength) * kMmToWorld;
        o.y = x * kMmToWorld;
        o.z = y * kMmToWorld;
        o.fields = uint32_t(p.speed) | uint32_t(p.temperature) << 8 | uint32_t(p.pressure) << 16 | uint32_t(p.plasticStrain) << 24;
        o.mat = uint32_t(p.material) | uint32_t(p.flags) << 8;
    }
    const size_t bytes = std::max<size_t>(m_staging.size(), 1) * sizeof(Instance);
    if (!m_instances || m_instanceCapacity < bytes) {
        m_instanceCapacity = bytes + bytes / 4;
        m_instances.reset(m_rhi->newBuffer(QRhiBuffer::Static, QRhiBuffer::VertexBuffer, quint32(m_instanceCapacity)));
        m_instances->create();
    }
    if (!m_staging.empty()) u->uploadStaticBuffer(m_instances.get(), 0, quint32(m_staging.size() * sizeof(Instance)), m_staging.data());
    m_instanceCount = int(m_staging.size());
}

void ParticleRenderer::render(QRhiCommandBuffer* cb) {
    QRhiResourceUpdateBatch* u = m_rhi->nextResourceUpdateBatch();
    if (!m_quadUploaded) {
        static const float corners[] = {-1, -1, 1, -1, -1, 1, 1, 1};
        u->uploadStaticBuffer(m_quad.get(), corners);
        m_quadUploaded = true;
    }
    decodeFrame(u);

    // camera
    const QVector3D eye = m_cam.target + m_cam.distance * QVector3D(std::cos(m_cam.pitch) * std::sin(m_cam.yaw),
                                                                     std::sin(m_cam.pitch),
                                                                     std::cos(m_cam.pitch) * std::cos(m_cam.yaw));
    QMatrix4x4 view;
    view.lookAt(eye, m_cam.target, QVector3D(0, 1, 0));
    QMatrix4x4 proj = m_rhi->clipSpaceCorrMatrix();
    proj.perspective(34.0f, float(m_size.width()) / float(std::max(m_size.height(), 1)), 0.02f, 300.0f);
    const QMatrix4x4 invView = view.inverted();
    const QVector3D dir = eye - m_cam.target;

    SceneUniforms su{};
    std::memcpy(su.view, view.constData(), 64);
    std::memcpy(su.proj, proj.constData(), 64);
    std::memcpy(su.invView, invView.constData(), 64);
    scl::SceneInfo sc{};
    if (m_frame) sc = m_frame->scene;
    const float cutHalf = m_cutaway * float(M_PI) / 360.0f;
    const float groundY = -std::max(sc.chargeRadius, sc.targetRadius) * 1.7f * kMmToWorld;
    const int vis = (m_showExplosive ? 1 : 0) | (m_showTarget ? 2 : 0) | (m_showGas ? 4 : 0);
    const float a[4] = {float(m_size.width()), float(m_size.height()), 0, kMmToWorld};
    const float b[4] = {std::atan2(dir.z(), dir.y()), cutHalf, groundY, float(vis)};
    const float c[4] = {float(m_colorMode), sc.chargeLength, sc.zFace, sc.zBack};
    const float d[4] = {sc.chargeRadius, sc.targetRadius, sc.chargeDiameter, sc.spacingFine};
    const float e[4] = {sc.spacingCoarse, float(int(sc.liner)), float(int(sc.target)), m_frame ? m_frame->tipTravel * kMmToWorld : 0};
    const float f[4] = {8.5f, 60.0f, 3.0f, 1.0f};
    std::memcpy(su.a, a, 16); std::memcpy(su.b, b, 16); std::memcpy(su.c, c, 16);
    std::memcpy(su.d, d, 16); std::memcpy(su.e, e, 16); std::memcpy(su.f, f, 16);
    u->updateDynamicBuffer(m_sceneUbo.get(), 0, sizeof(su), &su);

    PassUniforms pu{};
    pu.flags[0] = m_rhi->isYUpInNDC() ? 1.0f : -1.0f;
    pu.flags[1] = m_rhi->isYUpInFramebuffer() ? 1.0f : 0.0f;
    pu.flags[2] = m_bloomOn ? 0.45f : 0.0f;
    pu.flags[3] = 1.0f;
    u->updateDynamicBuffer(m_passUbo.get(), 0, sizeof(pu), &pu);

    // scene into HDR
    cb->beginPass(m_hdrRt.get(), QColor(0, 0, 0), {1.0f, 0}, u);
    const QRhiViewport vp(0, 0, float(m_size.width()), float(m_size.height()));
    cb->setGraphicsPipeline(m_bgPs.get());
    cb->setViewport(vp);
    cb->setShaderResources();
    cb->draw(3);
    if (m_showGrid) {
        cb->setGraphicsPipeline(m_groundPs.get());
        cb->setViewport(vp);
        cb->setShaderResources();
        cb->draw(4);
    }
    if (m_instanceCount > 0 && m_instances) {
        const QRhiCommandBuffer::VertexInput vin[] = {{m_quad.get(), 0}, {m_instances.get(), 0}};
        cb->setGraphicsPipeline(m_spherePs.get());
        cb->setViewport(vp);
        cb->setShaderResources();
        cb->setVertexInput(0, 2, vin);
        cb->draw(4, quint32(m_instanceCount));
        if (m_showGas) {
            cb->setGraphicsPipeline(m_gasPs.get());
            cb->setViewport(vp);
            cb->setShaderResources();
            cb->setVertexInput(0, 2, vin);
            cb->draw(4, quint32(m_instanceCount));
        }
    }
    cb->endPass();

    // bloom: threshold, downsample chain, additive upsample
    auto pass = [&](QRhiTextureRenderTarget* rt, QRhiGraphicsPipeline* ps, QRhiShaderResourceBindings* srb, bool clear) {
        const QSize ps2 = rt->pixelSize();
        cb->beginPass(rt, QColor(0, 0, 0, 0), {1.0f, 0}, nullptr, clear ? QRhiCommandBuffer::BeginPassFlags() : QRhiCommandBuffer::BeginPassFlags());
        cb->setGraphicsPipeline(ps);
        cb->setViewport(QRhiViewport(0, 0, float(ps2.width()), float(ps2.height())));
        cb->setShaderResources(srb);
        cb->draw(3);
        cb->endPass();
    };
    if (m_bloomOn) {
        pass(m_bloomRt[0].get(), m_prefilterPs.get(), m_prefilterSrb.get(), true);
        for (int k = 1; k < kBloomLevels; k++) pass(m_bloomRt[k].get(), m_downPs.get(), m_downSrb[k].get(), true);
        for (int k = kBloomLevels - 2; k >= 0; k--) pass(m_bloomRt[k].get(), m_upPs.get(), m_upSrb[k].get(), false);
    }

    // tonemap into the item
    cb->beginPass(renderTarget(), QColor(0, 0, 0), {1.0f, 0});
    cb->setGraphicsPipeline(m_compositePs.get());
    cb->setViewport(QRhiViewport(0, 0, float(renderTarget()->pixelSize().width()), float(renderTarget()->pixelSize().height())));
    cb->setShaderResources();
    cb->draw(3);
    cb->endPass();
}
