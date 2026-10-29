#version 440
layout(std140, binding = 0) uniform U {
    mat4 view; mat4 proj; mat4 invView;
    vec4 a;   // viewport w, h, -, mm to world
    vec4 b;   // cut centre, cut half-angle, ground y, visibility bits (1 explosive, 2 target, 4 gas)
    vec4 c;   // colour mode, charge length, target face z, target back z (mm)
    vec4 d;   // charge radius, target radius, charge diameter, fine spacing (mm)
    vec4 e;   // coarse spacing, liner kind, target kind, jet tip world x
    vec4 f;   // speed max, pressure max, strain max, exposure
};
layout(location = 0) out vec3 vWorld;
void main() {
    vec2 cc = vec2((gl_VertexIndex & 1) != 0 ? 1.0 : -1.0, (gl_VertexIndex & 2) != 0 ? 1.0 : -1.0) * 40.0;
    vWorld = vec3(cc.x + e.w, b.z, cc.y);
    gl_Position = proj * view * vec4(vWorld, 1.0);
}
