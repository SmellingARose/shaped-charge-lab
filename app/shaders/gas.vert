#version 440
// Additive glow for burnt explosive products.
layout(location = 0) in vec2 corner;
layout(location = 1) in vec3 ipos;
layout(location = 2) in uint ifields;
layout(location = 3) in uint imat;
layout(std140, binding = 0) uniform U {
    mat4 view; mat4 proj; mat4 invView;
    vec4 a;   // viewport w, h, -, mm to world
    vec4 b;   // cut centre, cut half-angle, ground y, visibility bits (1 explosive, 2 target, 4 gas)
    vec4 c;   // colour mode, charge length, target face z, target back z (mm)
    vec4 d;   // charge radius, target radius, charge diameter, fine spacing (mm)
    vec4 e;   // coarse spacing, liner kind, target kind, jet tip world x
    vec4 f;   // speed max, pressure max, strain max, exposure
};
layout(location = 0) out vec2 vUv;
layout(location = 1) out vec3 vCol;
layout(location = 2) out float vEmis;
vec3 turbo(float t) {
    t = clamp(t, 0.0, 1.0);
    const vec4 kR = vec4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
    const vec4 kG = vec4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
    const vec4 kB = vec4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
    const vec2 kR2 = vec2(-152.94239396, 59.28637943);
    const vec2 kG2 = vec2(4.27729857, 2.82956604);
    const vec2 kB2 = vec2(-89.90310912, 27.34824973);
    vec4 v4 = vec4(1.0, t, t * t, t * t * t);
    vec2 v2 = v4.zw * v4.z;
    return vec3(dot(v4, kR) + dot(v2, kR2), dot(v4, kG) + dot(v2, kG2), dot(v4, kB) + dot(v2, kB2));
}
vec3 blackbody(float T) {
    float t = clamp((T - 800.0) / 2800.0, 0.0, 1.0);
    vec3 col = mix(vec3(1.0, 0.18, 0.02), vec3(1.0, 0.55, 0.15), smoothstep(0.0, 0.45, t));
    return mix(col, vec3(1.0, 0.93, 0.78), smoothstep(0.45, 1.0, t));
}
void main() {
    uint fl = imat >> 8;
    bool gas = (fl & 1u) != 0u && (fl & 2u) != 0u && (int(b.w) & 4) != 0;
    float s = a.w;
    float r = length(ipos.yz);
    float th = atan(ipos.z, ipos.y);
    float dth = abs(mod(th - b.x + 9.42477796, 6.28318531) - 3.14159265);
    if (!gas || (dth < b.y && r > 0.6 * d.w * s)) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
    float temp = 300.0 + float((ifields >> 8) & 255u) / 255.0 * 4000.0;
    float t = clamp((temp - 400.0) / 3400.0, 0.0, 1.0);
    vCol = blackbody(400.0 + t * 3400.0);
    vEmis = t * 0.55;
    vUv = corner;
    vec3 cv = (view * vec4(ipos, 1.0)).xyz;
    gl_Position = proj * vec4(cv + vec3(corner * 2.4 * e.x * s, 0.0), 1.0);
}
