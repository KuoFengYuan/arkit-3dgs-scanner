# 外部 3DGS 訓練

[English](TRAINING.md) | **繁體中文**

本頁說明在電腦上訓練；App 也可以直接在手機上訓練（[手機端 3DGS 訓練](ON_DEVICE_3DGS.zh-TW.md)）。使用外部訓練器時，解壓匯出的掃描，使用 `images/ + sparse/0`。模型包含選用影像姿態、逐影像 PINHOLE 內參與初始化點，不含完整 SfM 觀測及 tracks。

## LichtFeld Studio / MrNeRF

用 [LichtFeld Studio](https://github.com/MrNeRF/LichtFeld-Studio) 開啟解壓的 COLMAP 資料集。安裝與 CLI 參數依該專案文件及已安裝版本的 help。比較掃描時記錄版本與設定；本專案未鎖定外部訓練器版本。

訓練影像以 `sparse/0/images.bin` 為準；images 仍保留所有原始照片，包括未選用者。自行遍歷 images 的流程需套用 training-selection.json 的 selectedIDs。

points3D.bin 是初始化點雲，不是訓練後模型。手機輸出目前上限 250,000 點。資料集 ZIP 不含 `gaussians.ply`：那是訓練結果，不是缺少的輸入；手機端訓練的模型另以 `scan_…-3dgs.zip` 分享。

## 其他訓練器

選用轉換器可產生 COLMAP / Nerfstudio：

```sh
python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

確認轉換參數與選幀行為，不要假設再次轉換與 App 輸出完全相同。資料匯入、影像縮放、驗證視角、初始化及相機最佳化，依實際安裝版本文件。

[Nerfstudio Splatfacto](https://docs.nerf.studio/nerfology/methods/splat.html) 提供訓練／匯出說明。其他可能使用者包括 [原始 3DGS](https://github.com/graphdeco-inria/gaussian-splatting) 與 [gsplat](https://github.com/nerfstudio-project/gsplat)。各版本的 loader、硬體與旗標可能不同，本文件不保證跨框架 PSNR 或速度提升。

## 姿態精修與缺少 tracks

App 採校正錨點，保留集與[照片對齊檢查](POSE_REFINEMENT.zh-TW.md)都通過時才套用 LiDAR 輔助 BA；未通過就保留原姿態。手機未建模的誤差（例如捲簾快門），若訓練器支援相機最佳化，仍可再由訓練器修正。重融合使用同組姿態，不能只改相機而保留未對齊的初始化點雲。

空影像觀測／tracks 可作為此種種子模型匯出，但 BA 無法自行產生缺少的對應。桌面精修需要特徵抽取、匹配、一致的相機／影像 ID、三角化及驗證後再 BA。參考 [COLMAP 已知姿態重建](https://colmap.github.io/faq.html#reconstruct-sparse-dense-model-from-known-camera-poses)。姿態變更後點雲也需對齊或重融合；手機流程本身不要求桌面 COLMAP。

## 選用深度監督

LiDAR 深度為公尺 float32，應讀取資料中的尺寸，不能假設永遠是 256×192。轉毫米 PNG 或其他格式時需處理有效深度遮罩、單位、影像／深度尺寸與方向，以及訓練器相機慣例。加入 depth_file_path 不代表每種訓練器就會啟用深度 loss。

## 模糊與重影除錯

1. 執行 tools/validate_dataset.py，查看姿態突跳、間隔和內參一致性。
2. 原始／優化版本使用相同訓練設定、縮放及保留驗證視角比較。
3. 以適當解析度檢查照片。運動估計是風險，低紋理可能無法判定清晰度；細節確實偏弱時補拍較清晰的重疊視角。
4. 檢查雙邊及局部厚度。點數增加或殘差減少不證明絕對精度。
5. 座標保持一致：COLMAP 相機／點雲一起套用設定的世界旋轉；JSONL 與 PLY 預覽保留 ARKit 座標，詳見[座標](COORDINATES.zh-TW.md)。
6. 先檢查覆蓋不足、反光、動態物體、曝光變化與長距漂移，再判定是否為訓練設定問題。

新匯出使用 capture-meta.json。舊 meta.json 若使訓練器誤判格式，可用新版重新匯出或改名解壓後的中繼資料；已分享 ZIP 不會自動更新。選幀與局部精修不能保證消除所有殘影，仍需重訓比較。
