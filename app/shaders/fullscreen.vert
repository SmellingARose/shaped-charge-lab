#version 440
// One triangle covering the screen; uv follows the backend's texture origin.
layout(std140, binding = 0) uniform P { vec4 flags; vec4 extra; };
layout(location = 0) out vec2 vUv;
void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
    vUv = vec2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    if (flags.y > 0.5) vUv.y = 1.0 - vUv.y;
    gl_Position = vec4(p.x, p.y * flags.x, 0.0, 1.0);
}
