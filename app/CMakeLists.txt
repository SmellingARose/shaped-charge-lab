find_package(Qt6 6.7 REQUIRED COMPONENTS Core Gui GuiPrivate Qml Quick QuickControls2 ShaderTools)
qt_standard_project_setup(REQUIRES 6.7)

qt_add_executable(ShapedChargeLab MACOSX_BUNDLE WIN32 src/main.cpp)
set_target_properties(ShapedChargeLab PROPERTIES
    OUTPUT_NAME "Shaped Charge Lab"
    MACOSX_BUNDLE_GUI_IDENTIFIER com.smellingarose.shapedchargelab
    MACOSX_BUNDLE_BUNDLE_NAME "Shaped Charge Lab"
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION})

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(ShapedChargeLab
    URI ShapedCharge
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/ParamSlider.qml
        qml/Section.qml
        qml/IconButton.qml
        qml/Segmented.qml
        qml/Hud.qml
        qml/Timeline.qml
        qml/Insights.qml
        qml/Icon.qml
        qml/Toggle.qml
    SOURCES
        src/SimController.h src/SimController.cpp
        src/ParticleView.h src/ParticleView.cpp
        src/PlotItem.h src/PlotItem.cpp
)

# Metal (macOS), HLSL (Direct3D 11/12), SPIR-V (Vulkan) and desktop/ES 3 GLSL; no GLSL ES 1.00.
qt_add_shaders(ShapedChargeLab "scl_shaders"
    GLSL "300es,330"
    HLSL 50
    MSL 12
    PREFIX "/shaders"
    BASE "shaders"
    FILES
        shaders/particle.vert shaders/particle.frag
        shaders/gas.vert shaders/gas.frag
        shaders/ground.vert shaders/ground.frag
        shaders/fullscreen.vert shaders/background.frag
        shaders/bloom_prefilter.frag shaders/bloom_down.frag shaders/bloom_up.frag shaders/composite.frag
)

target_include_directories(ShapedChargeLab PRIVATE src)
target_link_libraries(ShapedChargeLab PRIVATE scl_core Qt6::Quick Qt6::QuickControls2 Qt6::GuiPrivate)  # QRhi headers
target_compile_definitions(ShapedChargeLab PRIVATE SCL_VERSION="${PROJECT_VERSION}")
