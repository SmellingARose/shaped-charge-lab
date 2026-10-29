#version 440
layout(location = 0) in vec2 vUv;
layout(location = 1) in vec3 vCol;
layout(location = 2) in float vEmis;
layout(location = 0) out vec4 fragColor;
void main() {
    float d2 = dot(vUv, vUv);
    if (d2 > 1.0) discard;
    float k = exp(-d2 * 3.5) * (0.002 + 0.045 * vEmis * vEmis * vEmis);
    fragColor = vec4(vCol * k * 2.0, 0.0);
}
