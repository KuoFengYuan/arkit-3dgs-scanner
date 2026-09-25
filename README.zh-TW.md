# ARKit 3DGS Scanner

[English](README.md) | **繁體中文**

使用 ARKit 擷取照片、相機姿態與點雲，在手機完成品質檢查、姿態精修、深度融合和預覽；接著可直接在手機上訓練 3D Gaussian Splatting（3DGS）模型，或匯出標準 COLMAP 資料集給外部訓練器。

**「訓練 3DGS」完全在 iPhone 的 GPU 上執行，不需要伺服器**：渲染、計算損失、更新模型與相機都在手機完成。訓練影像可選 960、1,440 或照片原始的 1,920 px。訓練時可以繼續使用 App 的其他功能，iOS 26 還可以在背景繼續。切到其他 App 又沒有背景時間、裝置過熱、電量不足或記憶體吃緊時，會先儲存檢查點再暫停，之後可從掃描紀錄繼續。給外部訓練器的 COLMAP 匯出維持不變。方法、記憶體保護、檔案格式與各項驗證的範圍，詳見[手機端 3DGS 訓練](docs/ON_DEVICE_3DGS.zh-TW.md)。照片篩選、相機精修、點雲重融合同樣在手機執行，不需要上傳。GitHub、本機專案、scheme 與 App 識別碼均為 `arkit-3dgs-scanner`。以舊識別碼安裝的 App 會顯示為另一個 App；如需保留其中的掃描，請先從舊 App 匯出。

```text
開始掃描 → 自動擷取影像 → 停止與資料優化 → 檢查點雲
                                            ├─ 續掃補拍
                                            ├─ 在 iPhone 上訓練 3DGS → 檢視／分享模型
                                            └─ 匯出 3DGS 訓練資料 ZIP
掃描紀錄 → 照片／點雲／路線預覽 → 訓練 3DGS／優化資料／匯出／刪除
```

新增中英文科技感融合進度頁、第一人稱路線回放與分段匯出保護。詳見[融合進度、第一人稱預覽與匯出穩定性](docs/FUSION_REVIEW.zh-TW.md)。

- **實驗性表面重建：** 有上限的局部 RGB-D 姿態精修與稀疏 TSDF 表面點，保留完整 voxel 融合備援。TSDF 使用單一有界暫存檔與批次寫入保留完整精度；達點數上限時以穩定空間順序取樣。融合另加入單張 JPEG 預讀與精確深度有效性快取，不改取樣或門檻。詳見[流程、效能比較與限制](docs/SURFACE_RECONSTRUCTION.zh-TW.md)。

## 主要功能

| 功能 | 說明 |
| --- | --- |
| ARKit 掃描 | 依位移、轉角與品質自動保存關鍵影格；保存逐幀相機內參、姿態與時間戳 |
| LiDAR 開關 | 開拍前選擇使用深度掃描，或以 RGB、ARKit 稀疏特徵及可選影像重建採集 |
| 點雲融合 | 即時點雲預覽；停止後以多視角深度支持與有界修正減少重影、厚層和雜點 |
| 手機端資料優化 | 選擇清晰照片、跨幀匹配、驗證局部精修與重訪 track、以相同姿態重新融合深度 |
| 公尺尺度 | 點雲選點量距、已知長度校正、獨立距離驗證，同步匯出縮放後相機與點雲 |
| 手機端 3DGS | 每筆掃描可在手機上以 960–1,920 px 訓練、即時預覽、暫停與續訓；可隨時提前完成，之後再加強已保存的模型；完成的模型重開 App 後仍可從掃描紀錄開啟 |
| 歷史紀錄 | 停止後自動保存；可預覽、另存優化版本、匯出、單筆／多選／全部刪除 |
| 影像與路線回放 | 照片和 3D 相機位置同步；可調 FPS、拖曳進度、全螢幕及自動跟隨 |
| 平面圖 | 在支援的模式與裝置上擷取或推估結構，成功時可預覽及匯出 |
| 訓練資料匯出 | 原始影像、標準 COLMAP `sparse/0`、PLY、姿態及品質報告 |

## 快速開始

1. 使用 Xcode 26 或更新版本開啟 `arkit-3dgs-scanner.xcodeproj`，選取 `arkit-3dgs-scanner` scheme 與自己的簽章 Team。 Run 預設使用最佳化 Release；需要逐行除錯時才選 `arkit-3dgs-scanner-Debug`。詳見[融合速度與表面重影](docs/SCAN_FUSION_DIAGNOSTICS.zh-TW.md)。
2. 安裝至支援 ARKit 的 iPhone／iPad；專案最低部署版本為 iOS 17。LiDAR 深度與 RoomPlan 功能需對應硬體支援。
3. 按「開始掃描」，允許相機存取，等待追蹤就緒；開拍前選擇 LiDAR、精細掃描等設定。
4. 沿著空間移動，從不同角度拍到同一表面。停止後等待資料優化，檢查點雲與缺漏，必要時「續掃」。
5. 按「訓練 3DGS」在手機上建立模型；或按「匯出 3DGS 訓練資料」將 ZIP 分享到電腦，解壓後由支援 COLMAP 資料集的外部訓練器載入。

Simulator 可驗證一般介面與資料流程，不能代替真機 ARKit／LiDAR 掃描。已安裝的舊版 App 不會自動取得原始碼變更，需重新建置安裝。

## 在 iPhone 上訓練 3DGS

App 可以在手機的 GPU 上，為已保存的掃描訓練 3D Gaussian Splatting 模型，資料不會上傳。

**需求：**
- A14 或更新晶片的 iPhone／iPad（Metal Apple GPU family 7）。
- LiDAR 掃描的效果最好：LiDAR 深度能補上融合點雲漏掉的表面。純相機掃描則以其稀疏點雲開始訓練。
- 訓練時可以繼續使用 App 的其他功能。切到其他 App 會暫停，除非 iOS 允許在背景繼續（見[在背景繼續訓練](#在背景繼續訓練)）。建議接上電源。

### 開始訓練

1. 完成一次掃描，或打開「掃描紀錄」選一筆掃描。
2. 點「訓練 3DGS」卡片。掃描完成後的檢視畫面，以及掃描詳情頁都有這張卡片。
3. 選擇品質：

   | 品質 | 迭代次數 | 高斯上限 | 適合 |
   | --- | --- | --- | --- |
   | 快速預覽 | 3,000 | 300,000 | 先快速看看效果 |
   | 標準（建議） | 7,000 | 600,000 | 大多數掃描 |
   | 高品質 | 15,000 | 1,000,000 | 細節最多；時間最長、較耗電 |

4. 選擇「訓練解析度」，也就是訓練影像的長邊：

   | 解析度 | 長邊 | 代價 |
   | --- | --- | --- |
   | 低（預設） | 960 px | 最快、最省記憶體 |
   | 中 | 1,440 px | 時間約 1.7 倍 |
   | 高（原始） | 1,920 px，照片原始大小 | 時間約 2.6 倍，記憶體用量最高 |

   在這支手機跑完一次後，每個品質選項會顯示在所選解析度下花的時間。選項下方的記憶體檢查會在可用記憶體較少時自動降低高斯上限。
5. 可選：打開「進階設定」調整相機姿態微調、PPISP 色彩校正與抗鋸齒。大多數掃描維持預設即可；PPISP 只有在拍攝時曝光有變化才會自動開啟。
6. 點「開始訓練」。

### 訓練中

- 模型會即時出現並逐漸變清楚。單指拖曳旋轉、雙指平移、捏合縮放、點兩下重設視角。
- 卡片顯示進度、目前階段，速度穩定後也會顯示剩餘時間；下方一行是迭代、高斯數、損失、PSNR 與用時。
- 可以「暫停」、「儲存進度」或「停止」。停止時可選擇保留進度之後繼續，或刪除這次訓練。
- 覺得模型已經夠好時，點「完成並保存模型」即可結束訓練。目前的結果會存成模型，和跑完的訓練一樣，之後還可以用「加強模型」繼續訓練。
- 可以離開訓練畫面。瀏覽掃描紀錄或其他掃描時，訓練會繼續，首頁的「掃描紀錄」卡片會顯示進度。回到該掃描的「訓練 3DGS」卡片即可再看目前的訓練。
- 以下情況會自動暫停並儲存進度：
  - 切到其他 App，除非可以[在背景繼續](#在背景繼續訓練)；
  - 開始新的拍攝（結束拍攝後會自動繼續）；
  - 手機過熱；
  - 沒接電源且電量低於 15%；
  - 記憶體不足。

  回到 App 或手機降溫後會自動繼續；也可以之後從卡片繼續。

### 在背景繼續訓練

iOS 26 以上，切到其他 App 後仍可繼續訓練。iOS 會以系統通知顯示進度，也可以在那裡停止。需要：

- iOS 在這台裝置上提供背景 GPU 時間；以及
- 「Background GPU Access」功能，只有付費的 Apple Developer 團隊可以加入：
  1. 在 Xcode 選取 `arkit-3dgs-scanner` target，再選「Signing & Capabilities」。
  2. 按「+ Capability」，加入「Background GPU Access」。
  3. 重新建置並安裝。

專案已在 `Config/Info.plist` 宣告工作識別碼。缺少任一條件，或 iOS 結束背景時間時，訓練會儲存進度並暫停，回到 App 後繼續。訓練畫面會標示目前是哪一種情況。

### 完成後

- 模型會跟著這筆掃描保存，重開 App 後仍在。「掃描紀錄」的卡片會標示已有模型、訓練中或可續訓；點「檢視 3DGS 模型」即可環繞檢視。
- 「加強模型」會讀取已保存的模型繼續訓練：可選再訓練 3,000、7,000 或 15,000 次，以及訓練解析度，例如先用「低」訓練，再用「高（原始）」加強。相機姿態微調與色彩模型都會延續。加強完成前會保留目前的模型；以「刪除」停止加強時，已保存的模型維持原樣。
- 「分享 3DGS 模型」會送出 `scan_…-3dgs.zip`，內含 `gaussians.ply`（標準 3DGS PLY）、中繼資料、微調後的相機姿態；有用 PPISP 時另含 `ppisp.json`。
- 用其他 3DGS 檢視器開啟時，PLY 採用 COLMAP 座標系，Y 軸朝上的檢視器會看到上下顛倒，請繞 X 軸旋轉 180°。這些檢視器會忽略 `ppisp.json`。
- 右上角的選項選單：
  - 「重新訓練」：在新模型完成前保留目前的模型。
  - 「刪除 3DGS 模型」：只刪除訓練結果，掃描的照片、深度與姿態都保留。

訓練器會微調相機姿態、用 LiDAR 深度補上沒有點的表面、在訓練中補洞，並以 LiDAR 深度作為幾何損失，讓模型在偏離拍攝路徑環繞檢視時依然維持正確形狀。方法、實測結果、記憶體保護與檔案格式，詳見[手機端 3DGS 訓練](docs/ON_DEVICE_3DGS.zh-TW.md)。iPhone 上的訓練速度、記憶體用量與發熱都還沒實測，Mac 與 Simulator 的結果不能代替。

## 介面與操作

介面採深色、以 3D 為主：相機畫面或點雲佔滿螢幕，控制項浮在上方。每個畫面只有一個醒目的主要動作，次要控制只在需要時出現。
- **首頁與掃描紀錄：** 首頁介紹 App，底部浮著「開始掃描」；點「掃描紀錄」卡片才開啟封面格狀清單，「選取」可多選刪除。
- **掃描 HUD：**
  - 一個狀態膠囊與一個依優先序的提示插槽。
  - 只在掃描中出現的工具列。
  - 快門外圈顯示 LiDAR 視角涵蓋率，也就是被看過 30° 以上的表面佔比；熱圖以同樣的角度跨度為每塊表面上色（[視角涵蓋](docs/LIDAR_QUALITY_AND_PREVIEW.zh-TW.md#視角涵蓋熱圖)）。
  - 只有一顆「掃描設定」，同時標示目前模式；可捲動面板調整掃描模式、品質、相機與座標系。
- **檢視與歷史：** 浮動面板放數據，以及同一種卡片樣式的掃描動作：「訓練 3DGS」、「匯出 3DGS 訓練資料」（完成後變成「分享掃描」），歷史頁另有「掃描品質資訊」；掃描控制放在下方的次要按鈕。歷史的「更多操作」包含空間尺度驗證、資料優化與刪除。分享使用系統分享表並傳送檔案本身，LINE、Teams 等 App 會收到 ZIP 檔。

表面重建會明確顯示已包含姿態精修；若要獨立調整精修，請先關閉表面重建。刪除仍需確認，並移除所選掃描的完整資料。觸控範圍至少 44 點並有輔助使用標籤，所有操作均提供繁體中文與英文。設計系統、畫面狀態、橫直向與 iPad 版面，以及 Simulator 預覽參數詳見[介面設計](docs/INTERFACE_DESIGN.zh-TW.md)。

## 掃描模式與品質

### LiDAR 與純相機模式

| 模式 | 採集與重建 |
| --- | --- |
| LiDAR 開啟 | RGB、相機姿態、感測深度與可信度；可使用 mesh 補洞、RoomPlan 與 LiDAR 輔助姿態精修 |
| LiDAR 關閉 | RGB、相機姿態、經驗證的稀疏特徵點；可在停止後用多視角照片估算幾何，不保存 LiDAR 深度 |

模式只能在開拍前切換。`capture-meta.json` 分別記錄硬體能力 `lidarAvailable` 與本次選擇 `lidarEnabled`。開關控制 App 請求與使用的深度功能，不是感測器電源控制，也無法保證 ARKit 內部完全不用 LiDAR。

相機模式依賴紋理、清晰度與視差，不能把影像推估深度視為感測器量測。相機模式停止掃描後會依序執行兩步。先以純影像特徵追蹤與光束法平差（ARKit 逐幀運動為先驗）精修相機姿態，是否套用由保留集決定；再以 PatchMatch 多視角立體為最多 48 個視角估計深度圖，只保留相鄰視角確認過的深度。重播兩份掃描約得到 18,000–19,000 點，5 cm 內涵蓋 LiDAR 表面的 14–29%（先前的影像重建不到 8%），約 4% 的點離表面超過 10 cm。詳見 [相機模式精度](docs/CAMERA_ONLY_ACCURACY.zh-TW.md)。

### 厚層、重影與姿態精修

- 重融合優先選不同位置的參考深度；需要多視角支持，再沿原相機射線作最多 2 cm 的共識修正。
- 修正前後檢查可信度、深度邊界、遮擋與自由空間矛盾；mesh 補點同樣需要支持，避免重新補回厚層。
- 「精細掃描」逐張匹配影像，以保持 ARKit 相鄰影格運動的聯合光束法平差精修相機，並把以姿態引導、依平面變形匹配的重訪視角加入同一次求解（見[重訪視角精修](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md#重訪視角精修)）；使用自訂演算法，沒有移植 COLMAP／Ceres。局部姿態精修會先沿路線試算，通過才完整執行；試算被拒絕時保留已接受姿態，TSDF 仍繼續。照片驗證也會檢查修正後失去投影的樣本。結果須通過保留觀測與照片對齊檢查（比對重疊影格的影像紋理）才套用。兩份掃描的桌機重跑中，舊精修未通過此檢查；新精修讓寬基線 NCC 中位數提高約 0.02，局部表面階段則被拒絕。資料不足或驗證失敗時保留既有姿態。詳見[姿態精修](docs/POSE_REFINEMENT.zh-TW.md)。
- RGB 照片選用與深度融合分開：實際清晰度與視角差異決定訓練照片，可靠深度仍可保留。原始照片不因篩選而刪除。

569 幀掃描的局部厚度中位數曾由 8.94 降到 7.01 cm（約 21.6%）。這是固定局部區域的表面一致性量測，包含真實家具／多層結構，**不是絕對尺寸精度，也不保證 3DGS 無殘影**。方法、效能代價與限制見 [LiDAR 表面共識](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md)。

3 公尺以外的深度使用獨立的 4 公分格，避免遠距雜訊迫使近距表面粗化。**新增覆蓋保護為實驗選項，預設關閉**：以最終表面檢查缺口與邊界，並在可見性清理保護局部區域。實際重播找回部分覆蓋，但局部厚度增加，因此維持正式預設融合行為；不能宣稱尺寸精度已提升。見[距離優先](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md)與[覆蓋驗證及重播結果](docs/SCAN_FUSION_DIAGNOSTICS.zh-TW.md)。

### 大場景記憶體

逐幀讀取照片與深度，參考深度快取上限 8 幀／2 MiB；融合 grid 依記憶體預算限制並在必要時粗化，手機輸出點數上限目前為 250,000。這些限制用於掃描後處理，不代表可以無限制提高點數；手機端 3DGS 訓練另有自己的記憶體配置。

已有 1,000 幀合成深度串流測試，並保留取消與低記憶體回退。這不是實機長時間掃描不閃退的保證。詳見 [大場景記憶體](docs/LARGE_SCAN_MEMORY.zh-TW.md) 與 [採集吞吐量](docs/CAPTURE_THROUGHPUT.zh-TW.md)。

兩次 iPhone 17 Pro 閃退已定位為融合達 100% 後的 stderr 日誌寫入例外，已改用系統日誌。處理前清除採集快取、停止被遮住的相機渲染，插入／粗化內部檢查壓力，並預留 192 MiB 加單幀工作區；回退仍保留原始資料。詳見[裝置證據與記憶體控制](docs/LARGE_SCAN_MEMORY.zh-TW.md)。

## 歷史、回放與刪除

停止後自動保存預覽與摘要，不必先匯出。首頁「掃描紀錄」可開啟既有掃描：

- **拍攝影像**：照片與橘色相機位置／方向同步，支援跟隨或完整路線檢視；換圖完成前保留上一張，避免輪播閃爍。預覽按姿態旋正，原始 JPEG 不變。
- **播放速度**：0.5、1、2、5、10、15、30 fps；這是已保存關鍵影格的播放速度，不是原始等速影片。
- **優化訓練資料**：在手機重新處理照片、姿態與點雲，完成後另存新版本；此操作不執行 Gaussian 訓練。詳見 [手機端資料優化](docs/ON_DEVICE_TRAINING_QUALITY.zh-TW.md)。
- **訓練 3DGS**（或「檢視 3DGS 模型」、「繼續訓練 3DGS」）：開啟這筆掃描的手機端訓練。卡片會標示訓練中、已有模型或可續訓；中斷的訓練從最後一個檢查點繼續。
- **空間尺度與驗證**：選點量距、輸入已知長度校正、另選參考距離驗證；可另存公尺 COLMAP ZIP，同步縮放相機與點雲，不附原始深度。參考通過不代表整體精度認證。詳見[閉環修正與公尺尺度](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md)。
- **多選／全部刪除**：移除選定掃描的完整資料夾與一般／公尺版 ZIP，包含照片、深度、姿態、點雲與模型。舊版掃描若有 `gaussians.ply`，也在整筆刪除範圍內；不影響未選紀錄、系統相簿或已分享出去的副本。

歷史紀錄可預覽與重處理；離開掃描工作階段後，不能從歷史頁直接恢復原本的即時續掃。

## 匯出資料

新掃描與歷史匯出都先產生完整 COLMAP 資料，再打包 ZIP。訓練影像清單以 `sparse/0/images.bin` 為準，`images/` 保留所有原始照片。

```text
scan_…/
├── images/                    # 感測器原始方向 JPEG
├── depth/                     # LiDAR 深度／可信度 sidecar（相機模式無此量測）
├── sparse/0/
│   ├── cameras.bin            # 逐幀內參
│   ├── images.bin             # 選用影像與 world-to-camera 姿態
│   └── points3D.bin           # 初始化點雲
├── points.ply                 # ARKit 世界座標點雲
├── poses.jsonl                # 原始採集姿態
├── poses_refined.jsonl        # 匯出所選影像的處理後姿態
├── capture-meta.json          # 裝置與掃描模式
├── review.ply                 # 歷史預覽點雲
├── review-poses.jsonl          # 預覽／回放姿態
├── scan-summary.json          # 影格數與點數
├── training-selection.json    # 照片選用與補拍提示
├── pose-refinement.json       # 若有執行相機精修，其驗證結果
└── refusion-progress.json     # 若有重融合，其耗時與資源資訊
```

新掃描使用 `capture-meta.json`；舊 `meta.json` 仍可讀取，匯出時自動改名，避免與外部訓練器的格式判斷衝突。兩者同時存在時優先使用新檔，舊檔另存為不衝突的 capture 中繼資料檔。

依啟用功能及成功結果，可能另有平面圖、世界地圖、影像重建及採集效能報告。手機端訓練寫在掃描內的 `gaussian-training/`（檢查點、狀態與 `model/gaussians.ply` 及附屬檔）；資料集 ZIP 不含這個資料夾，模型另有自己的 ZIP。舊版掃描既有模型仍隨原資料保留與分享。

COLMAP 相機與 `points3D.bin` 預設一起繞世界 X 軸旋轉 180°；`points.ply`、`review.ply` 與 JSONL 保留 ARKit 世界座標。不要把不同座標系的點雲與姿態直接混用。詳見 [座標系](docs/COORDINATES.zh-TW.md) 與 [歷史訓練匯出](docs/HISTORY_TRAINING_EXPORT.zh-TW.md)。

輸出模型用於提供校準相機與初始化點，沒有完整 SfM 特徵觀測與 tracks；不能只執行 COLMAP BA 就期待補出缺少的觀測。沒有種子點時仍可匯出空點集，但外部訓練器可能需要額外初始化。

## 程式結構

```text
arkit-3dgs-scanner.xcodeproj/               # Xcode 專案
arkit-3dgs-scanner/
├── ContentView.swift          # 首頁與入口
├── Capture/
│   ├── CaptureController.swift
│   ├── CancelFlag.swift       # 背景掃描工作的共用取消旗標
│   ├── FrameWriter.swift
│   ├── DepthSampleFilter.swift
│   ├── RefusionEngine.swift
│   ├── OfflinePoseRefinement.swift
│   ├── TrainingFrameSelector.swift  # 資料選幀，非訓練器
│   ├── ExportManager.swift
│   └── UI/                    # 掃描、驗收與匯出介面
├── History/                   # 紀錄、同步回放、重處理與完整刪除
└── Training/                  # 手機端 3DGS：Metal 核心、訓練器、記憶體配置、檢查點、匯出、檢視器與介面
tools/                         # 資料轉換、分析及回歸測試
docs/                          # 架構、座標、品質與效能說明
```

`Training/` 是以 Swift 與 Metal 全新實作的模組，不使用先前的 msplat C++ 引擎、Swift 橋接或專用建置設定。掃描、預覽與 COLMAP 資料準備不依賴訓練器。

## 開發與驗證

```sh
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project arkit-3dgs-scanner.xcodeproj -scheme arkit-3dgs-scanner \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`tools/test_*.swift` 涵蓋寫入、幾何一致性、深度快取、大場景、歷史匯出與回放；`tools/test_math.py` 驗證座標轉換。編譯與合成測試不能代替真機的感測器、精度、溫度和長時間記憶體驗證。

可選 Python 工具：

```sh
python3 -m venv .venv
.venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/test_math.py
.venv/bin/python tools/validate_dataset.py /path/to/scan
.venv/bin/python tools/arkit2gs.py /path/to/scan -o /path/to/dataset --format both
```

更多說明：[掃描架構](docs/CAPTURE_ARCHITECTURE.zh-TW.md)、[深度品質與即時預覽](docs/LIDAR_QUALITY_AND_PREVIEW.zh-TW.md)、[外部訓練說明](docs/TRAINING.zh-TW.md)。

## 雙語與開發流程

App 預設繁體中文，首頁可切 English 並保存選擇；文件英文優先，每份提供繁中對照。動態訊息、錯誤與無障礙標籤也支援雙語。詳見 [語系說明](docs/LOCALIZATION.zh-TW.md)。

融合後單純運動估計偏高不再出補拍警告，放在收合的品質資訊；有實測細節偏弱才顯示需檢查的影格。這不會去除照片模糊，也不更動原照片／可靠深度。

遵循 [貢獻流程](CONTRIBUTING.zh-TW.md)與 [工作規範](AGENTS.zh-TW.md)：Feature/ 新功能、Bugfix/ 修錯、Enhance/ 改善，區分大小寫。完成驗證後 commit/push、開 PR、必要檢查通過後合併，刪除本次遠端與本機分支，回到 main；不繞過保護。

```sh
python3 tools/check_project.py
bash tools/test_localization.sh
bash tools/test_training_quality.sh
bash tools/test_gaussian_training.sh
bash tools/test_metric_loop.sh
bash tools/test_fusion_memory.sh
```

## 授權

Copyright 2026 Kuo Feng-Yuan（[KuoFengYuan](https://github.com/KuoFengYuan)）。本專案採用 [Apache License 2.0](LICENSE)。

**本專案為個人研究專案**，並非任何雇主或機構的產品，未經其背書，也不代表其立場。本專案依現狀提供，不附任何擔保。

- **可以商用**，包含手機端 3DGS 訓練器；也可以修改與再散布。
- **必須標註作者**：任何複製或衍生作品都要保留 [LICENSE](LICENSE) 與 [NOTICE](NOTICE)，並註明原作者為 Kuo Feng-Yuan（KuoFengYuan）。
- 3DGS 訓練器是以 Swift 與 Metal 獨立實作。其中不含原版 3D Gaussian Splatting（Inria／MPII）與 Mip-Splatting 的程式碼，這兩者只允許非商用；也不含 LichtFeld Studio（GPL-3.0）的程式碼。參考的論文與專案列在 [NOTICE](NOTICE)。
- 部分方法仍可能涉及第三方專利；以上不構成法律意見，商用前請自行確認。

## 文件索引

- [掃描架構](docs/CAPTURE_ARCHITECTURE.zh-TW.md)
- [介面設計](docs/INTERFACE_DESIGN.zh-TW.md)
- [姿態精修與照片對齊驗證](docs/POSE_REFINEMENT.zh-TW.md)
- [閉環修正與公尺尺度](docs/LOOP_CLOSURE_AND_SCALE.zh-TW.md)
- [手機端 3DGS 訓練](docs/ON_DEVICE_3DGS.zh-TW.md)
- [手機端資料優化](docs/ON_DEVICE_TRAINING_QUALITY.zh-TW.md)
- [LiDAR 多視角共識](docs/LIDAR_SURFACE_CONSENSUS.zh-TW.md)
- [無 LiDAR 重建](docs/CAMERA_ONLY_ACCURACY.zh-TW.md)
- [歷史匯出](docs/HISTORY_TRAINING_EXPORT.zh-TW.md)
- [外部訓練](docs/TRAINING.zh-TW.md)
- [拍攝吞吐量](docs/CAPTURE_THROUGHPUT.zh-TW.md)
- [即時預覽與品質閘門](docs/LIDAR_QUALITY_AND_PREVIEW.zh-TW.md)
- [大場景記憶體](docs/LARGE_SCAN_MEMORY.zh-TW.md)
- [座標慣例](docs/COORDINATES.zh-TW.md)
- [裝置操作](docs/DEVICE_NOTES.zh-TW.md)
