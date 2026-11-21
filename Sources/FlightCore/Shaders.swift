// Metal shading language source, compiled at launch.
//
// Frame layout:
//   1. shadow maps (aircraft cascade every frame, airfield cascade when the scene changes)
//   2. scene -> 4x MSAA HDR target (linear light, RGBA16F) with resolved colour and depth
//   3. ambient occlusion from the resolved depth, at half resolution, then blurred
//   4. bloom: bright-pass and a chain of downsampled blurs
//   5. composite: occlusion, bloom, exposure, filmic tone mapping, grading, vignette, dither

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Frame {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4x4 shadow0;
    float4x4 shadow1;
    float4 camPos;      // w = time
    float4 sunDir;      // w = runway type
    float4 sunColor;    // w = fog density
    float4 zenith;      // w = panorama rotation (turns)
    float4 horizon;     // w = panorama horizon offset (rad)
    float4 runway;      // half length, half width, site style, cloudiness
    float4 ambient;
    float4 post;        // x = tone-map in the scene shader (thumbnails), y = exposure, z = AO strength, w = bloom strength
    float4 screen;      // xy = 1 / render size, z = airfield shadow map size, w = aircraft shadow half-extent (m)
    float4 pano;        // photo sites: rgb = light grade, w = 1 when it applies
};
struct Draw { float4x4 model; float4 tint; float4 params; };

struct VIn { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float4 col [[attribute(2)]]; };
struct VOut { float4 pos [[position]]; float3 wp; float3 nrm; float4 col; };
struct SkyOut { float4 pos [[position]]; float2 ndc; };

constant float2 poisson[12] = {
    float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),
    float2(0.962, -0.195), float2(0.473, -0.480), float2(0.519, 0.767), float2(0.185, -0.893),
    float2(0.507, 0.064), float2(0.896, 0.412), float2(-0.322, -0.933), float2(-0.792, -0.598)
};
constant float3 aoKernel[10] = {
    float3(0.54, 0.22, 0.81), float3(-0.71, 0.35, 0.61), float3(0.13, -0.87, 0.47), float3(-0.32, -0.41, 0.85), float3(0.89, -0.31, 0.33),
    float3(-0.45, 0.83, 0.33), float3(0.27, 0.62, 0.74), float3(-0.92, -0.18, 0.35), float3(0.61, -0.71, 0.35), float3(0.05, 0.12, 0.99)
};

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}
static float fbm(float2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 4; i++) { s += a * vnoise(p); p = p * 2.03 + 17.0; a *= 0.5; }
    return s / 0.9375;
}
static float fbm2(float2 p) { return vnoise(p) * 0.67 + vnoise(p * 2.03 + 17.0) * 0.33; }
static float fbm5(float2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.07 + 13.0; a *= 0.5; }
    return s / 0.96875;
}
static float3 tonemap(float3 c) {
    return saturate((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14));
}
/// Inverse of tonemap(), so an already-graded photo survives the HDR pipeline unchanged.
static float3 untonemap(float3 y) {
    y = clamp(y, 0.0, 0.985);
    float3 a = 2.51 - 2.43 * y, b = 0.03 - 0.59 * y;
    return (-b + sqrt(b * b + 4.0 * a * 0.14 * y)) / (2.0 * a);
}
static float band(float d, float halfw, float aa) { return 1.0 - smoothstep(halfw - aa, halfw + aa, abs(d)); }
static float4 shade(float3 c, float a, Frame f) { return float4(f.post.x > 0.5 ? tonemap(c) : c, a); }

/// Clear-sky radiance without sun disc or clouds; also used for reflections and distance haze.
static float3 skyBase(float3 d, Frame f) {
    float3 L = f.sunDir.xyz;
    float t = saturate(d.y);
    float3 c = mix(f.horizon.rgb, f.zenith.rgb, pow(t, 0.42));
    float sd = dot(d, L);
    float hz = pow(1.0 - t, 5.0);
    c += f.sunColor.rgb * hz * (0.025 + 0.11 * pow(saturate(sd), 4.0));      // bright haze low down, strongest toward the sun
    c *= 0.9 + 0.1 * saturate(1.0 - sd);                                      // deeper blue away from the sun
    return c;
}

static float waveH(float2 q, float t) {
    return fbm2(q * 0.22 + float2(t * 0.35, t * 0.2)) + 0.45 * vnoise(q * 0.9 - float2(t * 0.6, t * 0.35));
}

vertex VOut sceneVS(VIn in [[stage_in]], constant Frame& f [[buffer(1)]], constant Draw& d [[buffer(2)]]) {
    VOut o;
    float4 w = d.model * float4(in.pos, 1.0);
    if (int(d.params.x) >= 5) {
        // vegetation sways in the wind; vertex alpha is the sway weight (0 at the root)
        float ph = w.x * 0.35 + w.z * 0.27, t = f.camPos.w;
        float g = sin(t * 1.7 + ph) * 0.6 + sin(t * 3.1 + ph * 1.7) * 0.4;
        w.xz += (d.params.zw * (0.55 + 0.45 * g) * 0.035 + float2(g, cos(t * 2.3 + ph)) * 0.012) * in.col.a;
    }
    o.wp = w.xyz;
    o.pos = f.viewProj * w;
    o.nrm = (d.model * float4(in.nrm, 0.0)).xyz;
    o.col = in.col * d.tint;
    return o;
}

vertex float4 shadowVS(VIn in [[stage_in]], constant float4x4& vp [[buffer(1)]], constant Draw& d [[buffer(2)]]) {
    return vp * (d.model * float4(in.pos, 1.0));
}

/// Sun visibility. Near the aircraft the penumbra widens with the distance between the
/// shadow caster and the surface (a high aircraft throws a soft shadow, a parked one a crisp one).
static float sunShadow(depth2d<float> sh0, depth2d<float> sh1, sampler cmp, sampler pt, Frame f, float3 wp, float2 frag, int taps) {
    // interleaved gradient noise: a well-spread per-pixel rotation that MSAA and the eye average out
    float ang = fract(52.9829189 * fract(dot(frag, float2(0.06711056, 0.00583715)))) * 6.2831853;
    float2x2 rot = float2x2(cos(ang), -sin(ang), sin(ang), cos(ang));
    float s0 = 1.0, s1 = 1.0;
    float4 c = f.shadow0 * float4(wp, 1.0);
    float2 uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    if (uv.x > 0.01 && uv.x < 0.99 && uv.y > 0.01 && uv.y < 0.99 && c.z > 0.0 && c.z < 1.0) {
        float bias = 0.00003, sum = 0.0, n = 0.0;
        for (int i = 0; i < 6; i++) {
            float d = sh0.sample(pt, uv + rot * poisson[i] * 0.05);
            if (d < c.z - bias) { sum += d; n += 1.0; }
        }
        if (n > 0.5) {
            float gap = (c.z - sum / n) * 1499.0;                               // metres between caster and receiver
            float r = clamp(gap * 0.011 / (2.0 * f.screen.w), 1.3 / 2048.0, 0.11);
            float s = 0.0;
            for (int i = 0; i < 12; i++) s += sh0.sample_compare(cmp, uv + rot * poisson[i] * r, c.z - bias);
            s0 = s / 12.0;
        }
    }
    c = f.shadow1 * float4(wp, 1.0);
    uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    if (uv.x > 0.01 && uv.x < 0.99 && uv.y > 0.01 && uv.y < 0.99 && c.z > 0.0 && c.z < 1.0) {
        float s = 0.0, r = 1.7 / f.screen.z;
        for (int i = 0; i < taps; i++) s += sh1.sample_compare(cmp, uv + rot * poisson[i] * r, c.z - 0.0005);
        // fade out toward the edge of the map instead of ending in a hard line
        float edge = smoothstep(0.5, 0.3, length(uv - 0.5));
        s1 = mix(1.0, s / float(taps), edge);
    }
    return min(s0, s1);
}

fragment float4 sceneFS(VOut in [[stage_in]], constant Frame& f [[buffer(1)]], constant Draw& d [[buffer(2)]],
                        depth2d<float> sh0 [[texture(0)]], depth2d<float> sh1 [[texture(1)]], sampler cmp [[sampler(0)]], sampler pt [[sampler(1)]]) {
    float3 toCam = f.camPos.xyz - in.wp;
    float dist = length(toCam);
    float3 V = toCam / dist;
    float3 N = normalize(in.nrm);
    float3 L = f.sunDir.xyz;
    float3 albedo = pow(in.col.rgb, float3(2.2));
    int material = int(d.params.x);
    int shadowTaps = material == 6 ? 1 : (material == 0 ? 6 : 4);        // grass is dense and noisy: one tap is enough
    float gloss = material == 0 ? in.col.a * d.params.y : 0.0;
    float shininess = 400.0;
    float groundSparkle = 0.0;
    float3 haze = skyBase(normalize(float3(-V.x, 0.03, -V.z)), f);
    float fog = 1.0 - exp(-dist * f.sunColor.w);

    if (material == 4) {     // translucent helpers: prop discs, soft blob shadows, obstacle overlay
        return shade(albedo * (f.ambient.rgb + f.sunColor.rgb * 0.4), in.col.a, f);
    }
    if (material == 3) {
        // smoke / dust puff: the normal attribute carries the position inside the quad
        float a = in.col.a * smoothstep(1.0, 0.25, length(in.nrm.xy));
        float3 c = albedo * (f.ambient.rgb * 1.5 + f.sunColor.rgb * 0.3);
        return shade(mix(c, haze, fog), a, f);
    }
    if (material == 6) {
        // grass card: cut individual blades out of the quad
        float2 uv = in.nrm.xy;
        float bx = uv.x * 11.0, id = floor(bx), fx = fract(bx) - 0.5;
        float hsh = hash21(float2(id, 3.7));
        float t = uv.y / (0.4 + 0.6 * hsh);
        float lean = (hash21(float2(id, 9.1)) - 0.5) * 0.8;
        if (t > 1.0 || abs(fx - lean * t * t) > 0.46 * (1.0 - t * t)) discard_fragment();
        albedo = mix(albedo, float3(dot(albedo, float3(0.3, 0.6, 0.1))), 0.3) * 0.62;
        albedo *= (0.8 + 0.4 * hsh) * (0.4 + 0.6 * t);        // darker at the roots: cheap self-shadowing
        N = float3(0.0, 1.0, 0.0);
        material = 5;
    } else if (material == 5) {
        // trees and bushes: clumps of leaves, lit unevenly, darker underneath and inside the crown, and less
        // garish than a plain coat of green paint
        float3 q = in.wp * 2.1;
        float clump = vnoise(q.xz + q.y * 0.7) * 0.6 + vnoise(q.xz * 3.3 + q.y * 2.3 + 5.0) * 0.4;
        float lumF = dot(albedo, float3(0.3, 0.6, 0.1));
        float leafy = saturate((albedo.g - albedo.r) * 6.0 + (albedo.r - albedo.b) * 2.0);      // foliage, not trunks or snow
        albedo = mix(albedo, float3(lumF), 0.22 * leafy) * mix(1.0, 0.86, leafy);
        albedo *= 1.0 + (clump - 0.5) * 0.95 * leafy;
        albedo *= mix(1.0, 0.55 + 0.45 * smoothstep(-0.7, 0.5, N.y), leafy);
        // single leaves close by
        float fwl = max(length(dfdx(in.wp)), length(dfdy(in.wp)));
        float leaf = hash21(floor(q.xz * 9.0 + q.y * 5.0) + 0.5) - 0.5;
        albedo *= 1.0 + leaf * 0.45 * leafy * saturate(1.5 - fwl * 40.0);
        N = normalize(N + float3(clump - 0.5, 0.0, vnoise(q.zx * 1.7 + q.y) - 0.5) * 1.1 * leafy);
    }
    if (material == 1) {
        float2 p = in.wp.xz;
        float fade = exp(-dist * 0.006);
        float nearFade = exp(-dist * 0.07);
        // how much ground one pixel covers: detail finer than that is left out, so nothing shimmers in the distance
        // (the geometric mean of its two extents: at a shallow angle a pixel is long and thin on the ground)
        float fw = sqrt(length(dfdx(p)) * length(dfdy(p)));
        #define OCT(k) saturate(1.6 - (k) * fw * 1.9)
        float macro = fbm2(p * 0.021);
        float patches = vnoise(p * 0.31 + 5.0);
        float fine = vnoise(p * 9.0);
        // bright ground (snow, sand) keeps its brightness and shows less mottling than turf
        float lum0 = dot(albedo, float3(0.3, 0.6, 0.1));
        float bright = smoothstep(0.35, 0.75, lum0);
        float mott = 1.0 - 0.75 * bright;
        float turf = saturate((albedo.g - max(albedo.r, albedo.b)) * 9.0);         // green ground: grass
        float sandy = saturate((albedo.r - albedo.b) * 5.0) * smoothstep(0.12, 0.35, lum0) * (1.0 - turf);
        float snowy = smoothstep(0.6, 0.85, lum0) * saturate(1.0 - (albedo.r - albedo.b) * 12.0);

        // ---- steep ground is rock: bare, layered, darker in the gullies (worked out only where it is steep)
        float3 Ng = N;
        float slope = 1.0 - Ng.y;
        float rock = smoothstep(0.16, 0.38, slope + (macro - 0.5) * 0.14) * (1.0 - snowy * 0.5);

        albedo = mix(albedo, float3(lum0), 0.34 * (1.0 - bright)) * mix(0.55, 0.9, bright);
        // broad differences in colour: lusher and drier patches, not just lighter and darker
        float3 tint = mix(float3(1.10, 0.98, 0.78), float3(0.86, 1.04, 0.92), patches);
        albedo *= mix(float3(1.0), tint, (0.5 * turf + 0.25 * sandy) * mott);
        albedo *= 1.0 + (0.5 * macro - 0.25) * mott;
        // detail at every scale from metres down to millimetres. Each scale is only worked out where it is larger
        // than a pixel, so nothing shimmers in the distance and nothing is computed that cannot be seen.
        float o1 = OCT(1.3), o4 = OCT(4.1), o12 = OCT(12.7), o36 = OCT(37.0), o110 = OCT(113.0);
        float d1 = 0.5, d4 = 0.5, d12 = 0.5, d36 = 0.5, d110 = 0.5;
        if (o1 > 0.0) d1 = vnoise(p * 1.3 + 7.0);
        if (o4 > 0.0) d4 = vnoise(p * 4.1 + 3.0);
        if (o12 > 0.0) d12 = vnoise(p * 12.7);
        if (o36 > 0.0) d36 = vnoise(p * 37.0 + 11.0);
        if (o110 > 0.0) d110 = vnoise(p * 113.0 + 2.0);
        float detail = (d1 - 0.5) * 0.22 * o1 + (d4 - 0.5) * 0.20 * o4 + (d12 - 0.5) * 0.20 * o12 + (d36 - 0.5) * 0.20 * o36 + (d110 - 0.5) * 0.18 * o110;
        albedo *= 1.0 + detail * (0.55 + 0.45 * mott) * (1.0 - rock * 0.4);
        // grain: crisp speckle, the difference between a surface in focus and a blurred one. Grass tufts, grit,
        // grains of sand and snow crust; in cells with wavy, irregular edges, so no grid shows.
        float og = OCT(47.0);
        if (og > 0.0) {
            float2 pw = p + (float2(d12, d36) - 0.5) * 0.11;
            float2 pw2 = p + (float2(d36, d110) - 0.5) * 0.03;
            float g1 = hash21(floor(pw * float2(47.0, 31.0)) + 0.5), g2 = hash21(floor(pw2.yx * float2(130.0, 95.0)) + 7.5);
            float grain = (g1 - 0.5) * og + (g2 - 0.5) * 0.9 * OCT(130.0);
            albedo *= 1.0 + grain * (0.34 * turf + 0.16 * sandy + 0.07 * snowy + 0.14 * (1.0 - turf) * (1.0 - bright));
            // grass: fine upright streaks close by, seen as blades
            if (turf > 0.01) {
                float blades = vnoise(p * float2(61.0, 17.0) + 3.0) * 0.6 + vnoise(p.yx * float2(53.0, 15.0)) * 0.4;
                albedo *= 1.0 + (blades - 0.5) * 0.5 * turf * OCT(60.0);
            }
        }
        if (rock > 0.01) {
            float strata = fbm2(float2(in.wp.y * 0.11 + macro * 3.0, dot(p, float2(0.011, 0.016))));
            float crags = fbm2(p * 0.09 + float2(in.wp.y * 0.05, 0.0));
            float3 rockCol = albedo * (0.62 + 0.55 * strata) * (0.8 + 0.4 * crags);
            rockCol = mix(rockCol, float3(dot(rockCol, float3(0.3, 0.6, 0.1))), 0.35 * (1.0 - bright));
            albedo = mix(albedo, rockCol, rock * (1.0 - 0.6 * snowy));
        }

        // small-scale relief so the ground catches the light unevenly; gentler when the sun is low, where it
        // would otherwise turn the ground into dark blotches. The slope of the relief comes from how the detail
        // changes from one pixel to the next.
        float lowSun = 0.35 + 0.65 * smoothstep(0.15, 0.6, L.y);
        float3 bump = float3(0.0);
        float ob = OCT(8.0);
        if (ob > 0.0) {
            float hgt = d4 * 0.6 + d12 * 0.4;
            float2 px = dfdx(p), py = dfdy(p);
            float hx = dfdx(hgt), hy = dfdy(hgt);
            float det = px.x * py.y - px.y * py.x;
            if (abs(det) > 1e-12) {
                float2 grad = float2(hx * py.y - hy * px.y, hy * px.x - hx * py.x) / det;
                bump = float3(-grad.x, 0.0, -grad.y) * (0.05 * ob);
                bump = clamp(bump, float3(-0.6), float3(0.6));
            }
        }
        float bumpAmt = 0.75 * mott * lowSun;
        float bumpFade = 1.0;
        // wind ripples on sand
        if (sandy > 0.02 && OCT(3.0) > 0.0) {
            float rip = sin(dot(p, float2(8.2, 3.1)) + d1 * 9.0);
            bump += float3(0.35, 0.0, 0.13) * rip * 0.06 * sandy * OCT(3.0);
        }
        // the lie of the land far away: folds, gullies and ridges that the coarse terrain mesh cannot show
        float farAmt = smoothstep(60.0, 400.0, dist) * 2.4 * smoothstep(0.03, 0.4, slope);
        if (farAmt > 0.02) {
            // ridged: sharp crests and soft valleys. Its slope is read from neighbouring pixels.
            // (built from the broad mottling that is already worked out, plus one larger fold)
            float r0 = abs(macro - 0.5);
            float relief = r0 * 5.0 + abs(vnoise(p * 0.0075 + 31.0) - 0.5) * 11.0;
            float2 px = dfdx(p), py = dfdy(p);
            float hx = dfdx(relief), hy = dfdy(relief);
            float det = px.x * py.y - px.y * py.x;
            float3 fold = float3(0.0);
            if (abs(det) > 1e-9) {
                float2 grad = float2(hx * py.y - hy * px.y, hy * px.x - hx * py.x) / det;
                fold = clamp(float3(-grad.x, 0.0, -grad.y) * 5.5, float3(-1.2), float3(1.2));
            }
            N = normalize(N + fold * farAmt);
            albedo *= 1.0 - 0.35 * min(farAmt, 1.0) * smoothstep(0.1, 0.0, r0) * (1.0 - snowy * 0.6);       // shaded gullies
        }
        // snow glitters where single crystals catch the sun
        if (snowy > 0.05) groundSparkle = step(0.9965, hash21(floor(p * 85.0) + floor(V.xz * 40.0))) * snowy * nearFade * smoothstep(0.1, 0.4, L.y);

        float hl = f.runway.x, hw = f.runway.y;
        int type = int(f.sunDir.w);
        float ax = abs(p.x), az = abs(p.y);
        float aa = max(fwidth(p.y), 0.02), aax = max(fwidth(p.x), 0.02);
        float inside = (1.0 - smoothstep(hw - aa, hw + aa, az)) * (1.0 - smoothstep(hl - aax, hl + aax, ax));
        if (inside > 0.0) {
            float lineFade = saturate(1.6 - aa * 2.0);
            if (type == 0) {
                float grit = vnoise(p * 55.0);
                float3 asp = float3(0.035, 0.036, 0.04) * (0.8 + 0.5 * fbm(p * 2.5) + 0.25 * fine * fade + 0.3 * (grit - 0.5) * nearFade);
                // tyre-darkened centre and patched repairs
                asp *= 1.0 - 0.18 * band(az, 1.6, 1.2) * (0.5 + 0.5 * fbm(p * 0.4));
                asp *= 1.0 - 0.25 * smoothstep(0.62, 0.7, fbm(p * 0.23 + 40.0));
                float ln = band(az - (hw - 0.6), 0.09, aa);
                ln = max(ln, band(az, 0.1, aa) * step(0.5, fract(ax / 9.0)) * step(ax, hl - 14.0));
                ln = max(ln, step(hl - 9.0, ax) * step(ax, hl - 3.0) * step(0.45, fract(az / 1.3)) * step(az, hw - 1.3));
                ln *= 0.75 + 0.25 * fbm(p * 3.0);                         // worn paint
                asp = mix(asp, float3(0.62), ln * lineFade);
                albedo = mix(albedo, asp, inside);
                gloss = mix(gloss, 0.1, inside);
                shininess = 45.0;
                bumpAmt = mix(bumpAmt, 0.08, inside);
            } else if (type == 1) {
                float stripe = 0.9 + 0.2 * step(0.5, fract(p.y / 2.5));
                float3 mown = albedo * float3(1.25, 1.3, 1.0) * stripe;
                float mk = max(band(az - (hw - 0.3), 0.12, aa) * step(0.5, fract(ax / 6.0)), step(hl - 0.6, ax) * step(0.5, fract(az / 2.0)));
                mown = mix(mown, float3(0.8), mk * lineFade);
                albedo = mix(albedo, mown, inside);
                bumpAmt = mix(bumpAmt, 0.7, inside);
            } else {
                float3 dirt = albedo * 0.82 + float3(0.01);
                float mk = max(band(az - (hw - 0.4), 0.15, aa), band(az, 0.12, aa) * step(0.5, fract(ax / 12.0)));
                dirt = mix(dirt, type == 3 ? float3(0.7, 0.16, 0.04) : float3(0.85, 0.82, 0.75), mk * lineFade * 0.8);
                albedo = mix(albedo, dirt, inside);
            }
        }
        N = normalize(N + bump * (bumpAmt * bumpFade));
    } else if (dot(N, V) < 0.0) {
        N = -N;
    }

    float ndl = max(dot(N, L), 0.0);
    if (material == 5) ndl = saturate((dot(N, L) + 0.45) / 1.45);     // soft wrap lighting for foliage
    float shadow = sunShadow(sh0, sh1, cmp, pt, f, in.wp, in.pos.xy, shadowTaps);
    if (material == 2) {
        // photo-site shadow catcher: only darkens the panorama behind it
        return float4(0.0, 0.0, 0.0, (1.0 - shadow) * 0.6 * exp(-dist * 0.004));
    }
    if (material == 7) {
        // water: rippled surface reflecting the sky, clearer and paler in the shallows (vertex colour and alpha)
        float2 p = in.wp.xz;
        float t = f.camPos.w, e = 0.35;
        float h0 = waveH(p, t), hx = waveH(p + float2(e, 0.0), t), hz = waveH(p + float2(0.0, e), t);
        float calm = exp(-dist * 0.004);
        float3 Nw = normalize(float3((h0 - hx) * 1.3 * calm, 1.0, (h0 - hz) * 1.3 * calm));
        float fres = 0.02 + 0.98 * pow(1.0 - max(dot(Nw, V), 0.0), 5.0);
        float3 R = reflect(-V, Nw);
        R.y = abs(R.y);
        float3 body = albedo * (f.ambient.rgb * 0.9 + f.sunColor.rgb * 0.35 * max(dot(Nw, L), 0.0));
        // darker and lighter streaks where the wind ruffles the surface more or less
        body *= 0.82 + 0.36 * fbm2(p * 0.012 + float2(t * 0.012, 0.0));
        float ndh = max(dot(Nw, normalize(L + V)), 0.0);
        float3 c = mix(body, skyBase(R, f), fres) + f.sunColor.rgb * (pow(ndh, 700.0) * 6.0 + pow(ndh, 60.0) * 0.25) * shadow;
        // foam where the water runs out onto the shore: lines that drift in and fade
        float shallow = 1.0 - smoothstep(0.27, 0.46, in.col.a);
        float wash = vnoise(p * 0.9 + float2(t * 0.25, t * 0.1)) + 0.25 * sin(t * 0.7 + p.x * 0.11 + p.y * 0.07);
        float foam = shallow * smoothstep(0.52, 0.8, wash) * (0.55 + 0.45 * vnoise(p * 7.0 + t * 0.3));
        c = mix(c, (f.ambient.rgb * 1.3 + f.sunColor.rgb * 0.5 * shadow) * 0.85, foam);
        return shade(mix(c, haze, fog), max(mix(in.col.a, 1.0, fres), foam), f);
    }
    if (material == 1) {
        // cloud shadows drifting over the landscape
        float cs = fbm2(in.wp.xz * 0.0016 + f.camPos.w * 0.004);
        shadow *= 1.0 - 0.5 * f.runway.w * smoothstep(0.5, 0.72, cs);
    }
    float3 skyAmb = f.ambient.rgb;
    float3 gndAmb = skyAmb * float3(0.45, 0.42, 0.36);
    float3 amb = mix(gndAmb, skyAmb, N.y * 0.5 + 0.5);
    float3 col = albedo * (amb + f.sunColor.rgb * ndl * shadow);
    if (material == 1) col += f.sunColor.rgb * groundSparkle * shadow * 1.5;
    if (material == 5) {
        // light shining through leaves when looking toward the sun
        col += albedo * f.sunColor.rgb * float3(0.9, 1.0, 0.55) * 0.35 * pow(saturate(dot(-V, L)), 3.0) * shadow;
    }
    if (gloss > 0.0) {
        // glossy paint, film covering and worn asphalt: sky reflection with Fresnel, plus a sun highlight
        float3 H = normalize(L + V);
        float ndh = max(dot(N, H), 0.0);
        float fres = 0.04 + 0.96 * pow(1.0 - max(dot(N, V), 0.0), 5.0);
        float3 R = reflect(-V, N);
        float3 env = R.y > 0.0 ? skyBase(R, f) : mix(f.horizon.rgb, gndAmb * 1.2, saturate(-R.y * 4.0));
        col = mix(col, env, fres * gloss * 0.7);
        col += f.sunColor.rgb * (pow(ndh, shininess) * (shininess > 100.0 ? 3.0 : 0.5) + pow(ndh, 50.0) * 0.22) * gloss * shadow * step(0.0, dot(N, L));
    }
    col = mix(col, haze, fog);
    return shade(col, 1.0, f);
}

vertex SkyOut skyVS(uint vid [[vertex_id]]) {
    SkyOut o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.ndc = p * 2.0 - 1.0;
    o.pos = float4(o.ndc, 0.0, 1.0);
    return o;
}
static float2 uvOf(float2 ndc) { return float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5); }

/// Catmull-Rom interpolation of the panorama: smooth, sharp edges where plain bilinear filtering shows the pixel grid.
static float3 panoCubic(texture2d<float> t, sampler s, float2 uv, float2 size) {
    float2 p = uv * size, tc = floor(p - 0.5) + 0.5, fr = p - tc;
    float2 w0 = fr * (-0.5 + fr * (1.0 - 0.5 * fr));
    float2 w1 = 1.0 + fr * fr * (-2.5 + 1.5 * fr);
    float2 w2 = fr * (0.5 + fr * (2.0 - 1.5 * fr));
    float2 w3 = fr * fr * (-0.5 + 0.5 * fr);
    float2 w12 = w1 + w2;
    float2 t0 = (tc - 1.0) / size, t3 = (tc + 2.0) / size, t12 = (tc + w2 / w12) / size;
    float3 r = t.sample(s, float2(t0.x, t0.y), level(0.0)).rgb * (w0.x * w0.y) + t.sample(s, float2(t12.x, t0.y), level(0.0)).rgb * (w12.x * w0.y) + t.sample(s, float2(t3.x, t0.y), level(0.0)).rgb * (w3.x * w0.y)
             + t.sample(s, float2(t0.x, t12.y), level(0.0)).rgb * (w0.x * w12.y) + t.sample(s, float2(t12.x, t12.y), level(0.0)).rgb * (w12.x * w12.y) + t.sample(s, float2(t3.x, t12.y), level(0.0)).rgb * (w3.x * w12.y)
             + t.sample(s, float2(t0.x, t3.y), level(0.0)).rgb * (w0.x * w3.y) + t.sample(s, float2(t12.x, t3.y), level(0.0)).rgb * (w12.x * w3.y) + t.sample(s, float2(t3.x, t3.y), level(0.0)).rgb * (w3.x * w3.y);
    return max(r, 0.0);
}

fragment float4 panoFS(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]], texture2d<float> pano [[texture(0)]], sampler ps [[sampler(1)]]) {
    float4 w = f.invViewProj * float4(in.ndc, 0.5, 1.0);
    float3 d = normalize(w.xyz / w.w - f.camPos.xyz);
    const float PI = 3.14159265;
    float u = atan2(d.x, -d.z) / (2.0 * PI);
    float u2 = atan2(-d.x, d.z) / (2.0 * PI);     // same angle half a turn away: its seam is elsewhere
    float v = 0.5 - (asin(clamp(d.y, -1.0, 1.0)) + f.horizon.w) / PI;
    float gx = abs(dfdx(u)) < abs(dfdx(u2)) ? dfdx(u) : dfdx(u2);
    float gy = abs(dfdy(u)) < abs(dfdy(u2)) ? dfdy(u) : dfdy(u2);
    float3 c = pano.sample(ps, float2(u + 0.5 + f.zenith.w, v), gradient2d(float2(gx, dfdx(v)), float2(gy, dfdy(v)))).rgb;
    if (f.pano.w > 0.5) c *= f.pano.rgb;
    return float4(f.post.x > 0.5 ? c : untonemap(c) / f.post.y, 1.0);
}

/// One cloud layer: density plus how much sunlight reaches this point through the cloud.
static float2 cloudLayer(float2 uv, float cover, float3 L, float scale) {
    float wn = fbm2(uv * 0.7 + 3.0);
    float2 warp = float2(wn, fract(wn * 7.3)) - 0.5;
    warp.y = (vnoise(uv * 0.9 + 11.0) - 0.5);
    float2 q = (uv + warp * 0.55) * scale;
    float n = fbm5(q);
    float dens = smoothstep(0.8 - cover * 0.52, 1.02 - cover * 0.52, n);
    float n2 = fbm(q + L.xz * 0.16 * scale);
    float lit = saturate(0.5 + (n - n2) * 3.2);            // thinner toward the sun = brighter
    lit = saturate(lit + (fbm2(q * 5.3 + 2.0) - 0.5) * 0.5 - (dens - 0.5) * 0.25);     // billowy detail, darker cores
    return float2(dens, lit);
}

fragment float4 skyFS(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]]) {
    float4 w = f.invViewProj * float4(in.ndc, 0.5, 1.0);
    float3 d = normalize(w.xyz / w.w - f.camPos.xyz);
    float3 L = f.sunDir.xyz;
    float3 c = skyBase(d, f);
    float sd = max(dot(d, L), 0.0);
    c += f.sunColor.rgb * (pow(sd, 8.0) * 0.1 + pow(sd, 120.0) * 0.35);
    float sunDisc = pow(sd, 3000.0) * 14.0;
    if (d.y > 0.005) {
        float cover = f.runway.w, t = f.camPos.w;
        // high thin cirrus, then drifting cumulus below it
        float2 uvh = d.xz / (d.y + 0.3) * 0.5 + float2(t * 0.0015, 0.0);
        float cirrus = smoothstep(0.6, 1.0, fbm(uvh * float2(1.0, 3.2) + 20.0)) * 0.3 * smoothstep(0.02, 0.3, d.y) * (0.3 + cover);
        c = mix(c, f.sunColor.rgb * 0.3 + f.ambient.rgb * 0.9, cirrus);
        float2 uv = d.xz / (d.y + 0.12) * 0.9 + float2(t * 0.006, t * 0.002);
        float2 cl = cloudLayer(uv, cover, L, 1.1);
        float3 sunlit = f.sunColor.rgb * 0.62 + f.ambient.rgb * 0.9;
        float3 shaded = f.ambient.rgb * 0.78 + f.horizon.rgb * 0.12;
        float3 cloud = mix(shaded, sunlit, cl.y);
        cloud += f.sunColor.rgb * pow(sd, 10.0) * (1.0 - cl.x) * 1.4;         // silver lining near the sun
        float a = cl.x * smoothstep(0.005, 0.16, d.y) * 0.94;
        c = mix(c, cloud, a);
        sunDisc *= 1.0 - a;
    }
    c += f.sunColor.rgb * sunDisc;
    c = mix(c, f.horizon.rgb * 0.8, smoothstep(0.0, -0.15, d.y));
    return shade(c, 1.0, f);
}

/// The sky is rendered at half resolution (it is smooth) and stretched over the scene's background.
fragment float4 skyBlitFS(SkyOut in [[stage_in]], texture2d<float> sky [[texture(0)]], sampler s [[sampler(1)]]) {
    return float4(sky.sample(s, uvOf(in.ndc)).rgb, 1.0);
}

// ---- post-processing

static float3 worldAt(float2 uv, float depth, Frame f) {
    float4 w = f.invViewProj * float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    return w.xyz / w.w;
}

/// Ambient occlusion from the depth buffer: darkens creases and contact areas the direct lighting misses.
fragment float4 aoFS(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]], depth2d<float> depthTex [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = uvOf(in.ndc);
    float d = depthTex.sample(s, uv);
    if (d <= 0.0) return float4(1.0);
    float3 P = worldAt(uv, d, f);
    float3 cam = f.camPos.xyz;
    float dc = length(P - cam);
    if (dc > 260.0) return float4(1.0);
    float2 px = f.screen.xy * 2.0;
    float3 Px = worldAt(uv + float2(px.x, 0.0), depthTex.sample(s, uv + float2(px.x, 0.0)), f);
    float3 Py = worldAt(uv + float2(0.0, px.y), depthTex.sample(s, uv + float2(0.0, px.y)), f);
    float3 N = normalize(cross(Py - P, Px - P));
    if (dot(N, cam - P) < 0.0) N = -N;
    float radius = clamp(dc * 0.035, 0.12, 2.2);
    float3 rnd = normalize(float3(hash21(in.pos.xy), hash21(in.pos.xy + 17.0), hash21(in.pos.xy + 41.0)) - 0.5);
    float occ = 0.0;
    for (int i = 0; i < 7; i++) {
        float3 dir = reflect(aoKernel[i], rnd);
        if (dot(dir, N) < 0.0) dir = -dir;
        float3 S = P + N * (0.03 * radius) + dir * (radius * (0.25 + 0.11 * float(i)));
        float4 c = f.viewProj * float4(S, 1.0);
        float2 suv = float2(c.x / c.w * 0.5 + 0.5, 0.5 - c.y / c.w * 0.5);
        float sdp = depthTex.sample(s, suv);
        if (sdp <= 0.0) continue;
        float dq = length(worldAt(suv, sdp, f) - cam), ds = length(S - cam);
        float range = smoothstep(0.0, 1.0, radius / max(abs(dc - dq), 0.001));
        occ += (dq < ds - 0.03 * radius ? 1.0 : 0.0) * range;
    }
    float ao = 1.0 - occ / 7.0;
    return float4(mix(1.0, ao, smoothstep(260.0, 160.0, dc)));
}

fragment float4 aoBlurFS(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]], texture2d<float> ao [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = uvOf(in.ndc), px = f.screen.xy * 2.0;
    float a = ao.sample(s, uv + px * float2(-1.5, -0.5)).r + ao.sample(s, uv + px * float2(0.5, -1.5)).r
            + ao.sample(s, uv + px * float2(1.5, 0.5)).r + ao.sample(s, uv + px * float2(-0.5, 1.5)).r + ao.sample(s, uv).r;
    return float4(a / 5.0);
}

/// Keep only what is brighter than a sunlit white surface: the sun, glints and bright cloud edges.
fragment float4 bloomPreFS(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]], texture2d<float> hdr [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = uvOf(in.ndc), px = f.screen.xy;
    float3 c = hdr.sample(s, uv + px * float2(-1, -1)).rgb + hdr.sample(s, uv + px * float2(1, -1)).rgb
             + hdr.sample(s, uv + px * float2(-1, 1)).rgb + hdr.sample(s, uv + px * float2(1, 1)).rgb;
    c *= 0.25;
    float l = max(c.r, max(c.g, c.b));
    float k = smoothstep(4.0, 7.0, l);
    return float4(min(c * k, float3(60.0)), 1.0);
}

fragment float4 bloomDownFS(SkyOut in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = uvOf(in.ndc);
    float2 px = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = src.sample(s, uv).rgb * 4.0;
    c += src.sample(s, uv + px * float2(-1, -1)).rgb + src.sample(s, uv + px * float2(1, -1)).rgb
       + src.sample(s, uv + px * float2(-1, 1)).rgb + src.sample(s, uv + px * float2(1, 1)).rgb;
    return float4(c / 8.0, 1.0);
}

fragment float4 compositeFS(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]],
                            texture2d<float> hdr [[texture(0)]], texture2d<float> ao [[texture(1)]],
                            texture2d<float> b1 [[texture(2)]], texture2d<float> b2 [[texture(3)]], texture2d<float> b3 [[texture(4)]],
                            texture2d<float> b4 [[texture(5)]], sampler s [[sampler(0)]]) {
    float2 uv = uvOf(in.ndc);
    float3 c = hdr.sample(s, uv).rgb;
    c *= mix(1.0, ao.sample(s, uv).r, f.post.z);
    float3 bloom = b1.sample(s, uv).rgb * 0.34 + b2.sample(s, uv).rgb * 0.3 + b3.sample(s, uv).rgb * 0.22 + b4.sample(s, uv).rgb * 0.14;
    c += bloom * f.post.w;
    c = tonemap(c * f.post.y);
    // gentle grade: a little more contrast and colour, slightly warm highlights
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(l), c, 1.09);
    c = mix(c, c * c * (3.0 - 2.0 * c), 0.18);
    c *= mix(float3(0.985, 0.995, 1.02), float3(1.02, 1.0, 0.975), l);
    float2 q = uv - 0.5;
    c *= 1.0 - 0.42 * dot(q, q);
    c += (hash21(in.pos.xy + fract(f.camPos.w) * 61.0) - 0.5) / 255.0;      // dither away banding in the sky
    return float4(saturate(c), 1.0);
}
"""
