#version 440
layout(location = 0) in vec3 vCenter;
layout(location = 1) in float vRadius;
layout(location = 2) in vec2 vUv;
layout(location = 3) flat in vec4 vAlb;
layout(location = 4) flat in vec4 vPar;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform U {
    mat4 view; mat4 proj; mat4 invView;
    vec4 a;   // viewport w, h, -, mm to world
    vec4 b;   // cut centre, cut half-angle, ground y, visibility bits (1 explosive, 2 target, 4 gas)
    vec4 c;   // colour mode, charge length, target face z, target back z (mm)
    vec4 d;   // charge radius, target radius, charge diameter, fine spacing (mm)
    vec4 e;   // coarse spacing, liner kind, target kind, jet tip world x
    vec4 f;   // speed max, pressure max, strain max, exposure
};
vec3 sky(vec3 dd) {
    vec3 top = vec3(0.42, 0.47, 0.56), hor = vec3(0.16, 0.17, 0.20), gnd = vec3(0.035, 0.036, 0.04);
    vec3 col = dd.y > 0.0 ? mix(hor, top, pow(clamp(dd.y, 0.0, 1.0), 0.6)) : mix(hor, gnd, pow(clamp(-dd.y, 0.0, 1.0), 0.35));
    col += vec3(3.2, 3.1, 2.9) * smoothstep(0.93, 0.985, dot(dd, normalize(vec3(-0.35, 0.85, 0.45))));
    col += vec3(1.2, 1.5, 2.0) * smoothstep(0.95, 0.995, dot(dd, normalize(vec3(0.85, 0.25, -0.45))));
    return col;
}
void main() {
    float d2 = dot(vUv, vUv);
    if (d2 > 1.0) discard;
    vec3 n0 = vec3(vUv, sqrt(1.0 - d2));
    vec3 pV = vCenter + n0 * vRadius;
    vec4 clip = proj * vec4(pV, 1.0);
    gl_FragDepth = clip.z / clip.w;
    vec3 n = vPar.z > 0.5 ? normalize(mix(n0, vec3(0, 0, 1), 0.55)) : n0;
    vec3 alb = vAlb.rgb;
    float metal = vPar.x, rough = max(vPar.y, 0.05);
    vec3 v = normalize(-pV);
    vec3 L = normalize((view * vec4(normalize(vec3(-0.35, 0.85, 0.45)), 0.0)).xyz);
    vec3 L2 = normalize((view * vec4(normalize(vec3(0.85, 0.25, -0.45)), 0.0)).xyz);
    vec3 nW = normalize((invView * vec4(n, 0.0)).xyz);
    vec3 R = normalize((invView * vec4(reflect(-v, n), 0.0)).xyz);
    vec3 F0 = mix(vec3(0.04), alb, metal);
    float NdV = max(dot(n, v), 1e-3);
    vec3 F = F0 + (1.0 - F0) * pow(1.0 - NdV, 5.0) * (1.0 - rough);
    float shin = mix(600.0, 10.0, rough);
    float spec = pow(max(dot(n, normalize(L + v)), 0.0), shin) * (shin + 8.0) / 40.0;
    float spec2 = pow(max(dot(n, normalize(L2 + v)), 0.0), shin) * (shin + 8.0) / 160.0;
    vec3 key = vec3(1.75, 1.68, 1.58), fill = vec3(0.40, 0.48, 0.62);
    vec3 diff = alb * (1.0 - metal) * (key * max(dot(n, L), 0.0) + fill * max(dot(n, L2), 0.0) + sky(nW) * 0.55);
    vec3 env = mix(sky(R), sky(normalize(nW + vec3(0, 0.5, 0))) * 0.8, rough * rough) * F;
    vec3 col = diff + (key * spec + fill * spec2) * F + env;
    col *= mix(0.65, 1.0, NdV);
    col += alb * vAlb.a * 4.0;
    fragColor = vec4(col, 1.0);
}
