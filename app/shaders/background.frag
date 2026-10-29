#version 440
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform P { vec4 flags; vec4 extra; };
void main() {
    float y = flags.y > 0.5 ? 1.0 - vUv.y : vUv.y;
    vec3 col = mix(vec3(0.075, 0.08, 0.095), vec3(0.018, 0.019, 0.024), y);
    col *= 1.0 - 0.45 * smoothstep(0.3, 0.95, length(vec2(vUv.x, y) - vec2(0.5, 0.42)));
    fragColor = vec4(col, 1.0);
}
