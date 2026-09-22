# Coordinate conventions: ARKit, COLMAP, and Nerfstudio

**English** | [繁體中文](COORDINATES.zh-TW.md)

The conversion formulas are exercised by [`tools/test_math.py`](../tools/test_math.py). Coordinate consistency is necessary for training, but does not prove physical accuracy.

## Camera conventions

| System | Camera X | Camera Y | Forward | Stored pose |
| --- | --- | --- | --- | --- |
| ARKit / OpenGL | Right | Up | -Z | Camera-to-world (`c2w`) |
| Nerfstudio / instant-ngp transforms | Right | Up | -Z | `transform_matrix` (`c2w`) |
| OpenCV / COLMAP | Right | Down | +Z | COLMAP world-to-camera (`w2c`), quaternion and translation |

For ARKit matrix `M_gl`, define `D = diag(1,-1,-1,1)`:

```text
M_cv = M_gl · D                         # Right multiply: change camera-local axes
W = inverse(M_cv) = [Rᵀ | -Rᵀt]        # Rigid inverse
qvec = rotationToQuaternion(W.rotation) # COLMAP order: qw, qx, qy, qz
tvec = W.translation
```

See `colmap_qt_from_c2w_gl()` in [geometry.py](../tools/geometry.py). SciPy commonly returns xyzw; do not serialize it as COLMAP wxyz without reordering.

```text
GL camera: u = fx*x/(-z)+cx; v = cy-fy*y/(-z), front has z<0
CV camera: u = fx*x/z+cx;    v = fy*y/z+cy,     front has z>0
```

Both paths must project the same world point identically. The regression suite checks agreement to 1e-6 pixels for its fixtures.

## World frame and viewer orientation

Capture uses gravity alignment, nominal +Y up, with positions/depth expressed in meters. Metric units do not remove tracking drift, depth noise, or scale error.

Camera-axis conventions do not uniquely prescribe a viewer's world-up direction. For compatibility with the targeted viewer setup, the app defaults to `flipWorldUpForExport = true`: rotate COLMAP cameras **and** points by 180° around world X, `(x,y,z) → (x,-y,-z)`. This rigid change preserves projections and only changes world orientation.

- `sparse/0/images.bin` and `points3D.bin` receive the paired conversion.
- `points.ply`, preview clouds, and JSONL poses retain ARKit coordinates.
- Python COLMAP export defaults to `--colmap-flip-up`; use `--no-colmap-flip-up` for a viewer expecting the original orientation.
- Python `--world-up z` applies `Rx(+90°)` to poses and points and takes precedence over the flip option.
- The Nerfstudio conversion preserves the GL camera convention; downstream orientation/normalization depends on trainer settings.

Never combine poses from one world frame with points from the other. A globally rotated model can pass every reprojection check and still look upside down in a viewer; orientation is a separate convention choice.

## Image orientation and calibration

The default export preserves camera-buffer sensor orientation together with its matching intrinsics and pose. Do not assume every device/video format is 1920×1440: use per-frame dimensions. Preview rotation is for display and does not alter training JPEG pixels or calibration.

Swift `simd` matrices are column-major. Intrinsics are read as:

```text
fx = intrinsics[0][0]; fy = intrinsics[1][1]
cx = intrinsics[2][0]; cy = intrinsics[2][1]
```

The app exports a PINHOLE approximation and **one camera calibration per selected image**, accommodating per-frame focus/calibration changes. It does not claim all residual lens effects are zero. The Python converter may use its own aggregated calibration path; inspect its output and validation report rather than assuming identical camera counts.

Optional Python portrait normalization must transform image, intrinsics, and camera axes together:

| Component | Clockwise 90° transform |
| --- | --- |
| Image | PIL `ROTATE_270` / `np.rot90(k=-1)` |
| Intrinsics | `fx'=fy`, `fy'=fx`, `cx'=H-cy`, `cy'=cx` |
| CV c2w | Right multiply by rotation with columns `x'=-y, y'=x, z'=z` |
| Projection invariant | `(u',v')=(H-v,u)` under the converter's pixel-coordinate convention |

In GL convention, use `D·R·D` for the equivalent local rotation. See `rotate_portrait()` and the associated tests; rotating only the photo creates incorrect calibration.

## Depth unprojection

Saved LiDAR depth is float32 in meters, representing camera Z depth rather than Euclidean ray length. Scale x/y intrinsics independently to the actual depth dimensions:

```text
fx_d = fx_rgb * depthWidth/imageWidth
fy_d = fy_rgb * depthHeight/imageHeight
cx_d = cx_rgb * depthWidth/imageWidth
cy_d = cy_rgb * depthHeight/imageHeight
p_cv = ((u-cx_d)/fx_d*d, (v-cy_d)/fy_d*d, d)
p_gl = (p_cv.x, -p_cv.y, -p_cv.z)
p_world = c2w_arkit * p_gl
```

Confidence, edges, incidence, temporal support, voxel weighting, and multi-view consensus then determine acceptance. Those are quality policies, separate from the coordinate equations.

Images, depth, intrinsics, and poses are taken from the same ARFrame. `frame.timestamp` is written to JSONL using the monotonic capture clock. Validation checks timestamps and intervals; synchronous acquisition does not eliminate rolling shutter or motion effects within an exposure.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Viewer appears upside down | World-up setting; apply any change to both cameras and points |
| Mirrored or misplaced reconstruction | Camera-local right multiplication versus world-axis left multiplication |
| Cameras face away from points | GL/CV conversion and c2w/w2c inversion |
| Rotating/floating model | Quaternion order and pose/point world-frame agreement |
| Large reprojection offset after portrait conversion | Image, intrinsics, and axes must all rotate |
| Transposed serialized matrices | Explicitly convert simd column storage to row-major JSONL |

Internal projection checks cannot establish an external viewer's preferred up direction or absolute scene accuracy.
