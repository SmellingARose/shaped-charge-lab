#version 440
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform P { vec4 flags; vec4 extra; };
layout(binding = 1) uniform sampler2D hdr;
layout(binding = 2) uniform sampler2D bloomTex;
vec3 aces(vec3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }
void main() {
    vec3 col = texture(hdr, vUv).rgb + texture(bloomTex, vUv).rgb * flags.z;
    col = aces(col * 0.95 * flags.w);
    col *= 1.0 - 0.25 * smoothstep(0.45, 0.85, length(vUv - 0.5));
    fragColor = vec4(pow(col, vec3(1.0 / 2.2)), 1.0);
}
