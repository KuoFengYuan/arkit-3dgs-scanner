# 座標系慣例：ARKit、COLMAP 與 Nerfstudio

[English](COORDINATES.md) | **繁體中文**

公式由 [`tools/test_math.py`](../tools/test_math.py) 驗證。座標自洽是訓練必要條件，但不代表真實幾何沒有誤差。

## 相機慣例

| 系統 | 相機 X | 相機 Y | 前方 | 儲存姿態 |
| --- | --- | --- | --- | --- |
| ARKit / OpenGL | 右 | 上 | -Z | camera-to-world（c2w） |
| Nerfstudio / instant-ngp transforms | 右 | 上 | -Z | transform_matrix（c2w） |
| OpenCV / COLMAP | 右 | 下 | +Z | COLMAP 為 world-to-camera（w2c）四元數與平移 |

令 ARKit 矩陣為 `M_gl`，`D = diag(1,-1,-1,1)`：

```text
M_cv = M_gl · D                         # 右乘，只改相機局部軸
W = inverse(M_cv) = [Rᵀ | -Rᵀt]        # 剛體反矩陣
qvec = rotationToQuaternion(W.rotation) # COLMAP 順序 qw,qx,qy,qz
tvec = W.translation
```

對應 [geometry.py](../tools/geometry.py) 的 `colmap_qt_from_c2w_gl()`。SciPy 常用 xyzw，不可直接當 wxyz 寫入。

```text
GL：u=fx*x/(-z)+cx；v=cy-fy*y/(-z)，前方 z<0
CV：u=fx*x/z+cx；v=fy*y/z+cy，前方 z>0
```

同一世界點在兩條路徑的投影應一致；合成回歸以 1e-6 像素容差檢查。

## 世界座標與檢視器方向

擷取採重力對齊，名義上 +Y 朝上，位置與深度以公尺表示。公制單位不會消除漂移、深度雜訊或尺度誤差。

相機座標慣例並不規定所有檢視器的世界上方向。本專案為相容目標檢視流程，預設 `flipWorldUpForExport = true`，將 COLMAP **相機與點雲一起**繞世界 X 軸轉 180°：`(x,y,z) → (x,-y,-z)`。這是保持投影不變的剛體轉換。

- `sparse/0/images.bin` 和 `points3D.bin` 成對轉換。
- `points.ply`、預覽點雲與 JSONL 姿態保留 ARKit 座標。
- Python COLMAP 預設 `--colmap-flip-up`；期待原方向的檢視器可用 `--no-colmap-flip-up`。
- Python `--world-up z` 對姿態與點雲套用 `Rx(+90°)`，優先於 flip。
- Nerfstudio 轉換保持 GL 相機慣例，後續方向／尺度正規化依訓練設定。

不同世界座標的點與姿態不可混用。整個世界一起旋轉仍可通過重投影測試，但在特定檢視器顯示顛倒；上方向是獨立選項。

## 影像方向與內參

預設保留相機 buffer 的感測器方向，連同對應內參與姿態一起儲存。不要假設所有裝置／格式都是 1920×1440，應讀取逐幀尺寸。預覽轉正只改顯示，不改訓練 JPEG 像素或校準。

Swift simd 為 column-major：

```text
fx = intrinsics[0][0]; fy = intrinsics[1][1]
cx = intrinsics[2][0]; cy = intrinsics[2][1]
```

App 採 PINHOLE 近似，**每張選用影像各輸出一組內參**，反映逐幀校準變化；不宣稱殘餘鏡頭效應完全為零。Python 轉換器可能使用聚合內參路徑，應查看輸出與驗證報告，不要假設相機數與 App 相同。

Python 選用 portrait 正規化時，影像、內參與相機軸必須一起轉：

| 項目 | 順時針 90° |
| --- | --- |
| 影像 | PIL ROTATE_270 / np.rot90(k=-1) |
| 內參 | fx'=fy、fy'=fx、cx'=H-cy、cy'=cx |
| CV c2w | 右乘 columns 為 x'=-y、y'=x、z'=z 的旋轉 |
| 投影不變量 | 依轉換器像素慣例，(u',v')=(H-v,u) |

GL 的對應旋轉為 `D·R·D`。詳見 `rotate_portrait()` 與測試；只轉照片會使內參不一致。

## 深度反投影

LiDAR 儲存 float32 公尺深度，代表相機光軸 Z，不是沿射線的歐氏距離。依實際尺寸分別縮放 x/y 內參：

```text
fx_d=fx_rgb*depthWidth/imageWidth；fy_d=fy_rgb*depthHeight/imageHeight
cx_d=cx_rgb*depthWidth/imageWidth；cy_d=cy_rgb*depthHeight/imageHeight
p_cv=((u-cx_d)/fx_d*d, (v-cy_d)/fy_d*d, d)
p_gl=(p_cv.x, -p_cv.y, -p_cv.z)
p_world=c2w_arkit*p_gl
```

後續信心值、邊界、入射角、時間支持、voxel 權重與多視角共識是品質政策，與座標公式分開。

影像、深度、內參與姿態取自同一 ARFrame，JSONL 記錄單調時鐘 `frame.timestamp`。驗證會檢查時間與間隔；同幀取得不代表沒有捲簾快門或曝光內的運動效應。

## 除錯

| 症狀 | 檢查 |
| --- | --- |
| 檢視器上下顛倒 | 世界上方向設定；姿態與點雲必須一起改 |
| 鏡像或錯位 | 相機局部軸右乘與世界軸左乘是否混淆 |
| 相機背對點雲 | GL/CV 轉換與 c2w/w2c 反矩陣 |
| 模型漂浮亂轉 | 四元數順序、姿態與點雲是否同座標 |
| portrait 後大幅投影偏移 | 影像、內參與軸是否都旋轉 |
| 矩陣轉置 | simd column-major 寫 JSONL 時明確轉 row-major |

投影自洽不能證明檢視器方向或絕對尺寸精度。
