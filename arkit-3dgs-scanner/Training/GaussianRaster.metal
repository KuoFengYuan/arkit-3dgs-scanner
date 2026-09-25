// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Kuo Feng-Yuan (KuoFengYuan). On-device 3DGS training; see LICENSE and NOTICE.
// Differentiable tile rasterizer for 3D Gaussian splatting.
//
// Independent Metal implementation of the standard EWA-splatting forward and backward passes
// (Kerbl et al. 2023) with the Mip-Splatting 2D filter (Yu et al. 2024), following the
// conventions of LichtFeld Studio's fastgs path: pinhole OpenCV camera (x right, y down,
// z forward), pixel centres at +0.5, 16x16 tiles, alpha <= 0.999, alpha threshold 1/255 and
// transmittance cut-off 1e-4. No upstream source is copied; see docs/ON_DEVICE_3DGS.md.
#include <metal_stdlib>
using namespace metal;

constant uint kTile = 16;
constant uint kTileThreads = kTile * kTile;
constant float kAlphaMin = 1.0f / 255.0f;
constant float kAlphaMax = 0.999f;
constant float kTransmittanceMin = 1e-4f;

/// Mirrors `GaussianCamera` in Swift (all 16-byte fields, 160 bytes).
struct CameraParams {
    float4 r0, r1, r2;       // world-to-camera rows [R | t]
    float4 intrinsics;       // fx, fy, cx, cy
    float4 center;           // camera centre in world coordinates
    float4 misc;             // near plane, 2D filter variance (px^2), mip compensation (0/1), unused
    uint4 dims;              // width, height, tilesX, tilesY
    uint4 sh;                // active SH degree, coefficients per Gaussian, Gaussian count, unused
    // Capture motion (zero for novel views): camera-frame linear velocity (m/s) and exposure
    // time (s); camera-frame angular velocity (rad/s) and rolling-shutter readout time (s,
    // first row to last row).
    float4 linearMotion;
    float4 angularMotion;
};

/// Parameter blocks of the flat model buffer (offsets in floats, capacity-strided).
struct ModelLayout {
    uint means, scales, quats, opacities, sh0, shN, capacity, shRest;
};

inline float sigmoid(float x) { return 1.0f / (1.0f + exp(-x)); }

inline float3x3 outer(float3 a, float3 b) { return float3x3(a * b.x, a * b.y, a * b.z); }

inline float3 load3(device const float* base, uint i) { return float3(base[3 * i], base[3 * i + 1], base[3 * i + 2]); }

inline float3x3 quatToMatrix(float4 q) {
    // q = (w, x, y, z), normalised.
    const float w = q.x, x = q.y, y = q.z, z = q.w;
    // Metal matrices are column-major: columns listed below.
    return float3x3(float3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
                    float3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
                    float3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)));
}

inline float3x3 worldRotation(constant CameraParams& cam) {
    // Columns of R from its rows.
    return float3x3(float3(cam.r0.x, cam.r1.x, cam.r2.x),
                    float3(cam.r0.y, cam.r1.y, cam.r2.y),
                    float3(cam.r0.z, cam.r1.z, cam.r2.z));
}

// Real SH basis (degree <= 3) with the constants of the reference 3DGS implementation.
constant float SH_C0 = 0.28209479177387814f;
constant float SH_C1 = 0.4886025119029199f;
constant float SH_C2[5] = {1.0925484305920792f, -1.0925484305920792f, 0.31539156525252005f,
                           -1.0925484305920792f, 0.5462742152960396f};
constant float SH_C3[7] = {-0.5900435899266435f, 2.890611442640554f, -0.4570457994644658f,
                           0.3731763325901154f, -0.4570457994644658f, 1.445305721320277f,
                           -0.5900435899266435f};

inline void shBasis(float3 d, uint degree, thread float* b) {
    b[0] = SH_C0;
    if (degree < 1) return;
    const float x = d.x, y = d.y, z = d.z;
    b[1] = -SH_C1 * y; b[2] = SH_C1 * z; b[3] = -SH_C1 * x;
    if (degree < 2) return;
    const float xx = x * x, yy = y * y, zz = z * z, xy = x * y, yz = y * z, xz = x * z;
    b[4] = SH_C2[0] * xy; b[5] = SH_C2[1] * yz; b[6] = SH_C2[2] * (2 * zz - xx - yy);
    b[7] = SH_C2[3] * xz; b[8] = SH_C2[4] * (xx - yy);
    if (degree < 3) return;
    b[9] = SH_C3[0] * y * (3 * xx - yy); b[10] = SH_C3[1] * xy * z; b[11] = SH_C3[2] * y * (4 * zz - xx - yy);
    b[12] = SH_C3[3] * z * (2 * zz - 3 * xx - 3 * yy); b[13] = SH_C3[4] * x * (4 * zz - xx - yy);
    b[14] = SH_C3[5] * z * (xx - yy); b[15] = SH_C3[6] * x * (xx - 3 * yy);
}

/// d(sum_k b_k(d) * g_k)/d(d) for the unnormalised gradient weights g_k (per basis function).
inline float3 shBasisGradient(float3 d, uint degree, thread const float* g) {
    float3 out = 0;
    if (degree < 1) return out;
    const float x = d.x, y = d.y, z = d.z;
    out += float3(-SH_C1 * g[3], -SH_C1 * g[1], SH_C1 * g[2]);
    if (degree < 2) return out;
    const float xx = x * x, yy = y * y, zz = z * z;
    out.x += SH_C2[0] * y * g[4] + SH_C2[2] * (-2 * x) * g[6] + SH_C2[3] * z * g[7] + SH_C2[4] * 2 * x * g[8];
    out.y += SH_C2[0] * x * g[4] + SH_C2[1] * z * g[5] + SH_C2[2] * (-2 * y) * g[6] + SH_C2[4] * (-2 * y) * g[8];
    out.z += SH_C2[1] * y * g[5] + SH_C2[2] * 4 * z * g[6] + SH_C2[3] * x * g[7];
    if (degree < 3) return out;
    out.x += SH_C3[0] * y * 6 * x * g[9] + SH_C3[1] * y * z * g[10] + SH_C3[2] * y * (-2 * x) * g[11]
           + SH_C3[3] * z * (-6 * x) * g[12] + SH_C3[4] * (4 * zz - 3 * xx - yy) * g[13]
           + SH_C3[5] * z * 2 * x * g[14] + SH_C3[6] * (3 * xx - 3 * yy) * g[15];
    out.y += SH_C3[0] * (3 * xx - 3 * yy) * g[9] + SH_C3[1] * x * z * g[10] + SH_C3[2] * (4 * zz - xx - 3 * yy) * g[11]
           + SH_C3[3] * z * (-6 * y) * g[12] + SH_C3[4] * x * (-2 * y) * g[13]
           + SH_C3[5] * z * (-2 * y) * g[14] + SH_C3[6] * x * (-6 * y) * g[15];
    out.z += SH_C3[1] * x * y * g[10] + SH_C3[2] * y * 8 * z * g[11] + SH_C3[3] * (6 * zz - 3 * xx - 3 * yy) * g[12]
           + SH_C3[4] * x * 8 * z * g[13] + SH_C3[5] * (xx - yy) * g[14];
    return out;
}

struct Projected {
    float3 camera;       // camera-space centre
    float2 pixel;        // projected centre (rolling-shutter corrected)
    float3 cov2d;        // raw 2D covariance (a, b, c)
    float3 cov2dFiltered; // rendered covariance: + 2D filter + motion blur
    float3 cov2dBase;    // numerator of the opacity compensation (raw or dilated)
    float det, detFiltered, detBase, rho;
    bool compensated;
    float2 limits;       // clamped x/z, y/z ratios
    bool2 clamped;
    float3x3 cov3d;
};

/// Screen velocity (px/s) of a camera-space centre under the capture motion, u' = J (w x p + v),
/// with J at the frustum-clamped ratios (like the covariance) and the speed capped so the
/// rolling-shutter shift and the blur stay within 5% of the image: first-order motion is not
/// valid for splats far off-axis or next to the camera, which would otherwise be thrown across
/// the view.
inline float2 pixelVelocity(constant CameraParams& cam, float3 camera, float2 limits) {
    const float fx = cam.intrinsics.x, fy = cam.intrinsics.y, z = camera.z;
    const float3 pdot = cross(cam.angularMotion.xyz, camera) + cam.linearMotion.xyz;
    float2 udot = float2(fx * (pdot.x - limits.x * pdot.z) / z, fy * (pdot.y - limits.y * pdot.z) / z);
    const float span = max(fabs(cam.angularMotion.w), cam.linearMotion.w);
    const float limit = 0.05f * float(max(cam.dims.x, cam.dims.y)) / max(span, 1e-6f);
    const float speed = length(udot);
    if (speed > limit) udot *= limit / speed;
    return udot;
}

/// Projects one Gaussian. Returns false when it is behind the near plane or degenerate.
inline bool projectGaussian(constant CameraParams& cam, float3 mean, float3 logScale, float4 quat,
                            thread Projected& p) {
    const float3x3 W = worldRotation(cam);
    const float3 t = float3(cam.r0.w, cam.r1.w, cam.r2.w);
    p.camera = W * mean + t;
    if (p.camera.z < cam.misc.x) return false;
    const float qn = dot(quat, quat);
    if (qn < 1e-8f) return false;
    const float3x3 R = quatToMatrix(quat * rsqrt(qn));
    const float3 s = exp(min(logScale, 20.0f));
    const float3x3 M = float3x3(R[0] * s.x, R[1] * s.y, R[2] * s.z);
    p.cov3d = M * transpose(M);
    const float fx = cam.intrinsics.x, fy = cam.intrinsics.y, cx = cam.intrinsics.z, cy = cam.intrinsics.w;
    const float W_ = float(cam.dims.x), H_ = float(cam.dims.y);
    const float z = p.camera.z;
    const float rx = p.camera.x / z, ry = p.camera.y / z;
    const float limXLo = (-0.15f * W_ - cx) / fx, limXHi = (1.15f * W_ - cx) / fx;
    const float limYLo = (-0.15f * H_ - cy) / fy, limYHi = (1.15f * H_ - cy) / fy;
    p.limits = float2(clamp(rx, limXLo, limXHi), clamp(ry, limYLo, limYHi));
    p.clamped = bool2(rx < limXLo || rx > limXHi, ry < limYLo || ry > limYHi);
    // J (2x3) rows; T = J * W.
    const float3 j0 = float3(fx / z, 0, -fx * p.limits.x / z);
    const float3 j1 = float3(0, fy / z, -fy * p.limits.y / z);
    const float3x3 Wt = transpose(W);
    const float3 T0 = Wt * j0, T1 = Wt * j1;       // rows of T = J W
    const float3 S0 = p.cov3d * T0, S1 = p.cov3d * T1;
    p.cov2d = float3(dot(T0, S0), dot(T0, S1), dot(T1, S1));
    const float k = cam.misc.y;
    const bool mip = cam.misc.z > 0.5f;
    const float3 dilated = float3(p.cov2d.x + k, p.cov2d.y, p.cov2d.z + k);
    p.pixel = float2(fx * rx + cx, fy * ry + cy);
    // Capture motion (Seiskari et al. 2024, screen-space approximation): the centre's pixel
    // velocity u' = J (w x p + v) shifts it to the time its row was read (rolling shutter) and
    // spreads it over the exposure (box blur, variance (u' T)^2 / 12). Velocities are
    // treated as constants in the backward pass.
    float3 blur = 0;
    const float exposure = cam.linearMotion.w, readout = cam.angularMotion.w;
    if (exposure > 0 || readout != 0) {
        const float2 udot = pixelVelocity(cam, p.camera, p.limits);
        if (readout != 0) {
            // Solve y = y0 + u'_y * t(y), t(y) = (y / H - 0.5) * readout.
            const float denom = max(1.0f - udot.y * readout / H_, 0.5f);
            const float y = (p.pixel.y - 0.5f * udot.y * readout) / denom;
            const float tau = clamp((y / H_ - 0.5f) * readout, -fabs(readout), fabs(readout));
            p.pixel += udot * tau;
        }
        if (exposure > 0) {
            const float2 b = udot * exposure;
            blur = float3(b.x * b.x, b.x * b.y, b.y * b.y) * (1.0f / 12.0f);
        }
    }
    p.cov2dFiltered = dilated + blur;
    p.cov2dBase = mip ? p.cov2d : dilated;
    p.det = max(p.cov2d.x * p.cov2d.z - p.cov2d.y * p.cov2d.y, 0.0f);
    p.detBase = max(p.cov2dBase.x * p.cov2dBase.z - p.cov2dBase.y * p.cov2dBase.y, 0.0f);
    p.detFiltered = p.cov2dFiltered.x * p.cov2dFiltered.z - p.cov2dFiltered.y * p.cov2dFiltered.y;
    if (p.detFiltered < 1e-6f) return false;
    // Opacity compensation keeps each splat's integral: the mip filter's and the blur's.
    p.compensated = mip || blur.x + blur.z > 0;
    p.rho = p.compensated ? sqrt(p.detBase / p.detFiltered) : 1.0f;
    return true;
}

/// Tile columns [x, y) of tile row `ty` that a splat reaches: the ellipse of pixels where its
/// alpha is at least 1/255, d^T Sigma^-1 d <= 2 ln(255 opacity) (`conic` = Sigma^-1 and the
/// opacity), cut by the row's band of pixel centres and clipped to its bounding box [x0, x1).
/// The box alone also lists the tiles its corners cross, which a rotated or elongated splat
/// never touches; they would be sorted and blended for nothing. Within the band the ellipse's
/// right edge is concave in dy (its maximum is the ellipse's rightmost point, clamped to the
/// band) and its left edge convex, so each row costs O(1).
inline int2 tileRowSpan(float2 centre, float4 conic, int ty, int x0, int x1) {
    const float A = conic.x, B = conic.y, C = conic.z;
    const float det = A * C - B * B;
    if (!(det > 0) || !(conic.w > 0)) return int2(x0, x1);
    // Covariance and the threshold, with a small margin so rounding never drops a pixel.
    const float sxx = C / det, sxy = -B / det, syy = A / det;
    const float r = 2.0f * log(255.0f * conic.w) * 1.001f + 1e-3f;
    if (!(r > 0)) return int2(x0, x0);
    const float ymax = sqrt(r * syy);
    const float lo = max(float(ty) * float(kTile) + 0.5f - centre.y, -ymax);
    const float hi = min(float(ty) * float(kTile) + float(kTile) - 0.5f - centre.y, ymax);
    if (lo > hi) return int2(x0, x0);
    // x(dy) = k dy +- sqrt(Sigma_x|y (r - dy^2 / Sigma_yy)); the rightmost point is at dy_R.
    const float k = sxy / syy, conditional = max(sxx - sxy * k, 0.0f);
    const float dyR = sxy * sqrt(r / sxx);
    const float dR = clamp(dyR, lo, hi), dL = clamp(-dyR, lo, hi);
    const float right = centre.x + k * dR + sqrt(max(0.0f, conditional * (r - dR * dR / syy)));
    const float left = centre.x + k * dL - sqrt(max(0.0f, conditional * (r - dL * dL / syy)));
    // Tile tx holds pixel centres 16 tx + 0.5 ... 16 tx + 15.5.
    const int first = max(x0, int(ceil((left - float(kTile) + 0.5f) / float(kTile))));
    const int last = min(x1, int(floor((right - 0.5f) / float(kTile))) + 1);
    return int2(first, max(first, last));
}

/// Projection, 2D filter, SH colour and tile extent per Gaussian.
kernel void project_forward(constant CameraParams& cam [[buffer(0)]],
                            constant ModelLayout& layout [[buffer(1)]],
                            device const float* model [[buffer(2)]],
                            device float2* outPixel [[buffer(3)]],
                            device float4* outConic [[buffer(4)]],        // conic (A, B, C), effective opacity
                            device float4* outColor [[buffer(5)]],        // rgb, camera depth
                            device uint* outTiles [[buffer(6)]],          // number of tiles touched
                            device uint4* outRect [[buffer(7)]],          // tile rect [x0, y0, x1, y1)
                            device uint* outDepthKey [[buffer(8)]],
                            uint i [[thread_position_in_grid]]) {
    if (i >= cam.sh.z) return;
    outTiles[i] = 0;
    outRect[i] = uint4(0);
    outDepthKey[i] = 0xFFFFFFFFu;
    outConic[i] = float4(0);
    const float3 mean = load3(model + layout.means, i);
    const float3 logScale = load3(model + layout.scales, i);
    const float4 quat = float4(model[layout.quats + 4 * i], model[layout.quats + 4 * i + 1],
                               model[layout.quats + 4 * i + 2], model[layout.quats + 4 * i + 3]);
    Projected p;
    if (!projectGaussian(cam, mean, logScale, quat, p)) return;
    const float opacity = sigmoid(model[layout.opacities + i]) * p.rho;
    if (opacity < kAlphaMin) return;
    const float3 c = p.cov2dFiltered;
    const float power = log(255.0f * opacity);
    const float2 extent = sqrt(2.0f * power * float2(c.x, c.z));
    const float2 lo = (p.pixel - extent) / float(kTile), hi = (p.pixel + extent) / float(kTile);
    const int x0 = max(int(floor(lo.x)), 0), y0 = max(int(floor(lo.y)), 0);
    const int x1 = min(int(floor(hi.x)) + 1, int(cam.dims.z)), y1 = min(int(floor(hi.y)) + 1, int(cam.dims.w));
    if (x1 <= x0 || y1 <= y0) return;
    const float inv = 1.0f / p.detFiltered;
    const float4 conic = float4(c.z * inv, -c.y * inv, c.x * inv, opacity);
    uint touched = 0;
    for (int ty = y0; ty < y1; ++ty) {
        const int2 span = tileRowSpan(p.pixel, conic, ty, x0, x1);
        touched += uint(span.y - span.x);
    }
    if (touched == 0) return;
    outConic[i] = conic;
    outPixel[i] = p.pixel;
    // View-dependent colour.
    const float3 dir = normalize(mean - cam.center.xyz);
    float basis[16];
    const uint degree = cam.sh.x, rest = cam.sh.y - 1;
    shBasis(dir, degree, basis);
    float3 rgb = basis[0] * load3(model + layout.sh0, i);
    const uint count = (degree + 1) * (degree + 1);
    for (uint k = 1; k < count; ++k) rgb += basis[k] * load3(model + layout.shN + i * rest * 3, k - 1);
    rgb += 0.5f;
    outColor[i] = float4(max(rgb, 0.0f), p.camera.z);
    outTiles[i] = touched;
    outRect[i] = uint4(x0, y0, x1, y1);
    outDepthKey[i] = as_type<uint>(p.camera.z);
}

/// Tile key that sorts after every real tile and is never blended (see `emit_intersections`).
constant uint kUnusedTile = 0xFFFFu;

/// Writes (tile id, Gaussian id) pairs in depth order; `order` lists Gaussians by depth and
/// `offsets` is the exclusive scan of their tile counts in that order. Each Gaussian writes
/// exactly the `tiles` entries `project_forward` counted: the row spans are recomputed here,
/// and should rounding ever give fewer, the rest are `kUnusedTile` entries no tile reads.
kernel void emit_intersections(device const uint* order [[buffer(0)]],
                               device const uint* offsets [[buffer(1)]],
                               device const uint4* rects [[buffer(2)]],
                               device const uint* tiles [[buffer(3)]],
                               device uint* keys [[buffer(4)]],
                               device uint* values [[buffer(5)]],
                               constant uint4& info [[buffer(6)]],      // count, tilesX, capacity
                               device const float2* pixels [[buffer(7)]],
                               device const float4* conics [[buffer(8)]],
                               uint k [[thread_position_in_grid]]) {
    if (k >= info.x) return;
    const uint g = order[k];
    const uint n = tiles[g];
    if (n == 0) return;
    const uint4 r = rects[g];
    const float2 centre = pixels[g];
    const float4 conic = conics[g];
    uint offset = offsets[k];
    const uint end = min(offset + n, info.z);
    for (uint y = r.y; y < r.w && offset < end; ++y) {
        const int2 span = tileRowSpan(centre, conic, int(y), int(r.x), int(r.z));
        for (int x = span.x; x < span.y && offset < end; ++x) {
            keys[offset] = y * info.y + uint(x);
            values[offset] = g;
            ++offset;
        }
    }
    for (; offset < end; ++offset) { keys[offset] = kUnusedTile; values[offset] = g; }
}

kernel void clear_uint2(device uint2* values [[buffer(0)]], constant uint& count [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    if (i < count) values[i] = uint2(0);
}

kernel void clear_float(device float* values [[buffer(0)]], constant uint& count [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    if (i < count) values[i] = 0;
}

/// Start/end of each tile's run in the tile-sorted intersection list. Start and end of one
/// tile are written by different threads, so they are stored as separate scalars (a vector
/// component store may rewrite the whole vector).
kernel void tile_ranges(device const uint* keys [[buffer(0)]],
                        device uint* ranges [[buffer(1)]],
                        constant uint& count [[buffer(2)]],
                        uint i [[thread_position_in_grid]]) {
    if (i >= count) return;
    const uint tile = keys[i];
    if (tile == kUnusedTile) return;
    if (i == 0 || keys[i - 1] != tile) ranges[2 * tile] = i;
    if (i == count - 1 || keys[i + 1] != tile) ranges[2 * tile + 1] = i + 1;
}

/// Front-to-back alpha blending per 16x16 tile. Stores the colour, final transmittance and the
/// number of list entries each pixel consumed, which the backward pass replays in reverse.
kernel void rasterize_forward(constant CameraParams& cam [[buffer(0)]],
                              device const uint2* ranges [[buffer(1)]],
                              device const uint* ids [[buffer(2)]],
                              device const float2* pixels [[buffer(3)]],
                              device const float4* conics [[buffer(4)]],
                              device const float4* colors [[buffer(5)]],
                              device float4* image [[buffer(6)]],          // rgb, final transmittance
                              device uint* lastIndex [[buffer(7)]],
                              constant float4& background [[buffer(8)]],
                              device float* depthImage [[buffer(9)]],      // expected camera depth (unnormalised)
                              uint2 tile [[threadgroup_position_in_grid]],
                              uint2 local [[thread_position_in_threadgroup]],
                              uint tid [[thread_index_in_threadgroup]],
                              uint simd [[simdgroup_index_in_threadgroup]]) {
    threadgroup float2 sPixel[kTileThreads];
    threadgroup float4 sConic[kTileThreads];
    threadgroup float4 sColor[kTileThreads];
    threadgroup bool sDone[kTileThreads / 32];
    const uint W = cam.dims.x, H = cam.dims.y;
    const uint2 pixel = tile * kTile + local;
    const bool inside = pixel.x < W && pixel.y < H;
    const float2 centre = float2(pixel) + 0.5f;
    const uint2 range = ranges[tile.y * cam.dims.z + tile.x];
    float T = 1.0f;
    float3 C = 0;
    float D = 0;
    uint last = range.x;
    bool done = !inside;
    for (uint batch = range.x; batch < range.y; batch += kTileThreads) {
        const bool simdDone = simd_all(done);
        if (tid % 32 == 0) sDone[simd] = simdDone;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        bool allDone = true;
        for (uint s = 0; s < kTileThreads / 32; ++s) allDone = allDone && sDone[s];
        if (allDone) break;
        const uint index = batch + tid;
        if (index < range.y) {
            const uint g = ids[index];
            sPixel[tid] = pixels[g];
            sConic[tid] = conics[g];
            sColor[tid] = colors[g];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const uint n = min(kTileThreads, range.y - batch);
        for (uint j = 0; j < n && !done; ++j) {
            const float4 co = sConic[j];
            const float2 d = sPixel[j] - centre;
            const float power = -0.5f * (co.x * d.x * d.x + co.z * d.y * d.y) - co.y * d.x * d.y;
            if (power > 0) continue;
            const float alpha = min(kAlphaMax, co.w * exp(power));
            if (alpha < kAlphaMin) continue;
            const float next = T * (1 - alpha);
            if (next < kTransmittanceMin) { done = true; break; }
            const float w = alpha * T;
            C += sColor[j].xyz * w;
            D += sColor[j].w * w;
            T = next;
            last = batch + j + 1;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (!inside) return;
    const uint p = pixel.y * W + pixel.x;
    image[p] = float4(C + T * background.xyz, T);
    lastIndex[p] = last;
    depthImage[p] = D;
}

/// Per-Gaussian values accumulated by `rasterize_backward` (atomic floats):
/// [dx, dy, dA, dB, dC, dOpacity, dR, dG, dB, sum w, sum w*error, sum w*edge], where w is the
/// blending weight T*alpha. The last three drive MRNF's error- and edge-guided densification.
constant uint kGrad2DStride = 13;   // mirrors GaussianRasterizer.grad2DStride

/// One step of `simdSum16`: a lane keeps `W` of its 2W values, adding its partner's copies.
template <uint W>
inline void simdHalve(thread float* v, uint lane) {
    const bool upper = (lane & (2 * W)) != 0;
    for (uint i = 0; i < W; ++i) {
        const float send = upper ? v[i] : v[i + W];
        const float keep = upper ? v[i + W] : v[i];
        v[i] = keep + simd_shuffle_xor(send, ushort(2 * W));
    }
}

/// Sums 16 values over a 32-lane SIMD group with 16 shuffles instead of 16 `simd_sum` calls
/// (80): each step halves the values a lane keeps and swaps the other half with its partner.
/// Returns, in lanes 2k and 2k + 1, the total of value k. `v` is overwritten.
inline float simdSum16(thread float* v, uint lane) {
    simdHalve<8>(v, lane);
    simdHalve<4>(v, lane);
    simdHalve<2>(v, lane);
    simdHalve<1>(v, lane);
    return v[0] + simd_shuffle_xor(v[0], ushort(1));
}

/// Reverse replay of the blend. `imageGrad` holds dL/d(rgb) of the raw render; `pixelError`
/// is the normalised per-pixel error map and `edges` the edge map of the target image.
kernel void rasterize_backward(constant CameraParams& cam [[buffer(0)]],
                               device const uint2* ranges [[buffer(1)]],
                               device const uint* ids [[buffer(2)]],
                               device const float2* pixels [[buffer(3)]],
                               device const float4* conics [[buffer(4)]],
                               device const float4* colors [[buffer(5)]],
                               device const float4* image [[buffer(6)]],
                               device const uint* lastIndex [[buffer(7)]],
                               constant float4& background [[buffer(8)]],
                               device const float4* imageGrad [[buffer(9)]],
                               device atomic_float* grad2d [[buffer(10)]],
                               device const float* pixelError [[buffer(11)]],
                               device const float* edges [[buffer(12)]],
                               device const float* lossSums [[buffer(13)]],  // [2] = sum of the error map
                               device const float* lidar [[buffer(14)]],     // LiDAR depth (m), 0 = unusable
                               constant float4& depthLoss [[buffer(15)]],    // weight per pixel, width, height, on
                               constant uint& tileRowOffset [[buffer(16)]],  // first tile row of this band
                               uint2 groupTile [[threadgroup_position_in_grid]],
                               uint2 local [[thread_position_in_threadgroup]],
                               uint tid [[thread_index_in_threadgroup]],
                               uint lane [[thread_index_in_simdgroup]],
                               uint simd [[simdgroup_index_in_threadgroup]]) {
    // Batches of 64 Gaussians. Each SIMD group sums its 32 pixels' values for a Gaussian with
    // `simdSum16` and adds them to device memory with one atomic per value. Summing the 8 SIMD
    // groups in threadgroup memory first (26 KB) was slower: it left room for one threadgroup
    // per GPU core. Batches of 128 or 256 were no faster.
    constexpr uint kBatch = 64;
    // Large images are replayed in bands of tile rows, one command buffer each, so no single
    // command buffer runs long enough for the GPU watchdog to abort it.
    const uint2 tile = uint2(groupTile.x, groupTile.y + tileRowOffset);
    if (tile.y >= cam.dims.w) return;
    threadgroup float2 sPixel[kBatch];
    threadgroup float4 sConic[kBatch];
    threadgroup float4 sColor[kBatch];
    threadgroup uint sId[kBatch];
    threadgroup uint sLast[kTileThreads / 32];
    const uint W = cam.dims.x, H = cam.dims.y;
    const uint2 pixel = tile * kTile + local;
    const bool inside = pixel.x < W && pixel.y < H;
    const float2 centre = float2(pixel) + 0.5f;
    const uint2 range = ranges[tile.y * cam.dims.z + tile.x];
    const uint p = inside ? pixel.y * W + pixel.x : 0;
    const float4 out = inside ? image[p] : float4(0);
    float T = out.w;
    const uint last = inside ? lastIndex[p] : range.x;
    const float3 dC = inside ? imageGrad[p].xyz : float3(0);
    // Error map normalised to mean 1 (unnormalised when the mean is ~0).
    const float errorMean = lossSums[2] / float(W * H);
    const float errorScale = errorMean > 1e-6f ? 1.0f / errorMean : 1.0f;
    const float error = inside ? pixelError[p] * errorScale : 0.0f;
    const float edge = inside ? edges[p] : 0.0f;
    // Colour of everything behind the current splat, including the background.
    float3 behind = T * background.xyz;
    // Depth loss sum_i w_i |z_i - z_lidar| / z_lidar: every contributing splat is pulled to the
    // measured surface (floaters in front and behind do not cancel). `behindE` is its suffix.
    float depthWeight = 0, lidarZ = 0, behindE = 0;
    if (inside && depthLoss.w > 0.5f) {
        const uint lw = uint(depthLoss.y), lh = uint(depthLoss.z);
        const uint lx = min(lw - 1, uint(centre.x * float(lw) / float(W))), ly = min(lh - 1, uint(centre.y * float(lh) / float(H)));
        lidarZ = lidar[ly * lw + lx];
        if (lidarZ > 0) depthWeight = depthLoss.x / lidarZ;
    }
    // Only replay up to the deepest entry any pixel of the tile consumed.
    const uint simdLast = simd_max(last);
    if (lane == 0) sLast[simd] = simdLast;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint end = range.x;
    for (uint s = 0; s < kTileThreads / 32; ++s) end = max(end, sLast[s]);
    if (end <= range.x) return;
    const uint batches = (end - range.x + kBatch - 1) / kBatch;
    for (uint b = 0; b < batches; ++b) {
        const uint batchEnd = end - b * kBatch;
        const uint batchStart = batchEnd > range.x + kBatch ? batchEnd - kBatch : range.x;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const uint index = batchStart + tid;
        if (tid < kBatch && index < batchEnd) {
            const uint g = ids[index];
            sId[tid] = g;
            sPixel[tid] = pixels[g];
            sConic[tid] = conics[g];
            sColor[tid] = colors[g];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const int n = int(batchEnd - batchStart);
        for (int j = n - 1; j >= 0; --j) {
            const uint listIndex = batchStart + uint(j);
            bool active = inside && listIndex < last;
            float alpha = 0, G = 0;
            float2 d = 0;
            const float4 co = sConic[j];
            if (active) {
                d = sPixel[j] - centre;
                const float power = -0.5f * (co.x * d.x * d.x + co.z * d.y * d.y) - co.y * d.x * d.y;
                G = exp(power);
                alpha = min(kAlphaMax, co.w * G);
                active = power <= 0 && alpha >= kAlphaMin;
            }
            if (!simd_any(active)) continue;
            float v[16];
            for (uint k = 0; k < 16; ++k) v[k] = 0;
            if (active) {
                const float Tbefore = T / (1 - alpha);
                const float3 c = sColor[j].xyz;
                const float w = alpha * Tbefore;
                v[6] = w * dC.x; v[7] = w * dC.y; v[8] = w * dC.z;
                float dAlpha = dot(dC, c * Tbefore - behind / (1 - alpha));
                behind += c * w;
                if (depthWeight > 0) {
                    const float dz = sColor[j].w - lidarZ, e = fabs(dz);
                    v[12] = depthWeight * w * sign(dz);
                    dAlpha += depthWeight * (e * Tbefore - behindE / (1 - alpha));
                    behindE += e * w;
                }
                T = Tbefore;
                if (co.w * G < kAlphaMax) {
                    v[5] = G * dAlpha;
                    const float dPower = alpha * dAlpha;
                    v[0] = -dPower * (co.x * d.x + co.y * d.y);
                    v[1] = -dPower * (co.y * d.x + co.z * d.y);
                    v[2] = -0.5f * dPower * d.x * d.x;
                    v[3] = -dPower * d.x * d.y;
                    v[4] = -0.5f * dPower * d.y * d.y;
                }
                v[9] = w; v[10] = w * error; v[11] = w * edge;
            }
            // Lanes 2k and 2k + 1 now hold the SIMD group's total of value k.
            const float sum = simdSum16(v, lane);
            const uint k = lane >> 1;
            if ((lane & 1) == 0 && k < kGrad2DStride && sum != 0)
                atomic_fetch_add_explicit(grad2d + sId[j] * kGrad2DStride + k, sum, memory_order_relaxed);
        }
    }
}

inline float clampGrad(float g) { return clamp(g, -1e4f, 1e4f); }

/// Chain rule from the per-Gaussian 2D gradients to the model parameters and the camera.
/// Writes every row < count of `grads` (zero for culled Gaussians). `poseGrad` accumulates
/// dL/d[R|t] of the world-to-camera transform (row-major 3x4) over all Gaussians.
kernel void project_backward(constant CameraParams& cam [[buffer(0)]],
                             constant ModelLayout& layout [[buffer(1)]],
                             device const float* model [[buffer(2)]],
                             device const float* grad2d [[buffer(3)]],
                             device const uint* tiles [[buffer(4)]],
                             device float* grads [[buffer(5)]],
                             device atomic_float* poseGrad [[buffer(6)]],
                             uint i [[thread_position_in_grid]],
                             uint lane [[thread_index_in_simdgroup]]) {
    const uint count = cam.sh.z;
    const uint rest = cam.sh.y - 1;
    float poseLocal[12];
    for (uint k = 0; k < 12; ++k) poseLocal[k] = 0;
    bool active = i < count && tiles[i] > 0;
    if (i < count && !active) {
        for (uint k = 0; k < 3; ++k) { grads[layout.means + 3 * i + k] = 0; grads[layout.scales + 3 * i + k] = 0;
                                       grads[layout.sh0 + 3 * i + k] = 0; }
        for (uint k = 0; k < 4; ++k) grads[layout.quats + 4 * i + k] = 0;
        grads[layout.opacities + i] = 0;
        for (uint k = 0; k < rest * 3; ++k) grads[layout.shN + i * rest * 3 + k] = 0;
    }
    if (active) {
        const float3 mean = load3(model + layout.means, i);
        const float3 logScale = load3(model + layout.scales, i);
        const float4 quat = float4(model[layout.quats + 4 * i], model[layout.quats + 4 * i + 1],
                                   model[layout.quats + 4 * i + 2], model[layout.quats + 4 * i + 3]);
        Projected p;
        projectGaussian(cam, mean, logScale, quat, p);
        device const float* g2 = grad2d + i * kGrad2DStride;
        const float fx = cam.intrinsics.x, fy = cam.intrinsics.y;
        const float3x3 W = worldRotation(cam);
        const float3 Wr0 = cam.r0.xyz, Wr1 = cam.r1.xyz, Wr2 = cam.r2.xyz;
        const float3 t = float3(cam.r0.w, cam.r1.w, cam.r2.w);

        // Opacity and 2D filter compensation.
        const float sig = sigmoid(model[layout.opacities + i]);
        const float gOpacity = g2[5];
        const float dLogit = gOpacity * p.rho * sig * (1 - sig);

        // Conic -> filtered covariance (per-slot symmetric gradients).
        const float3 cf = p.cov2dFiltered;
        const float inv = 1.0f / p.detFiltered;
        const float2x2 Q = float2x2(float2(cf.z * inv, -cf.y * inv), float2(-cf.y * inv, cf.x * inv));
        const float2x2 GQ = float2x2(float2(g2[2], 0.5f * g2[3]), float2(0.5f * g2[3], g2[4]));
        const float2x2 dSigma = -1.0f * (Q * GQ * Q);
        float ma = dSigma[0][0], mb = dSigma[0][1], mc = dSigma[1][1];
        if (p.compensated && p.rho > 0) {
            // rho^2 = det(base) / det(filtered), both base and filtered = cov2d + constant:
            // d rho / d cov2d = (adj(base) - rho^2 adj(filtered)) / (2 rho det(filtered)).
            const float rho2 = p.rho * p.rho;
            const float dRho = gOpacity * sig;
            const float scale = dRho / (2.0f * p.rho * p.detFiltered);
            const float3 b = p.cov2dBase, f = p.cov2dFiltered;
            ma += scale * (b.z - rho2 * f.z);
            mb += scale * (-b.y + rho2 * f.y);
            mc += scale * (b.x - rho2 * f.x);
        }

        // 2D -> 3D covariance and the projection Jacobian.
        const float z = p.camera.z;
        const float3 j0 = float3(fx / z, 0, -fx * p.limits.x / z);
        const float3 j1 = float3(0, fy / z, -fy * p.limits.y / z);
        const float3x3 Wt = transpose(W);
        const float3 T0 = Wt * j0, T1 = Wt * j1;
        const float3x3 dCov3 = ma * outer(T0, T0) + mb * (outer(T0, T1) + outer(T1, T0)) + mc * outer(T1, T1);
        const float3 dT0 = 2.0f * (p.cov3d * (ma * T0 + mb * T1));
        const float3 dT1 = 2.0f * (p.cov3d * (mb * T0 + mc * T1));
        const float dj00 = dot(dT0, Wr0), dj02 = dot(dT0, Wr2);
        const float dj11 = dot(dT1, Wr1), dj12 = dot(dT1, Wr2);
        float3 dW0 = j0.x * dT0, dW1 = j1.y * dT1, dW2 = j0.z * dT0 + j1.z * dT1;

        // Rolling shutter: the row time depends on the unshifted row y0 (velocities held
        // constant), so d pixel / d y0 = (u'_x R / (H denom), 1 / denom).
        float gx = g2[0], gy = g2[1];
        const float readout = cam.angularMotion.w;
        if (readout != 0) {
            const float ry = p.camera.y / z, H_ = float(cam.dims.y);
            const float2 udot = pixelVelocity(cam, p.camera, p.limits);
            const float denom = 1.0f - udot.y * readout / H_;
            const float y0 = fy * ry + cam.intrinsics.w;
            const float tau = ((y0 - 0.5f * udot.y * readout) / max(denom, 0.5f) / H_ - 0.5f) * readout;
            if (denom > 0.5f && fabs(tau) < fabs(readout)) {
                gy = g2[1] / denom + g2[0] * udot.x * readout / (H_ * denom);
            }
        }
        // Camera-space centre.
        float3 dCam = float3(gx * fx / z, gy * fy / z,
                             -gx * fx * p.camera.x / (z * z) - gy * fy * p.camera.y / (z * z) + g2[12]);
        const float z2 = z * z, z3 = z2 * z;
        dCam.z += dj00 * (-fx / z2) + dj11 * (-fy / z2);
        if (!p.clamped.x) { dCam.x += dj02 * (-fx / z2); dCam.z += dj02 * (2 * fx * p.camera.x / z3); }
        else { dCam.z += dj02 * (fx * p.limits.x / z2); }
        if (!p.clamped.y) { dCam.y += dj12 * (-fy / z2); dCam.z += dj12 * (2 * fy * p.camera.y / z3); }
        else { dCam.z += dj12 * (fy * p.limits.y / z2); }
        float3 dMean = Wt * dCam;
        dW0 += dCam.x * mean; dW1 += dCam.y * mean; dW2 += dCam.z * mean;
        float3 dt = dCam;

        // Colour: SH coefficients and the view direction.
        const float3 toGaussian = mean - cam.center.xyz;
        const float distance = length(toGaussian);
        const float3 dir = toGaussian / max(distance, 1e-12f);
        float basis[16];
        const uint degree = cam.sh.x;
        shBasis(dir, degree, basis);
        const uint coeffs = (degree + 1) * (degree + 1);
        float3 raw = basis[0] * load3(model + layout.sh0, i);
        for (uint k = 1; k < coeffs; ++k) raw += basis[k] * load3(model + layout.shN + i * rest * 3, k - 1);
        raw += 0.5f;
        const float3 gRGB = float3(g2[6], g2[7], g2[8]) * float3(raw >= 0.0f);
        float gBasis[16];
        for (uint k = 0; k < 16; ++k) gBasis[k] = 0;
        gBasis[0] = dot(load3(model + layout.sh0, i), gRGB);
        for (uint k = 0; k < 3; ++k) grads[layout.sh0 + 3 * i + k] = clampGrad(basis[0] * gRGB[k]);
        for (uint k = 1; k < rest + 1; ++k) {
            const bool used = k < coeffs;
            const float3 coefficient = load3(model + layout.shN + i * rest * 3, k - 1);
            if (used) gBasis[k] = dot(coefficient, gRGB);
            for (uint c = 0; c < 3; ++c)
                grads[layout.shN + i * rest * 3 + (k - 1) * 3 + c] = used ? clampGrad(basis[k] * gRGB[c]) : 0.0f;
        }
        const float3 dDir = shBasisGradient(dir, degree, gBasis);
        const float3 dToGaussian = (dDir - dir * dot(dir, dDir)) / max(distance, 1e-12f);
        dMean += dToGaussian;
        // Camera centre c = -R^T t receives -dToGaussian.
        const float3 dCenter = -dToGaussian;
        dt += -(W * dCenter);
        dW0 += -t.x * dCenter; dW1 += -t.y * dCenter; dW2 += -t.z * dCenter;

        // 3D covariance -> scale and rotation.
        const float qn = rsqrt(dot(quat, quat));
        const float4 q = quat * qn;
        const float3x3 R = quatToMatrix(q);
        const float3 s = exp(min(logScale, 20.0f));
        const float3x3 M = float3x3(R[0] * s.x, R[1] * s.y, R[2] * s.z);
        const float3x3 dM = 2.0f * (dCov3 * M);
        float3 dLogScale = float3(dot(R[0], dM[0]) * s.x, dot(R[1], dM[1]) * s.y, dot(R[2], dM[2]) * s.z);
        dLogScale *= float3(logScale < 20.0f);
        const float3x3 dR = float3x3(dM[0] * s.x, dM[1] * s.y, dM[2] * s.z);
        // G(row, col) = dR[col][row]
        #define G(r, c) dR[c][r]
        const float w = q.x, x = q.y, y = q.z, zq = q.w;
        const float4 dq = 2.0f * float4(x * (G(2, 1) - G(1, 2)) + y * (G(0, 2) - G(2, 0)) + zq * (G(1, 0) - G(0, 1)),
                                        -2 * x * (G(1, 1) + G(2, 2)) + y * (G(0, 1) + G(1, 0)) + zq * (G(0, 2) + G(2, 0)) + w * (G(2, 1) - G(1, 2)),
                                        x * (G(0, 1) + G(1, 0)) - 2 * y * (G(0, 0) + G(2, 2)) + zq * (G(1, 2) + G(2, 1)) + w * (G(0, 2) - G(2, 0)),
                                        x * (G(0, 2) + G(2, 0)) + y * (G(1, 2) + G(2, 1)) - 2 * zq * (G(0, 0) + G(1, 1)) + w * (G(1, 0) - G(0, 1)));
        #undef G
        const float4 dQuat = (dq - q * dot(q, dq)) * qn;

        for (uint k = 0; k < 3; ++k) {
            grads[layout.means + 3 * i + k] = clampGrad(dMean[k]);
            grads[layout.scales + 3 * i + k] = clampGrad(dLogScale[k]);
        }
        for (uint k = 0; k < 4; ++k) grads[layout.quats + 4 * i + k] = clampGrad(dQuat[k]);
        grads[layout.opacities + i] = clampGrad(dLogit);
        poseLocal[0] = dW0.x; poseLocal[1] = dW0.y; poseLocal[2] = dW0.z; poseLocal[3] = dt.x;
        poseLocal[4] = dW1.x; poseLocal[5] = dW1.y; poseLocal[6] = dW1.z; poseLocal[7] = dt.y;
        poseLocal[8] = dW2.x; poseLocal[9] = dW2.y; poseLocal[10] = dW2.z; poseLocal[11] = dt.z;
    }
    if (simd_any(active)) {
        for (uint k = 0; k < 12; ++k) {
            const float v = simd_sum(poseLocal[k]);
            if (lane == 0) atomic_fetch_add_explicit(poseGrad + k, v, memory_order_relaxed);
        }
    }
}

