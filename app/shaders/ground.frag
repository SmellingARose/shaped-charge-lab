#version 440
layout(location = 0) in vec3 vWorld;
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
void main() {
    float s = a.w, cd = d.z;
    float zmm = vWorld.x / s + c.y;        // axial position, mm from the back of the charge
    float lat = vWorld.z / s;              // lateral, mm
    vec3 base = vec3(0.050, 0.054, 0.064);
    vec2 g1 = vec2(zmm, lat) / 10.0;
    vec2 w1 = fwidth(g1);
    vec2 l1 = 1.0 - smoothstep(vec2(0.0), w1 * 1.2, abs(fract(g1 - 0.5) - 0.5));
    float minor = max(l1.x, l1.y) * 0.10;
    float fromFace = (zmm - c.y) / cd;     // charge diameters past the face
    float w2 = fwidth(fromFace);
    float major = (1.0 - smoothstep(0.0, w2 * 1.6, abs(fract(fromFace - 0.5) - 0.5))) * step(-0.01, fromFace);
    vec3 col = base + minor * vec3(0.30, 0.33, 0.38) + major * 0.22 * vec3(0.75, 0.80, 0.90);
    float inStand = step(c.y, zmm) * step(zmm, c.z);
    float band = inStand * (1.0 - smoothstep(0.0, 1.5, abs(lat) / (0.5 * cd)));
    col += band * vec3(0.16, 0.085, 0.02);
    float edge = inStand * (1.0 - smoothstep(0.0, fwidth(lat) * 2.0, abs(abs(lat) - 0.5 * cd)));
    col += edge * vec3(0.55, 0.30, 0.08);
    float chargeSpan = smoothstep(-2.0, 2.0, zmm) * (1.0 - smoothstep(c.y - 2.0, c.y + 2.0, zmm));
    float targetSpan = smoothstep(c.z - 2.0, c.z + 2.0, zmm) * (1.0 - smoothstep(c.w - 2.0, c.w + 2.0, zmm));
    float sh = chargeSpan * exp(-pow(lat / (d.x * 1.3), 2.0)) + targetSpan * exp(-pow(lat / (d.y * 1.3), 2.0));
    col *= 1.0 - 0.65 * clamp(sh, 0.0, 1.0);
    float dist = length(vWorld.xz - vec2(e.w, 0.0));
    float fade = 1.0 - smoothstep(6.0, 22.0, dist);
    fragColor = vec4(col * fade + vec3(0.02, 0.021, 0.026) * (1.0 - fade), 1.0);
}
