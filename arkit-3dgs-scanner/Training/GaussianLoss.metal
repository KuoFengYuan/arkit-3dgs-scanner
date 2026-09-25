// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Photometric loss (L1 + D-SSIM) and PPISP photometric compensation, forward and backward.
//
// Loss: (1 - lambda) * L1(isp, gt) + lambda * (1 - SSIM) with an 11x11 Gaussian window
// (sigma 1.5), averaged over the image interior (5-pixel border excluded, as in LichtFeld
// Studio). With PPISP enabled, SSIM is decoupled like upstream: its luminance term compares the
// ISP output with the target, and contrast-structure compares the raw render with the target.
// The per-pixel error map for MRNF densification is max(0, 1 - mean_c cs_c).
//
// PPISP follows the published Physically-Plausible ISP model (nv-tlabs/ppisp, Apache-2.0):
// per-frame exposure and chromaticity homography, per-camera vignetting and camera response.
// This is an independent Metal implementation; see docs/ON_DEVICE_3DGS.md.
#include <metal_stdlib>
using namespace metal;

constant float kWindow[11] = {0.00102838f, 0.00759876f, 0.03600077f, 0.10936069f, 0.21300554f, 0.26601172f,
                              0.21300554f, 0.10936069f, 0.03600077f, 0.00759876f, 0.00102838f};
constant float kC1 = 0.0001f;   // (0.01)^2
constant float kC2 = 0.0009f;   // (0.03)^2

/// Mirrors `GaussianLossParams` in Swift.
struct LossParams {
    uint width, height, border, decoupled;   // decoupled: PPISP active
    float lambda, invInterior, unused0, unused1;
};

/// Per-frame ISP parameters, activated on the CPU. Mirrors `PPISPUniforms` in Swift.
struct PPISPParams {
    float4 exposure;          // x: EV (clamped), y: 2^EV, z: enabled (0/1), w: unused
    float4 vignetting[3];     // per channel: cx, cy, alpha0, alpha1
    float4 vignetting2;       // alpha2 per channel (xyz)
    float4 homography[3];     // rows of H (xyz)
    float4 crfTau, crfEta, crfGamma, crfCenter;   // per channel (xyz)
    float4 crfA;              // a per channel (xyz); b = 1 - a
};

inline float3 rgbOf(device const uchar4* image, uint p) { return float3(image[p].xyz) * (1.0f / 255.0f); }

inline bool interior(uint2 q, constant LossParams& lp) {
    return q.x >= lp.border && q.y >= lp.border && q.x + lp.border < lp.width && q.y + lp.border < lp.height;
}

// MARK: - PPISP

struct ISPStages {
    float3 x0, x1, x2, x3, out;
    float3 vignette, poly;
    float2 uv;
};

inline float3 crfForward(float3 x3, constant PPISPParams& P) {
    float3 out;
    for (uint c = 0; c < 3; ++c) {
        const float x = clamp(x3[c], 0.0f, 1.0f);
        const float center = P.crfCenter[c], tau = P.crfTau[c], eta = P.crfEta[c], a = P.crfA[c];
        float y;
        if (x <= center) y = a * pow(x / center, tau);
        else y = 1.0f - (1.0f - a) * pow((1.0f - x) / (1.0f - center), eta);
        out[c] = pow(max(y, 0.0f), P.crfGamma[c]);
    }
    return out;
}

inline ISPStages ispForward(float3 raw, uint2 q, uint width, uint height, constant PPISPParams& P) {
    ISPStages s;
    s.x0 = raw;
    s.x1 = raw * P.exposure.y;
    const float norm = 1.0f / float(max(width, height));
    s.uv = float2((float(q.x) + 0.5f - 0.5f * float(width)) * norm, (float(q.y) + 0.5f - 0.5f * float(height)) * norm);
    for (uint c = 0; c < 3; ++c) {
        const float2 d = s.uv - P.vignetting[c].xy;
        const float r2 = dot(d, d);
        const float poly = 1.0f + r2 * (P.vignetting[c].z + r2 * (P.vignetting[c].w + r2 * P.vignetting2[c]));
        s.poly[c] = poly;
        s.vignette[c] = clamp(poly, 0.0f, 1.0f);
    }
    s.x2 = s.x1 * s.vignette;
    const float3 pos = max(s.x2, 0.0f);
    const float intensity = pos.x + pos.y + pos.z;
    const float3 rgi = float3(pos.x, pos.y, intensity);
    const float3 hq = float3(dot(P.homography[0].xyz, rgi), dot(P.homography[1].xyz, rgi), dot(P.homography[2].xyz, rgi));
    const float k = intensity / (max(hq.z, 0.0f) + 1e-5f);
    const float3 o = k * hq;
    s.x3 = float3(o.x, o.y, o.z - o.x - o.y);
    s.out = crfForward(s.x3, P);
    return s;
}

/// ISP output of the raw render (identity copy when PPISP is disabled for this view).
kernel void ppisp_forward(device const float4* raw [[buffer(0)]],
                          device float4* output [[buffer(1)]],
                          constant PPISPParams& P [[buffer(2)]],
                          constant uint2& size [[buffer(3)]],
                          uint2 q [[thread_position_in_grid]]) {
    if (q.x >= size.x || q.y >= size.y) return;
    const uint p = q.y * size.x + q.x;
    const float4 r = raw[p];
    if (P.exposure.z < 0.5f) { output[p] = float4(r.xyz, r.w); return; }
    output[p] = float4(ispForward(r.xyz, q, size.x, size.y, P).out, r.w);
}

/// Parameter gradient slots accumulated by `ppisp_backward`:
/// [0] EV, [1..15] vignetting (per channel cx, cy, a0, a1, a2), [16..24] H row-major,
/// [25..36] CRF per channel (tau, eta, gamma, center) of the activated values.
constant uint kPPISPGradCount = 37;

/// dL/d(raw) += PPISP^T dL/d(isp); accumulates parameter gradients.
kernel void ppisp_backward(device const float4* raw [[buffer(0)]],
                           device const float4* ispGrad [[buffer(1)]],
                           device float4* rawGrad [[buffer(2)]],
                           device atomic_float* paramGrad [[buffer(3)]],
                           constant PPISPParams& P [[buffer(4)]],
                           constant uint2& size [[buffer(5)]],
                           uint2 q [[thread_position_in_grid]],
                           uint tid [[thread_index_in_threadgroup]],
                           uint lane [[thread_index_in_simdgroup]],
                           uint simd [[simdgroup_index_in_threadgroup]]) {
    const bool valid = q.x < size.x && q.y < size.y;
    const uint p = valid ? q.y * size.x + q.x : 0;
    float g[kPPISPGradCount];
    for (uint k = 0; k < kPPISPGradCount; ++k) g[k] = 0;
    if (valid) {
        const ISPStages s = ispForward(raw[p].xyz, q, size.x, size.y, P);
        const float3 g4 = ispGrad[p].xyz;
        // Camera response.
        float3 g3 = 0;
        for (uint c = 0; c < 3; ++c) {
            const float xin = s.x3[c];
            const float x = clamp(xin, 0.0f, 1.0f);
            const float center = P.crfCenter[c], tau = P.crfTau[c], eta = P.crfEta[c], gamma = P.crfGamma[c];
            const float a = P.crfA[c], b = 1.0f - a;
            float y, dydx, dyda, dydtau = 0, dydeta = 0, dydc;
            if (x <= center) {
                const float base = x / center;
                const float pw = base > 0 ? pow(base, tau) : 0.0f;
                y = a * pw;
                dydx = base > 0 ? a * tau * pow(base, tau - 1.0f) / center : 0.0f;
                dyda = pw;
                dydtau = base > 0 ? a * pw * log(base) : 0.0f;
                dydc = -dydx * base;
            } else {
                const float base = (1.0f - x) / (1.0f - center);
                const float pw = base > 0 ? pow(base, eta) : 0.0f;
                y = 1.0f - b * pw;
                dydx = base > 0 ? b * eta * pow(base, eta - 1.0f) / (1.0f - center) : 0.0f;
                dyda = pw;                                   // dy/db = -pw, db/da = -1
                dydeta = base > 0 ? -b * pw * log(base) : 0.0f;
                dydc = -dydx * base;                         // d base/dc = base / (1 - c)
            }
            const float yPos = max(y, 0.0f);
            const float out = pow(yPos, gamma);
            const float dOutdY = yPos > 0 ? gamma * pow(yPos, gamma - 1.0f) : 0.0f;
            const float dy = g4[c] * dOutdY;
            if (xin > 0.0f && xin < 1.0f) g3[c] = dy * dydx;
            // a depends on tau, eta and the centre: a = eta c / (tau + c (eta - tau)).
            const float L = tau + center * (eta - tau);
            const float daTau = -eta * center * (1.0f - center) / (L * L);
            const float daEta = center * tau * (1.0f - center) / (L * L);
            const float daC = eta * tau / (L * L);
            g[25 + 4 * c + 0] += dy * (dydtau + dyda * daTau);
            g[25 + 4 * c + 1] += dy * (dydeta + dyda * daEta);
            g[25 + 4 * c + 2] += yPos > 0 ? g4[c] * out * log(yPos) : 0.0f;
            g[25 + 4 * c + 3] += dy * (dydc + dyda * daC);
        }
        // Chromaticity homography.
        const float3 pos = max(s.x2, 0.0f);
        const float intensity = pos.x + pos.y + pos.z;
        const float3 rgi = float3(pos.x, pos.y, intensity);
        const float3 hq = float3(dot(P.homography[0].xyz, rgi), dot(P.homography[1].xyz, rgi), dot(P.homography[2].xyz, rgi));
        const float den = max(hq.z, 0.0f) + 1e-5f;
        const float k = intensity / den;
        const float3 go = float3(g3.x - g3.z, g3.y - g3.z, g3.z);
        const float dk = dot(go, hq);
        float3 dq = k * go;
        if (hq.z > 0) dq.z -= dk * k / den;
        const float dIntensity = dk / den;
        for (uint r = 0; r < 3; ++r) for (uint c = 0; c < 3; ++c) g[16 + 3 * r + c] += dq[r] * rgi[c];
        const float3 drgi = dq.x * P.homography[0].xyz + dq.y * P.homography[1].xyz + dq.z * P.homography[2].xyz;
        float3 g2 = float3(drgi.x + drgi.z, drgi.y + drgi.z, drgi.z) + dIntensity;
        g2 *= float3(s.x2 >= 0.0f);
        // Vignetting.
        const float3 g1 = g2 * s.vignette;
        for (uint c = 0; c < 3; ++c) {
            if (s.poly[c] < 0.0f || s.poly[c] > 1.0f) continue;
            const float2 d = s.uv - P.vignetting[c].xy;
            const float r2 = dot(d, d);
            const float base = g2[c] * s.x1[c];
            g[1 + 5 * c + 2] += base * r2;
            g[1 + 5 * c + 3] += base * r2 * r2;
            g[1 + 5 * c + 4] += base * r2 * r2 * r2;
            const float dr2 = base * (P.vignetting[c].z + 2.0f * P.vignetting[c].w * r2 + 3.0f * P.vignetting2[c] * r2 * r2);
            g[1 + 5 * c + 0] += -2.0f * d.x * dr2;
            g[1 + 5 * c + 1] += -2.0f * d.y * dr2;
        }
        // Exposure.
        if (abs(P.exposure.x) < 16.0f) g[0] += 0.69314718f * dot(g1, s.x1);
        rawGrad[p] += float4(g1 * P.exposure.y, 0);
    }
    // SIMD sums, then one device atomic per slot and threadgroup.
    threadgroup float partial[8][kPPISPGradCount];
    for (uint k = 0; k < kPPISPGradCount; ++k) {
        const float v = simd_sum(g[k]);
        if (lane == 0) partial[simd][k] = v;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < kPPISPGradCount) {
        float v = 0;
        for (uint s = 0; s < 8; ++s) v += partial[s][tid];
        if (v != 0) atomic_fetch_add_explicit(paramGrad + tid, v, memory_order_relaxed);
    }
}

// MARK: - SSIM (fused, 16x16 tiles with a 5-pixel apron in threadgroup memory)

constant int kApron = 5;
constant int kSpan = 26;            // 16 + 2 * 5

inline int2 clampPixel(int2 q, constant LossParams& lp) { return clamp(q, int2(0), int2(int(lp.width) - 1, int(lp.height) - 1)); }
inline bool inImage(int2 q, constant LossParams& lp) { return q.x >= 0 && q.y >= 0 && q.x < int(lp.width) && q.y < int(lp.height); }

/// Loss terms, SSIM map, error map and the SSIM partial derivatives (12 planes:
/// dL/d mean isp, dL/d mean raw, dL/d E[raw^2], dL/d E[raw * gt], each x 3 channels) in one
/// pass. Pixels outside the image count as zero (zero-padded window), which only matters for
/// the excluded border. `sums`: [L1 (interior), SSIM (interior), error (all), squared error (all)].
kernel void ssim_forward(device const float4* isp [[buffer(0)]],
                         device const float4* raw [[buffer(1)]],
                         device const uchar4* gt [[buffer(2)]],
                         device float* partials [[buffer(3)]],
                         device float* errorMap [[buffer(4)]],
                         device atomic_float* sums [[buffer(5)]],
                         constant LossParams& lp [[buffer(6)]],
                         uint2 group [[threadgroup_position_in_grid]],
                         uint2 local [[thread_position_in_threadgroup]],
                         uint tid [[thread_index_in_threadgroup]],
                         uint lane [[thread_index_in_simdgroup]],
                         uint simd [[simdgroup_index_in_threadgroup]]) {
    threadgroup float sI[kSpan * kSpan], sR[kSpan * kSpan], sG[kSpan * kSpan];
    threadgroup float sH[6][kSpan * 16];
    threadgroup float sSums[8][4];
    const int2 origin = int2(group * 16) - kApron;
    const int2 q = int2(group * 16 + local);
    const bool valid = inImage(q, lp);
    const uint P = lp.width * lp.height;
    const uint p = valid ? uint(q.y) * lp.width + uint(q.x) : 0;
    const bool inside = valid && interior(uint2(q), lp);
    const float dS = inside ? -lp.lambda * lp.invInterior / 3.0f : 0.0f;
    float ssim = 0, csMean = 0;
    for (uint c = 0; c < 3; ++c) {
        for (uint k = tid; k < uint(kSpan * kSpan); k += 256) {
            const int2 a = origin + int2(int(k) % kSpan, int(k) / kSpan);
            const bool ok = inImage(a, lp);
            const uint ap = ok ? uint(a.y) * lp.width + uint(a.x) : 0;
            sI[k] = ok ? isp[ap][c] : 0.0f;
            sR[k] = ok ? raw[ap][c] : 0.0f;
            sG[k] = ok ? float(gt[ap][c]) * (1.0f / 255.0f) : 0.0f;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint k = tid; k < uint(kSpan * 16); k += 256) {
            const uint row = k / 16, col = k % 16;
            float mi = 0, mr = 0, mg = 0, rr = 0, gg = 0, rg = 0;
            for (int t = 0; t < 11; ++t) {
                const uint a = row * kSpan + col + uint(t);
                const float w = kWindow[t], i = sI[a], r = sR[a], g = sG[a];
                mi += w * i; mr += w * r; mg += w * g; rr += w * r * r; gg += w * g * g; rg += w * r * g;
            }
            sH[0][k] = mi; sH[1][k] = mr; sH[2][k] = mg; sH[3][k] = rr; sH[4][k] = gg; sH[5][k] = rg;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        float s6[6] = {0, 0, 0, 0, 0, 0};
        for (int t = 0; t < 11; ++t) {
            const uint a = (local.y + uint(t)) * 16 + local.x;
            const float w = kWindow[t];
            for (uint j = 0; j < 6; ++j) s6[j] += w * sH[j][a];
        }
        const float mi = s6[0], mr = s6[1], mg = s6[2];
        const float varR = s6[3] - mr * mr, varG = s6[4] - mg * mg, cov = s6[5] - mr * mg;
        const float A1 = 2 * mi * mg + kC1, B1 = mi * mi + mg * mg + kC1;
        const float A2 = 2 * cov + kC2, B2 = varR + varG + kC2;
        const float l = A1 / B1, cs = A2 / B2;
        csMean += cs / 3.0f;
        if (inside) ssim += l * cs;
        if (valid) {
            partials[(0 + c) * P + p] = dS * cs * 2.0f * (mg - l * mi) / B1;
            partials[(3 + c) * P + p] = dS * l * (-2.0f * mg + 2.0f * cs * mr) / B2;
            partials[(6 + c) * P + p] = dS * l * (-cs / B2);
            partials[(9 + c) * P + p] = dS * l * (2.0f / B2);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float l1 = 0, err = 0, sq = 0;
    if (valid) {
        const float3 target = rgbOf(gt, p);
        const float3 d = isp[p].xyz - target;
        if (inside) l1 = abs(d.x) + abs(d.y) + abs(d.z);
        const float3 dc = clamp(isp[p].xyz, 0.0f, 1.0f) - target;
        sq = dot(dc, dc);
        err = max(0.0f, 1.0f - csMean);
        errorMap[p] = err;
    }
    const float4 v = float4(simd_sum(l1), simd_sum(ssim), simd_sum(err), simd_sum(sq));
    if (lane == 0) { sSums[simd][0] = v.x; sSums[simd][1] = v.y; sSums[simd][2] = v.z; sSums[simd][3] = v.w; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < 4) {
        float total = 0;
        for (uint s = 0; s < 8; ++s) total += sSums[s][tid];
        atomic_fetch_add_explicit(sums + tid, total, memory_order_relaxed);
    }
}

/// Blurs the partial-derivative planes (the symmetric window is its own adjoint) and forms the
/// image gradients: ispGrad = dL/d(isp) (L1 + SSIM luminance), rawGrad = dL/d(raw) from
/// contrast-structure. Without PPISP (`decoupled == 0`) both go to `rawGrad`.
kernel void ssim_backward(device const float* partials [[buffer(0)]],
                          device const float4* isp [[buffer(1)]],
                          device const float4* raw [[buffer(2)]],
                          device const uchar4* gt [[buffer(3)]],
                          device float4* ispGrad [[buffer(4)]],
                          device float4* rawGrad [[buffer(5)]],
                          constant LossParams& lp [[buffer(6)]],
                          uint2 group [[threadgroup_position_in_grid]],
                          uint2 local [[thread_position_in_threadgroup]],
                          uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float sP[4][kSpan * kSpan];
    threadgroup float sH[4][kSpan * 16];
    const int2 origin = int2(group * 16) - kApron;
    const int2 q = int2(group * 16 + local);
    const bool valid = inImage(q, lp);
    const uint P = lp.width * lp.height;
    const uint p = valid ? uint(q.y) * lp.width + uint(q.x) : 0;
    float3 gi = 0, gr = 0;
    const float3 r = valid ? raw[p].xyz : float3(0), g = valid ? rgbOf(gt, p) : float3(0);
    for (uint c = 0; c < 3; ++c) {
        for (uint k = tid; k < uint(kSpan * kSpan); k += 256) {
            const int2 a = origin + int2(int(k) % kSpan, int(k) / kSpan);
            const bool ok = inImage(a, lp);
            const uint ap = ok ? uint(a.y) * lp.width + uint(a.x) : 0;
            for (uint j = 0; j < 4; ++j) sP[j][k] = ok ? partials[(3 * j + c) * P + ap] : 0.0f;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint k = tid; k < uint(kSpan * 16); k += 256) {
            const uint row = k / 16, col = k % 16;
            float4 acc = 0;
            for (int t = 0; t < 11; ++t) {
                const uint a = row * kSpan + col + uint(t);
                acc += kWindow[t] * float4(sP[0][a], sP[1][a], sP[2][a], sP[3][a]);
            }
            sH[0][k] = acc.x; sH[1][k] = acc.y; sH[2][k] = acc.z; sH[3][k] = acc.w;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        float4 b = 0;
        for (int t = 0; t < 11; ++t) {
            const uint a = (local.y + uint(t)) * 16 + local.x;
            b += kWindow[t] * float4(sH[0][a], sH[1][a], sH[2][a], sH[3][a]);
        }
        gi[c] = b.x;
        gr[c] = b.y + 2.0f * r[c] * b.z + g[c] * b.w;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!valid) return;
    if (interior(uint2(q), lp)) gi += (1.0f - lp.lambda) * lp.invInterior / 3.0f * sign(isp[p].xyz - g);
    if (lp.decoupled != 0) { ispGrad[p] = float4(gi, 0); rawGrad[p] = float4(gr, 0); }
    else { ispGrad[p] = float4(0); rawGrad[p] = float4(gi + gr, 0); }
}

// MARK: - Image helpers

/// Edge map of a target image (grayscale, 5x5 Gaussian blur, Sobel magnitude, non-maximum
/// suppression); normalised by the median of positive values on the CPU.
kernel void edge_blur(device const uchar4* gt [[buffer(0)]],
                      device float* blurred [[buffer(1)]],
                      constant uint2& size [[buffer(2)]],
                      uint2 q [[thread_position_in_grid]]) {
    if (q.x >= size.x || q.y >= size.y) return;
    const float k5[5][5] = {{2, 4, 5, 4, 2}, {4, 9, 12, 9, 4}, {5, 12, 15, 12, 5}, {4, 9, 12, 9, 4}, {2, 4, 5, 4, 2}};
    float sum = 0;
    for (int dy = -2; dy <= 2; ++dy) for (int dx = -2; dx <= 2; ++dx) {
        const int x = clamp(int(q.x) + dx, 0, int(size.x) - 1), y = clamp(int(q.y) + dy, 0, int(size.y) - 1);
        const float3 c = float3(gt[uint(y) * size.x + uint(x)].xyz) * (1.0f / 255.0f);
        sum += k5[dy + 2][dx + 2] * dot(c, float3(0.299f, 0.587f, 0.114f));
    }
    blurred[q.y * size.x + q.x] = sum / 159.0f;
}

inline float edgeAt(device const float* blurred, uint2 size, int x, int y) {
    return blurred[uint(clamp(y, 0, int(size.y) - 1)) * size.x + uint(clamp(x, 0, int(size.x) - 1))];
}

inline float2 sobel(device const float* b, uint2 size, int x, int y) {
    const float gx = -edgeAt(b, size, x - 1, y - 1) - 2 * edgeAt(b, size, x - 1, y) - edgeAt(b, size, x - 1, y + 1)
                   + edgeAt(b, size, x + 1, y - 1) + 2 * edgeAt(b, size, x + 1, y) + edgeAt(b, size, x + 1, y + 1);
    const float gy = -edgeAt(b, size, x - 1, y - 1) - 2 * edgeAt(b, size, x, y - 1) - edgeAt(b, size, x + 1, y - 1)
                   + edgeAt(b, size, x - 1, y + 1) + 2 * edgeAt(b, size, x, y + 1) + edgeAt(b, size, x + 1, y + 1);
    return float2(gx, gy);
}

kernel void edge_sobel_nms(device const float* blurred [[buffer(0)]],
                           device float* edges [[buffer(1)]],
                           constant uint2& size [[buffer(2)]],
                           uint2 q [[thread_position_in_grid]]) {
    if (q.x >= size.x || q.y >= size.y) return;
    const int x = int(q.x), y = int(q.y);
    const float2 g = sobel(blurred, size, x, y);
    const float m = length(g);
    // Neighbours along the gradient direction rounded to 0/45/90/135 degrees.
    const int sector = int(round(atan2(g.y, g.x) / (M_PI_F / 4))) & 3;
    const int2 offsets[4] = {int2(1, 0), int2(1, 1), int2(0, 1), int2(-1, 1)};
    const int2 o = offsets[sector];
    const float a = length(sobel(blurred, size, x + o.x, y + o.y)), b = length(sobel(blurred, size, x - o.x, y - o.y));
    edges[q.y * size.x + q.x] = (m >= a && m >= b) ? m : 0.0f;
}

kernel void scale_float(device float* values [[buffer(0)]], constant float2& scaleCount [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    if (i < uint(scaleCount.y)) values[i] *= scaleCount.x;
}

/// Display conversion of a float render (rgb in [0, 1]) to RGBA8.
kernel void image_to_rgba8(device const float4* image [[buffer(0)]],
                           device uchar4* output [[buffer(1)]],
                           constant uint2& size [[buffer(2)]],
                           uint2 q [[thread_position_in_grid]]) {
    if (q.x >= size.x || q.y >= size.y) return;
    const uint p = q.y * size.x + q.x;
    output[p] = uchar4(uchar3(round(clamp(image[p].xyz, 0.0f, 1.0f) * 255.0f)), 255);
}
