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
    float4 zenith;
    float4 horizon;
    float4 runway;      // half length, half width, site style, cloudiness
    float4 ambient;
};
struct Draw { float4x4 model; float4 tint; float4 params; };

struct VIn { float3 pos [[attribute(0)]]; float3 nrm [[attribute(1)]]; float4 col [[attribute(2)]]; };
struct VOut { float4 pos [[position]]; float3 wp; float3 nrm; float4 col; };

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
static float3 tonemap(float3 c) {
    return saturate((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14));
}
static float band(float d, float halfw, float aa) { return 1.0 - smoothstep(halfw - aa, halfw + aa, abs(d)); }

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

static float2 shadowLookup(depth2d<float> map, sampler s, float4x4 vp, float3 wp, float bias) {
    float4 c = vp * float4(wp, 1.0);
    float2 uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    bool inside = uv.x > 0.01 && uv.x < 0.99 && uv.y > 0.01 && uv.y < 0.99 && c.z > 0.0 && c.z < 1.0;
    float sum = 0.0;
    float t = 1.0 / 2048.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            sum += map.sample_compare(s, uv + float2(x, y) * t, c.z - bias);
    return float2(sum / 9.0, inside ? 1.0 : 0.0);
}

fragment float4 sceneFS(VOut in [[stage_in]], constant Frame& f [[buffer(1)]], constant Draw& d [[buffer(2)]],
                        depth2d<float> sh0 [[texture(0)]], depth2d<float> sh1 [[texture(1)]], sampler ss [[sampler(0)]]) {
    float3 toCam = f.camPos.xyz - in.wp;
    float dist = length(toCam);
    float3 V = toCam / dist;
    float3 N = normalize(in.nrm);
    float3 L = f.sunDir.xyz;
    float3 albedo = pow(in.col.rgb, float3(2.2));
    int material = int(d.params.x);
    float spec = d.params.y;

    if (material == 4) {     // translucent helpers: prop discs, soft shadows, obstacle overlay
        return float4(tonemap(albedo * (f.ambient.rgb + f.sunColor.rgb * 0.4)), in.col.a);
    }
    if (material == 3) {
        // smoke / dust puff: the normal attribute carries the position inside the quad
        float a = in.col.a * smoothstep(1.0, 0.25, length(in.nrm.xy));
        float3 c = albedo * (f.ambient.rgb * 1.5 + f.sunColor.rgb * 0.3);
        c = mix(c, f.horizon.rgb, 1.0 - exp(-dist * f.sunColor.w));
        return float4(tonemap(c), a);
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
        albedo *= (0.8 + 0.4 * hsh) * (0.45 + 0.55 * t);
        N = float3(0.0, 1.0, 0.0);
        material = 5;
    }
    if (material == 1) {
        float2 p = in.wp.xz;
        float fade = exp(-dist * 0.006);
        float macro = fbm(p * 0.021);
        float detail = fbm(p * 1.3);
        float fine = vnoise(p * 9.0);
        albedo = mix(albedo, float3(dot(albedo, float3(0.3, 0.6, 0.1))), 0.34) * 0.55;
        albedo *= (0.72 + 0.56 * macro) * mix(1.0, 0.62 + 0.5 * detail + 0.26 * fine, fade);
        // close-up: streaky blade-like variation
        float blades = vnoise(p * float2(41.0, 13.0) + 3.0) * 0.6 + vnoise(p.yx * float2(37.0, 11.0)) * 0.4;
        albedo *= mix(1.0, 0.72 + 0.56 * blades, exp(-dist * 0.07));
        float hl = f.runway.x, hw = f.runway.y;
        int type = int(f.sunDir.w);
        float ax = abs(p.x), az = abs(p.y);
        float aa = max(fwidth(p.y), 0.02), aax = max(fwidth(p.x), 0.02);
        float inside = (1.0 - smoothstep(hw - aa, hw + aa, az)) * (1.0 - smoothstep(hl - aax, hl + aax, ax));
        if (inside > 0.0) {
            float lineFade = saturate(1.6 - aa * 2.0);
            if (type == 0) {
                float3 asp = float3(0.035, 0.036, 0.04) * (0.8 + 0.5 * fbm(p * 2.5) + 0.25 * fine * fade);
                float ln = band(az - (hw - 0.6), 0.09, aa);
                ln = max(ln, band(az, 0.1, aa) * step(0.5, fract(ax / 9.0)) * step(ax, hl - 14.0));
                ln = max(ln, step(hl - 9.0, ax) * step(ax, hl - 3.0) * step(0.45, fract(az / 1.3)) * step(az, hw - 1.3));
                asp = mix(asp, float3(0.75), ln * lineFade);
                albedo = mix(albedo, asp, inside);
            } else if (type == 1) {
                float stripe = 0.9 + 0.2 * step(0.5, fract(p.y / 2.5));
                float3 mown = albedo * float3(1.25, 1.3, 1.0) * stripe;
                float mk = max(band(az - (hw - 0.3), 0.12, aa) * step(0.5, fract(ax / 6.0)), step(hl - 0.6, ax) * step(0.5, fract(az / 2.0)));
                mown = mix(mown, float3(0.8), mk * lineFade);
                albedo = mix(albedo, mown, inside);
            } else {
                float3 dirt = albedo * 0.82 + float3(0.01);
                float mk = max(band(az - (hw - 0.4), 0.15, aa), band(az, 0.12, aa) * step(0.5, fract(ax / 12.0)));
                dirt = mix(dirt, float3(0.85, 0.82, 0.75), mk * lineFade * 0.8);
                albedo = mix(albedo, dirt, inside);
            }
        }
    } else if (dot(N, V) < 0.0) {
        N = -N;
    }

    float ndl = max(dot(N, L), 0.0);
    if (material == 5) ndl = saturate((dot(N, L) + 0.45) / 1.45);     // soft wrap lighting for foliage
    float2 s0 = shadowLookup(sh0, ss, f.shadow0, in.wp, 0.00003);
    float2 s1 = shadowLookup(sh1, ss, f.shadow1, in.wp, 0.0006);
    float shadow = s0.y > 0.5 ? s0.x : (s1.y > 0.5 ? s1.x : 1.0);
    if (material == 2) {
        // photo-site shadow catcher: only darkens the panorama behind it
        return float4(0.0, 0.0, 0.0, (1.0 - shadow) * 0.6 * exp(-dist * 0.004));
    }
    if (material == 1) {
        // cloud shadows drifting over the landscape
        float cs = fbm(in.wp.xz * 0.0016 + f.camPos.w * 0.004);
        shadow *= 1.0 - 0.45 * f.runway.w * smoothstep(0.5, 0.72, cs);
    }
    float3 skyAmb = f.ambient.rgb;
    float3 gndAmb = skyAmb * float3(0.45, 0.42, 0.36);
    float3 amb = mix(gndAmb, skyAmb, N.y * 0.5 + 0.5);
    float3 col = albedo * (amb + f.sunColor.rgb * ndl * shadow);
    float gloss = material == 0 ? in.col.a * spec : 0.0;
    if (gloss > 0.0) {
        // glossy paint / film covering: sky reflection with Fresnel, plus a tight sun highlight
        float3 H = normalize(L + V);
        float ndh = max(dot(N, H), 0.0);
        float fres = 0.04 + 0.96 * pow(1.0 - max(dot(N, V), 0.0), 5.0);
        float3 R = reflect(-V, N);
        float3 env = R.y > 0.0 ? mix(f.horizon.rgb, f.zenith.rgb, pow(R.y, 0.5)) : mix(f.horizon.rgb, gndAmb * 1.2, saturate(-R.y * 4.0));
        col = mix(col, env, fres * gloss * 0.7);
        col += f.sunColor.rgb * (pow(ndh, 400.0) * 3.0 + pow(ndh, 50.0) * 0.22) * gloss * shadow * step(0.0, dot(N, L));
    }
    float fog = 1.0 - exp(-dist * f.sunColor.w);
    float sunAmt = pow(max(dot(-V, L), 0.0), 8.0);
    float3 fogCol = f.horizon.rgb + f.sunColor.rgb * sunAmt * 0.12;
    col = mix(col, fogCol, fog);
    return float4(tonemap(col), 1.0);
}

struct SkyOut { float4 pos [[position]]; float2 ndc; };

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
    return float4(c, 1.0);
}

vertex SkyOut skyVS(uint vid [[vertex_id]]) {
    SkyOut o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.ndc = p * 2.0 - 1.0;
    o.pos = float4(o.ndc, 0.0, 1.0);
    return o;
}

fragment float4 skyFS(SkyOut in [[stage_in]], constant Frame& f [[buffer(1)]]) {
    float4 w = f.invViewProj * float4(in.ndc, 0.5, 1.0);
    float3 d = normalize(w.xyz / w.w - f.camPos.xyz);
    float3 L = f.sunDir.xyz;
    float t = saturate(d.y);
    float3 c = mix(f.horizon.rgb, f.zenith.rgb, pow(t, 0.5));
    float sd = max(dot(d, L), 0.0);
    c += f.sunColor.rgb * (pow(sd, 8.0) * 0.12 + pow(sd, 120.0) * 0.35);
    if (d.y > 0.005) {
        float2 uv = d.xz / (d.y + 0.12) * 0.9 + float2(f.camPos.w * 0.006, f.camPos.w * 0.002);
        float n = fbm(uv * 1.1) * 0.65 + fbm(uv * 3.3 + 7.0) * 0.35;
        float cov = f.runway.w;
        float dens = smoothstep(0.78 - cov * 0.5, 1.0 - cov * 0.5, n);
        float shade = fbm(uv * 1.1 + L.xz * 0.12) * 0.65 + 0.35;
        float3 cloud = mix(f.sunColor.rgb * 0.5 + f.ambient.rgb * 0.9, f.ambient.rgb * 0.75, saturate((shade - 0.45) * 2.0) * dens);
        c = mix(c, cloud, dens * smoothstep(0.005, 0.16, d.y) * 0.92);
    }
    c += f.sunColor.rgb * pow(sd, 3000.0) * 12.0;
    c = mix(c, f.horizon.rgb * 0.8, smoothstep(0.0, -0.15, d.y));
    return float4(tonemap(c), 1.0);
}
"""
