# 掃描架構與操作流程

## 責任邊界

| 元件 | 責任 |
| --- | --- |
| `CaptureSessionConfiguration` | 集中建立 ARKit 設定，按裝置能力與 LiDAR 開關啟用深度與網格；只有新 session 可以載入世界地圖。移除已無使用者的平面偵測。 |
| `CaptureSessionState` | 相機權限、初始化、追蹤、中斷、失敗的單一狀態來源。只有 `ready` 允許抓幀。 |
| `CaptureController` | MainActor 上協調掃描、後處理、驗收、訓練、匯出；UI 不直接修改 phase。 |
| `FrameWriter` | Actor 中完成 JPEG、深度與姿態寫入，錯誤向上傳遞；成功之後才回報已儲存影像。 |
| `PointCloudAccumulator` / `PointCloudFusion` | 背景融合與點雲預覽；以錨點局部座標融合並套用最終錨點修正，保留背壓與節流。 |
| `DepthSampleFilter` | 即時與離線融合共用的深度邊緣、信心值與入射角檢查。 |
| `ScanLibrary` | Actor 管理磁碟掃描、預覽快照、舊資料重建、打包與刪除。 |
| `ScanHistoryView` | 掃描列表、模式標記、3D／照片預覽與刪除確認。 |
| `ScanRoutePlaybackView` / `PlaybackCameraPose` | 雙畫面回放、影格進度、跟隨相機及全螢幕。 |
| `ExportManager` | 在背景產生 COLMAP 與 ZIP；以暫存檔完成 ZIP 後才發布正式檔案。 |
| `CaptureView` / `HUDOverlay` | 生命週期通知、操作可用性、權限恢復入口、分階段導引。 |

資料工作階段與相機狀態分離。例如 `scanning + relocalizing` 表示掃描仍存在，但暫停接受影像；`review` 表示後處理與 session 暫停已完成，可以安全續掃。

## 需要維持的條件

1. 新掃描先取得相機權限、確認追蹤正常；相機尚未就緒時，即使直接呼叫 `startScan()` 也不能建立資料集。
2. 進入背景時暫停 AR 與運動監測；回到掃描時不重設世界座標，等待追蹤正常才接受影像。系統權限提示造成的短暫 inactive 不視為切到背景。
3. 停止掃描先拒絕新幀，等寫入、特徵抽取與預覽融合完成，才讀取資料進行後處理。
4. RoomPlan 停止與 ARSession.pause 完成後才進入 review，避免先開放續掃、再被上一輪工作暫停。RoomPlan 最終建模仍可在背景完成。
5. 寫檔失敗不增加成功幀數；停止掃描並保留先前成功資料。已關閉的 writer 必須明確拒絕後續寫入。
6. COLMAP、平面圖 JSON/SVG/DXF 或 ZIP 寫入失敗後回到先前畫面，保留 writer 與資料供重試。ZIP 成功後才關閉 writer、進入 done。
7. 新掃描清除舊平面圖、統計與預覽資源。非同步平面圖／訓練回呼檢查工作識別碼，不能修改下一輪工作。
8. ARView 真正移除時才 teardown；開啟平面圖頁面不等同於離開掃描。

原生 RoomPlan 的 USDZ 匯出仍使用既有的可選輸出流程；此輪的錯誤傳遞涵蓋 COLMAP、PLY、姿態、JSON/SVG/DXF 與 ZIP。

## 操作體驗

首頁以「掃描 → 檢查與補掃 → 建立與分享」說明流程，採捲動版面與固定底部入口。掃描 HUD 顯示階段與具名快門，進階設定預設收合，權限拒絕提供系統設定入口。驗收時沒有可用影像不能匯出，沒有點雲不能建立模型；追蹤已失效時不能把新座標的資料接到既有掃描。

掃描、後處理、訓練進行中與匯出期間無法直接關閉畫面；先停止掃描／訓練或等待工作完成。離開尚未匯出的驗收畫面會說明資料保留位置，可從首頁歷史紀錄重新預覽、分享及刪除；離開後無法恢復原本的即時掃描工作階段。

## 精度與融合

- 追蹤需連續正常 0.6 秒才接受影像；追蹤丟失或影格間隔過長會重新等待穩定。
- 即時點雲優先使用原始 sceneDepth，避免以跨影格平滑深度作為主要融合輸入；原始深度不可用時才回退。即時與離線路徑共用四向深度邊緣、信心值、實際視線入射角及模糊權重。
- 空間磚依校正後的錨點位置尋找既有格子，降低錨點跨越世界網格邊界後重複建磚的機會；最後一幀未再看見的磚也套用最終錨點修正。
- 實測深度優先於 mesh 補點；mesh 不再把同格實測點的位置拉偏。合併格子時維持這個優先序。
- 姿態增量使用完整旋轉矩陣，避免一階近似累積尺度／剪切誤差。「精細掃描」預設開啟，有 LiDAR 時執行 6 輪局部 BA；保留集驗證未改善便不套用。這會增加停止後的處理時間。

這些改動修正可重現的融合誤差與資料品質風險，尚未量測真實場景的公分級誤差或效能增益。

## 歷史紀錄

每次停止掃描，在原始資料旁保存 `review.ply`、`review-poses.jsonl` 與 `scan-summary.json`。不必先匯出 ZIP 即可回到首頁預覽；原始影像及姿態仍保留。

列表直接讀取 `Documents/scans/scan_*`，因此舊版掃描也會出現。缺少預覽的舊資料會以有限影格與點數預算從深度重建；沒有深度時仍可翻閱照片。預覽最多顯示 120,000 點，並使用影像縮圖限制記憶體。歷史分享會打包現存檔案，不保證尚未正式匯出的掃描已含 COLMAP 訓練資料。

歷史列表可按「選取」逐筆勾選，或按「全選」，再執行「刪除所選」；一般列表底部另有「全部刪除」。確認視窗會顯示筆數，取消不更動檔案，處理期間停用操作及關閉手勢。

刪除會移除整個選定掃描資料夾及同名 ZIP，包含照片、Gaussian 模型（`gaussians.ply`）、平面圖模型（`floorplan.usdz`）、點雲、深度、姿態與 COLMAP 資料。系統相簿、已分享至其他 App 的副本與未選掃描不受影響。

整批路徑先驗證，再逐筆處理；重複選項只刪一次。全部刪除以確認時的列表快照為準，不包含確認之後新增的資料。部分失敗會顯示成功／失敗筆數並更新列表；未刪除的檔案會嘗試搬回供重試，回復失敗也不會清掉剩餘資料。

## 影像與點雲同步回放

歷史紀錄的「拍攝影像」分頁以雙畫面同步顯示拍攝照片與 3D 點雲。直向手機上下排列，橫向或寬螢幕左右排列；可播放／暫停、切換上一張／下一張、拖曳進度、全螢幕及重設點雲視角。照片保持原比例，點雲仍可旋轉、縮放和平移。

綠色線為拍攝路線，橘色視錐為當張照片的相機位置與朝向（ARKit 局部 -Z）。標記使用與歷史點雲相同的校正後姿態；照片以檔名配對，缺圖不會導致後續位置錯位。缺少姿態時保留照片並提示「此影像沒有對應位置」，不猜測位置。沒有點雲但有軌跡時仍顯示路線。

回放速度支援 0.5、1、2、5、10、15、30 fps，預設 2 fps，可在播放中調整並與全螢幕共用設定。以設定間隔逐張播放已儲存的關鍵影格，並非原始等速影片；可用左下角的拍攝相對時間辨識實際拍攝間隔。播放到最後會停止，可再次按播放重播；離開分頁、開啟全螢幕或 App 進入背景時暫停。切換影像只更新相機標記與跟隨視角，不重建點雲。預設從拍攝位置斜後上方自動跟隨，播放時以不超過 0.25 秒、且最多佔影格間隔 80% 的過渡同步移動與轉向；拖曳進度或前後切換直接定位。缺少有效姿態時不移動視角。

定位箭頭切換跟隨；「查看完整路線」暫停播放並還原全景。暫停後可手動旋轉／縮放，再按播放會重新對準當前位置並繼續跟隨。一般獨立的 3D 驗收頁不啟用跟隨。播放速度至少 10 fps 時，照片預覽最長邊降為 960 像素，暫停恢復原有預覽尺寸；原始檔案不變，實際 FPS 受裝置負載影響。

換圖採用保留上一張的方式：`ScanPhoto` 不再於每次請求開始時將 `image` 清空；解碼完成後在停用隱式動畫的更新中替換圖片，同時通知回放畫面。已取消的舊請求不能發布結果。首張未載入才顯示進度，缺檔或壞圖則顯示佔位圖並允許繼續播放。

點雲與拍攝時間使用 `displayedFrame`，而非尚在載入的目標影格。播放時若當張尚未回報成功或失敗，暫緩前進，避免高 FPS 持續取消解碼。調整 FPS／暫停而變更預覽解析度時也保留現有照片，原始影像不變。

`tools/test_scan_playback.swift` 的 4 組測試涵蓋缺圖／亂序配對、無效姿態與時間、校正姿態一致性、空紀錄及舊資料回退。模擬器建置通過；Computer Use 讀取 Simulator 持續逾時，因此本次未完成實際播放及畫面排版的 UI 驗證。

## LiDAR 開關與比較方法

在開始掃描前切換「LiDAR 深度掃描」。掃描期間不可切換，避免同一份資料混用兩種模式；切換會建立新的 AR 工作階段並取消載入上次世界地圖。

- **開啟**：使用深度與 mesh，並依設定提供 RoomPlan、深度融合與精細姿態校正。
- **關閉**：不請求 sceneDepth、smoothedSceneDepth、sceneReconstruction，也不啟動 RoomPlan 或儲存深度；保留 RGB、ARKit 姿態及稀疏特徵點雲。這條路徑尚未加入純 RGB 稠密重建。
- `meta.json` 分別記錄硬體能力 `lidarAvailable` 與本次模式 `lidarEnabled`，歷史列表顯示開／關。舊資料若無新欄位，沿用原有硬體標記。

此開關控制 App 請求與使用的深度功能，不能保證 ARKit 內部追蹤完全不使用 LiDAR，亦非感測器電源控制；若需要嚴格的無 LiDAR 硬體對照，須另用不具 LiDAR 的裝置。

比較時固定場景、光線、走路路徑、相機設定與拍攝距離，分別開／關各掃一次。兩次皆先關閉「精細掃描」，避免把姿態後處理差異混入比較；再另測校正效果。從歷史紀錄比對點雲覆蓋、牆面厚度、邊緣重影、照片清晰度，並用已知長度物件檢查尺寸誤差。點數較多本身不代表精度較高。

## 驗證

iPhone 目標不簽章建置：

```sh
xcodebuild -project fable.xcodeproj -scheme fable -configuration Debug \
  -sdk iphoneos -derivedDataPath /tmp/fable-build CODE_SIGNING_ALLOWED=NO build
```

macOS 上的實際 I/O 回歸測試（需允許 CoreVideo / IOSurface 存取）：

```sh
swiftc -module-cache-path /tmp/fable-swift-cache \
  fable/Capture/Models.swift fable/Capture/BlurFilter.swift \
  fable/Capture/FrameWriter.swift fable/Capture/ExportManager.swift \
  tools/test_capture_pipeline.swift -o /tmp/test_capture_pipeline
/tmp/test_capture_pipeline
```

測試涵蓋：JPEG／JSONL 成功落盤、注入寫入失敗後重試、成功紀錄計數、ZIP 取代、失敗保留前份 ZIP、暫存檔清理、關閉後拒絕寫入。

本次亦通過 iOS Simulator 建置與以下回歸測試：

| 測試 | 範圍 |
| --- | --- |
| `tools/test_capture_accuracy.swift`（18 項） | 追蹤穩定、旋轉剛性、四向深度邊界、信心值與入射角、非有限座標、實測優先與錨點跨格修正 |
| `tools/test_scan_library.swift`（8 組） | 保存／讀取、LiDAR 標記、舊資料相容、PLY 截斷檢查、單筆／多選／全部刪除完整資料樹、確認快照、批次路徑驗證與符號連結排除 |
| `tools/test_scan_playback.swift`（4 組） | 影像／姿態配對、無效資料、校正後座標與舊資料回退 |
| `tools/test_playback_camera.swift`（5 組） | 自動跟隨方向、位移、轉彎、垂直拍攝與無效姿態 |
| `tools/test_playback_timing.swift`（2 組） | FPS 與過渡時間界限、無效速度回退 |
| `tools/test_bundle_adjust.swift`（8 項） | 合成姿態校正、無效觀測及保留集拒絕退步結果 |
| `tools/test_voxel_shard.swift`（5 組） | 分片融合與參考結果一致、降採樣及空資料 |

新增多選／全部刪除的模擬器建置及 8 組歷史資料回歸測試通過；本次 Computer Use 連線逾時，新增選取介面尚未完成點擊驗證。以下 UI 檢查為前次單筆歷史功能的驗證結果。

iPhone 17 Pro 模擬器使用合成資料確認首頁／歷史入口、空列表、LiDAR 標記、3D 點雲載入、照片前後切換、刪除確認及 ZIP 打包。模擬器不提供實際 AR 掃描，LiDAR 開關的硬體效果仍待實機驗證。

仍須在 iPhone 實測以下情境；編譯、合成資料與 UI 測試不能代替感測器驗證：

- 首次允許／拒絕相機權限，從系統設定返回。
- 掃描中切到背景、回到相同位置、追蹤丟失及恢復。
- 快速結束後立刻續掃，確認座標連續且沒有晚到的 pause。
- 開啟平面圖再返回，確認仍可續掃與匯出。
- 停止發生在訓練準備期間，或剛開始／已產生預覽時。
- LiDAR 與無 LiDAR 裝置、橫直向、小螢幕、放大字體與 VoiceOver。
- 長時間掃描的記憶體、溫度與幀率；這一輪不宣稱量測到效能或重建精度提升。

API 行為依據：[Apple 相機權限文件](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:))、[ARSession 中斷通知](https://developer.apple.com/documentation/arkit/arsessionobserver/sessionwasinterrupted(_:))。

深度 API 參考：[Apple smoothedSceneDepth](https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth)。

自動跟隨相機的純數學回歸測試：

```sh
swiftc -O -module-cache-path /tmp/fable-swift-cache \
  fable/History/PlaybackCameraPose.swift tools/test_playback_camera.swift \
  -o /tmp/fable-follow-camera-test
/tmp/fable-follow-camera-test
```
