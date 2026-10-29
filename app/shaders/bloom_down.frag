#version 440
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform P { vec4 flags; vec4 extra; };
layout(binding = 1) uniform sampler2D src;
void main() {
    vec2 ts = 1.0 / vec2(textureSize(src, 0));
    vec3 col = texture(src, vUv).rgb * 0.5;
    col += (texture(src, vUv + ts * vec2(-1, -1)).rgb + texture(src, vUv + ts * vec2(1, -1)).rgb
          + texture(src, vUv + ts * vec2(-1, 1)).rgb + texture(src, vUv + ts * vec2(1, 1)).rgb) * 0.125;
    fragColor = vec4(col, 1.0);
}
