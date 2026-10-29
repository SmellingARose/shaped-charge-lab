find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 ShaderTools)
# QRhi headers: a separate GuiPrivate package from Qt 6.9, part of Qt6Gui before that
find_package(Qt6 QUIET COMPONENTS GuiPrivate)
qt_standard_project_setup(REQUIRES 6.8)

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
target_link_libraries(ShapedChargeLab PRIVATE scl_core Qt6::Quick Qt6::QuickControls2 Qt6::GuiPrivate)  # GuiPrivate: QRhi headers
target_compile_definitions(ShapedChargeLab PRIVATE SCL_VERSION="${PROJECT_VERSION}")

# ---- self-contained deployment (used by packaging/ and CI)
get_target_property(_qmake Qt6::qmake IMPORTED_LOCATION)
get_filename_component(_qtbin ${_qmake} DIRECTORY)
if(WIN32)
  find_program(SCL_WINDEPLOYQT windeployqt HINTS ${_qtbin})
  if(SCL_WINDEPLOYQT)
    # deploy/ holds the exe, the Qt runtime and the MSVC runtime DLLs next to it (so no VC++ Redistributable is needed)
    set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
    include(InstallRequiredSystemLibraries)
    if(MSVC AND NOT CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
      message(WARNING "MSVC runtime DLLs not found: the deploy folder will need the VC++ Redistributable installed")
    endif()
    set(_dep ${CMAKE_BINARY_DIR}/deploy)
    add_custom_target(scl_deploy
      COMMAND ${CMAKE_COMMAND} -E rm -rf ${_dep}
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dep}
      COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:ShapedChargeLab> $<TARGET_FILE:scl_smoke> ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS} ${_dep}/
      COMMAND ${SCL_WINDEPLOYQT} --qmldir ${CMAKE_CURRENT_SOURCE_DIR}/qml --no-translations --no-compiler-runtime "${_dep}/$<TARGET_FILE_NAME:ShapedChargeLab>"
      DEPENDS ShapedChargeLab scl_smoke VERBATIM)
  endif()
elseif(APPLE)
  find_program(SCL_MACDEPLOYQT macdeployqt HINTS ${_qtbin})
endif()
