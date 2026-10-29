#version 440
// Sphere impostor for every solid particle (explosive, liner, target). Gas is drawn by gas.vert.
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
layout(location = 0) out vec3 vCenter;
layout(location = 1) out float vRadius;
layout(location = 2) out vec2 vUv;
layout(location = 3) flat out vec4 vAlb;   // rgb, emissive
layout(location = 4) flat out vec4 vPar;   // metal, roughness, on the cut face, -
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
    uint mat = imat & 255u;
    uint fl = imat >> 8;
    int vis = int(b.w);
    bool hide = (fl & 1u) == 0u || (fl & 2u) != 0u
        || (mat == 0u && (vis & 1) == 0) || (mat == 2u && (vis & 2) == 0);
    float s = a.w;
    float dp = ((fl & 8u) != 0u ? e.x : d.w);
    float rad = 0.62 * dp * pow(0.7937005, float((fl >> 4) & 7u)) * s;
    // cutaway wedge facing the camera (particles near the axis stay)
    float r = length(ipos.yz);
    float th = atan(ipos.z, ipos.y);
    float dth = abs(mod(th - b.x + 9.42477796, 6.28318531) - 3.14159265);
    if (dth < b.y && r > 0.6 * d.w * s) hide = true;
    if (hide) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }

    float speed = float(ifields & 255u) / 255.0 * 10.0;
    float temp = 300.0 + float((ifields >> 8) & 255u) / 255.0 * 4000.0;
    float pres = exp2(float((ifields >> 16) & 255u) / 255.0 * log2(201.0)) - 1.0;
    float strain = float(ifields >> 24) / 255.0 * 4.0;
    bool damaged = (fl & 4u) != 0u;
    vec3 alb; float metal = 0.0; float rough = 0.6; float emis = 0.0;
    if (mat == 0u) { alb = vec3(0.46, 0.43, 0.33); rough = 0.8; }
    else if (mat == 1u) {
        alb = e.y < 0.5 ? vec3(0.96, 0.58, 0.40) : (e.y < 1.5 ? vec3(0.60, 0.62, 0.70) : vec3(0.88, 0.89, 0.91));
        metal = 1.0; rough = 0.24;
    } else {
        alb = e.z < 0.5 ? vec3(0.50, 0.52, 0.55) : vec3(0.82, 0.84, 0.87);
        metal = 1.0; rough = 0.42;
    }
    if (damaged) { rough = min(rough + 0.25, 1.0); alb *= 0.82; }
    int mode = int(c.x);
    if (mode == 1) { alb = turbo(speed / f.x); metal = 0.15; rough = 0.45; }
    else if (mode == 2) { alb = turbo(log2(1.0 + max(pres, 0.0)) / log2(1.0 + f.y)); metal = 0.15; rough = 0.45; }
    else if (mode == 3) { alb = turbo((temp - 300.0) / 1300.0); metal = 0.15; rough = 0.45; }
    else if (mode == 4) { alb = turbo(strain / f.z); metal = 0.15; rough = 0.45; }
    if (mat != 0u) { float g = clamp((temp - 1000.0) / 1200.0, 0.0, 1.0); emis = g * g * 0.35; }
    bool onCut = abs(dth - b.y) < 1.5 * dp * s / max(r, dp * s);

    vAlb = vec4(clamp(alb, 0.0, 1.0), emis);
    vPar = vec4(metal, rough, onCut ? 1.0 : 0.0, 0.0);
    vec3 cv = (view * vec4(ipos, 1.0)).xyz;
    vCenter = cv;
    vRadius = rad;
    vUv = corner * 1.15;
    gl_Position = proj * vec4(cv + vec3(corner * rad * 1.15, rad), 1.0);
}
