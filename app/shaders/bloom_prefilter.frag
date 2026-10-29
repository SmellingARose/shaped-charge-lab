#version 440
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform P { vec4 flags; vec4 extra; };
layout(binding = 1) uniform sampler2D src;
void main() {
    vec2 ts = 1.0 / vec2(textureSize(src, 0));
    vec3 col = (texture(src, vUv + ts * vec2(-1, -1)).rgb + texture(src, vUv + ts * vec2(1, -1)).rgb
              + texture(src, vUv + ts * vec2(-1, 1)).rgb + texture(src, vUv + ts * vec2(1, 1)).rgb) * 0.25;
    float br = max(col.r, max(col.g, col.b));
    float knee = 0.6, thr = 2.2;
    float soft = clamp(br - thr + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    fragColor = vec4(col * (max(soft, br - thr) / max(br, 1e-4)), 1.0);
}
