# LeNet Accelerator — RTL Optimization Report

> **版本：** Revised 2026-11-08 ｜**範圍：** V0–V9 ｜**設計：** 5-Layer Quantized LeNet（SystemVerilog）  
> **目的：** 紀錄「為什麼改、怎麼改、硬體實測差異、是否通過驗證」，作為 GitHub 與專案面試的可追溯技術文件。  
> **資料依據：** 原 `Optimization(3).md` 的 DC 報告與使用者回報。原稿保留作為歷史存檔；本檔是重整版。

## 1. Executive Summary

專案在 **10 ns 目標時脈**下，先以 **Combinational Logic 簡化與跨 Layer 資源共享**降低面積，再以 **Zero-Activation Group Skipping**縮短執行週期。

| 比較項目 | Baseline V0 | 最低面積 V7 | 最新／最快 V9 |
|---|---:|---:|---:|
| DC Total Cell Area | 947,242.55 | **498,037.52** | 505,781.06 |
| 相對 V0 的面積降幅 | — | **47.42%** | **46.60%** |
| Cycle Count¹ | 31,497 | 31,497 | **29,481** |
| 10 ns 對應運算時間² | 314.97 µs | 314.97 µs | **294.81 µs** |
| Golden / GLS / Setup Timing | 時序 PASS*；其他記錄不足 | **全部 PASS*** | **全部 PASS*** |

**核心成果**

- **V7：面積最低**，相對 V0 減少 **449,205.03**（−47.42%），且不增加執行週期。
- **V9：運算週期最低**，相對未加入 Zero Skipping 的 V7 減少 **2,016 cycles（−6.40%）**，面積則比 V7 **增加 1.55%**。
- **V9 vs V8：** 面積 +1.31% 換取 Cycle −5.39%；若僅用 DC Cell Area × 10 ns × Cycles 當作*代理指標*，改善約 4.15%，**不是實測能量或 PPA**。
- **建議保留版本：** V7（Area Baseline）、V8（FC1 Skip 單獨實驗）、V9（最新完整架構／最快版本）。

¹ V0～V3A 的 Cycle Count 在原稿總表列為 31,497（回報），但缺少逐版本的原始 Cycle Log；**明確逐版確認的連續紀錄從 V3B 開始**。  
² 運算時間按 `cycles × 10 ns` 推算，不是晶片實測延遲。  
`*`：PASS 由使用者回報，非本文件附帶的原始 Timing／Golden／GLS Log 所獨立證明。

## 2. 量測條件與證據界線

| 項目 | 條件／限制 |
|---|---|
| RTL / Design | SystemVerilog；Top：`lenet`；CONV1、CONV2、CONV3、FC1、FC2 |
| SRAM 介面 | Activation、Weight 各一組 Dual-Port SRAM；每 Port 32-bit |
| Synthesis | Synopsys Design Compiler T-2022.03，`CBDK_IC_Contest_v2.5 / slow.db` |
| 製程 | 原始紀錄稱 0.13 µm；實際製程與 Cell Area 單位請以 Library 定義為準 |
| Clock | 10 ns 目標；V3B～V9 Setup Timing PASS（使用者回報） |
| Area | 報表的 **Total Cell Area**，不是 Floorplan Core Area 或實際晶片尺寸 |
| SRAM 宏 | DC 報表 Macro / Black Box = 0；**不能推論 SRAM Macro 實體面積已包含** |
| 佈線 / Power | `Net Interconnect area: undefined`；尚未有完整 Power 或 Post-Route PPA |
| Traceability | 各版完整 SDC、compile options、WNS/TNS、原始 GLS/Golden Log、Git Commit 仍待歸檔 |

**統計原則：** 對每項優化以 **Top Total Cell Area 的相鄰版本差值**作為淨面積收益；新建立的 Shared Module 仍占面積，**不可只相加 Layer 階層縮減量**。`Buf/Inv Area` 已包含在 Combinational Area 裡，不可重複加總。

## 3. 完整版本總覽

> **Area Δ 前版：** 負值代表節省，正值代表增加。**相對 V0：** 均為 Total Cell Area 改善率；V8/V9 的目標已轉為縮短 Cycle。

| 版本 | 本次主要修改 | DC Total Cell Area | Area Δ 前版 | 相對 V0 | Cycles¹ |
|---|---|---:|---:|---:|---:|
| V0 | Baseline | 947,242.55 | — | — | 31,497¹ |
| V1 | OPT-01：CONV2 Pool→Quant 重排 | 866,592.29 | -80,650.26 (-8.51%) | 8.51% | 31,497¹ |
| V2 | OPT-02：FC Buffer Banked Read | 758,936.39 | -107,655.90 (-12.42%) | 19.88% | 31,497¹ |
| V2.1 | Gate Sim RTL 修正（非新 OPT） | 759,562.73 | 626.34 (+0.08%) | 19.81% | 31,497¹ |
| V3A | OPT-03A：Static Write Decoder | 759,250.41 | -312.32 (-0.04%) | 19.85% | 31,497¹ |
| V3B | OPT-03B：Window Read MUX | 699,094.55 | -60,155.86 (-7.92%) | 26.20% | 31,497 |
| V4 | OPT-04B：CONV1/2 Shared PE | 636,574.22 | -62,520.33 (-8.94%) | 32.80% | 31,497 |
| V5 | OPT-05：五層 Unified 5-PE | 565,724.74 | -70,849.48 (-11.13%) | 40.28% | 31,497 |
| V6 | OPT-06：Shared Channel PSUM | 552,503.69 | -13,221.05 (-2.34%) | 41.67% | 31,497 |
| **V7** | OPT-07A：Shared ReLU + Quantizer | 498,037.52 | -54,466.17 (-9.86%) | 47.42% | 31,497 |
| V8 | OPT-08A：FC1 Zero-Group Skip | 499,220.61 | 1,183.09 (+0.24%) | 47.30% | 31,161 |
| **V9** | OPT-08B：CONV3 Zero-Group Skip | 505,781.06 | 6,560.45 (+1.31%) | 46.60% | 29,481 |

**驗證摘要：** V0、V1 曾回報 10 ns PASS，但早期 Golden／GLS 缺乏逐版明確紀錄；V2、V2.1、V3A 只有 Area Report 可明確支持，不能把後續 V3B 的 PASS 回填。**V3B～V9：Golden、Gate-Level Simulation、10 ns Timing 均 PASS（使用者回報）**。所有版本的實際 WNS／TNS 均尚未在本文件附原始報告。

## 4. Optimization Details

以下按**三個設計階段**排列，每個 OPT 只記一次「問題 → 解法 → 量測 → 注意事項」，避免與版本總表重複敘述。

### Phase A — 消除不必要的組合邏輯（V1～V3B）

#### OPT-01｜CONV2：先 Max Pool、後 Quantization（V1）

- **問題：** V0 的 2×2 Pool Window 對四個 32-bit PSUM 各量化一次，再比較四個 8-bit 結果；合成出四組大型量化乘法邏輯。
- **修改：** 先用 signed 比較器取得 `pool_psum_max`，只對最大值做一次 ReLU／Scale Quantization。需滿足當前 `quantize_psum()` 為單調不減的數值條件，並核對 signedness／溢位／saturation。
- **合成成果：** Top **947,242.55 → 866,592.29（−8.51%）**；`u_conv2` **248,871.09 → 168,253.08（−32.39%）**。Sequential Cells 不變，主要節省組合邏輯。
- **驗證／注意：** 10 ns PASS（回報）；V1 Golden、GLS 原始結果仍未附。四顆乘法器原先面積相加不等於實際節省的 Top 面積。

#### OPT-02｜FC Buffer：8-Byte Aligned Banked Read（V2；V2.1 為修正版）

- **問題：** 原 `fc_buf[fc_buf_raddr + lane]` 逐 Byte 動態選取，造成大量 Wide MUX，但合法讀址原本就為 8-Byte 對齊。
- **修改：** 將 120 × 8-bit 改成 **15 × 64-bit Bank**，使用 `raddr[6:3]` 做 Bank Selection，仍維持組合讀取；處理單 Byte Write、RELOAD84 Byte Mask 與 `reload_we` 優先權。
- **合成成果：** `u_fc_buffer` **165,352.22 → 56,964.74（−65.55%）**；Top **866,592.29 → 758,936.39（−12.42%）**；儲存位元數並未減少，下降來自 Read MUX。
- **V2.1：** Gate Simulation 相關 RTL 修正後，Top **758,936.39 → 759,562.73（+0.083%）**，FC Buffer Area 仍是 56,964.74；**這不是另一項面積最佳化**。
- **驗證／注意：** V2、V2.1 個別 Golden／GLS／Timing PASS 未附；Bank Address、Byte Order 與 RELOAD84 最後一個 4-Byte Group 需要保留回歸測試。

#### OPT-03A｜Shared Line Buffer：Static Write Decoder（V3A，效果不顯著）

- **修改：** 嘗試以固定 Row／Block Decode 取代動態寫入選擇。
- **合成結果：** Top **759,562.73 → 759,250.41（−0.041%）**，但目標模組 `u_shared_line_buffer` **157,744.47 → 157,863.29（+0.075%）**。
- **結論：** **未證實有效改善目標 Buffer 面積**；保留為 A/B 實驗，不將微小 Top 波動視為架構成果。Golden／Timing／GLS 個別證據待補。

#### OPT-03B｜Shared Line Buffer：Window Read MUX（V3B）

- **問題：** 5×5 Window 直接用 `line_buffer[r][col+c]`，每個 Byte 的動態索引產生昂貴的 MUX。
- **修改：** 改成 **8-Byte Chunk Selection → Byte Shift → Row Selection**；保留 CONV1 Row Shift、CONV2 Reload、CONV3 Vector Mode。
- **合成成果：** `u_shared_line_buffer` **157,863.29 → 99,075.54（−37.24%）**；Top **759,250.41 → 699,094.55（−7.92%）**；Sequential Cells 維持 6,601。
- **驗證：** Golden／GLS／10 ns Timing PASS，**31,497 cycles**（使用者回報）。此為第一次連續明確回報完整驗證的基準版。

### Phase B — 跨 Layer 資源共享（V4～V7）

#### OPT-04B｜CONV1／CONV2 共用 PE（V4）

- **問題：** 兩層由 Top FSM 依序運算，卻各自具有 5 個 PE，造成重複的乘法器與加法器。
- **修改：** 將兩層合併為唯一 `u_shared_pe_array`：5 個 PE，每個 PE 含 5-Lane MAC；Layer Controller／Valid 仍各自維持。
- **合成成果：** Top **699,094.55 → 636,574.22（−8.94%）**；新 `u_shared_pe_array` 面積 **62,705.35**，必須計入整體成本。
- **驗證：** 由 Hierarchy 看見 5 個 PE 實例；Golden／GLS／10 ns Timing PASS，**31,497 cycles**（回報）。

#### OPT-05｜五個 Layer 共用同一組 5-PE Array（V5）

- **修改：** CONV3、FC1、FC2 取消各自 2 個 PE，改分時使用 `shared_pe_array` 的 **PE0～PE1**；CONV1／CONV2 則使用 **PE0～PE4**。Top 加入 Operand、Valid、Result 的路由選擇，各層仍保留 PSUM 與 Controller。
- **合成成果：** Top **636,574.22 → 565,724.74（−11.13%）**；五層實體 PE 合計仍只有 **5 個**（不代表晶片其他量化或算術乘法器不存在）。
- **驗證：** DC Hierarchy 支持五顆共享 PE；Golden／GLS／10 ns Timing PASS，**31,497 cycles**（回報）。

#### OPT-06｜CONV2／FC2 共用 Channel PSUM Buffer（V6）

- **修改：** 兩層原本各自的 `2 × 10 × 32-bit` Channel PSUM 暫存，改在 Top 建立唯一 **640-bit `u_shared_ch_temp_buffer`**；保留 CONV2 Pooling 與 FC2 MAC／Bias／Output 的讀寫模式。
- **合成成果：** Sequential Cells **6,601 → 5,961（−640）**；Noncombinational Area **−20,482.53**，Combinational Area **+7,261.48**（新增讀寫 MUX 等）。Top 淨改善 **565,724.74 → 552,503.69（−2.34%）**。
- **驗證：** Golden／GLS／10 ns Timing PASS，**31,497 cycles**（回報）。640 個 Sequential Cells 減少符合預期儲存容量，但不能只靠數目逐顆證明對應關係。

#### OPT-07A｜四個 Layer 共用 ReLU + Quantizer（V7）

- **問題：** CONV1、CONV2、CONV3、FC1 各自具有 Scale Multiply／Shift／Saturation，導致重複的大型量化乘法器。
- **修改：** 在 Top 建立唯一 `u_shared_quantizer`，四層依 FSM 選擇 **PSUM + Scale**，量化器維持 Combinational，結果回到各層既有 FF／Pooling 時序；FC2 不參與量化路徑。
- **合成成果：** `u_shared_quantizer` 面積 **51,470.26**（內含大型 `mult_18`，不能重複加總）；Top **552,503.69 → 498,037.52（−9.86%）**，主要為 Combinational Area 下降 **54,883.73**。
- **驗證：** Golden／GLS／10 ns Timing PASS，**31,497 cycles**（回報）。**V7 為全紀錄最低面積版本**。
- **數值行為：** CONV1 維持 **Quantize → 8-bit Pool**；CONV2 維持 **32-bit PSUM Pool → Quantize**，未任意交換 Pipeline 順序。

### Phase C — 以少量面積交換執行週期（V8～V9）

#### OPT-08A｜FC1 Zero-Activation Group Skipping（V8）

- **問題：** FC1 120 筆 Activation 分成 15 組 × 8 Bytes，若整組皆為零，仍會浪費一次 Group Issue、Weight Read 與 MAC。
- **修改：** 用 `fc1_group_nonzero[14:0]` 動態標記 Group；Priority Selector 找下一個非零 Group，Activation／Weight 位址及 Pipeline Group Index 同步跳轉；保守版**強制保留 Group 0、14**，以維持 First／Last PSUM 判斷。
- **本次 Golden 的理論收益：** 4 個中間全零 Group × 84 個輸出 = **336 個 Group**；實測 Cycle **31,497 → 31,161（−336，−1.07%）**。
- **合成成本：** Top Area **498,037.52 → 499,220.61（+0.24%）**；Golden／GLS／10 ns Timing PASS（回報）。此版用於隔離 FC1 Skip 的效益，**不是最低面積版**。

#### OPT-08B｜CONV3 Zero-Activation Group Skipping（V9）

- **修改：** 依方案在 CONV2 輸出 SRAM 寫入時建立 50 組、每組 8 Bytes 的動態非零資訊；CONV3 的 Activation、Weight Address 與 Group Metadata 同步跳轉；保守版**強制保留 Group 0、49**。
- **本次 Golden 的理論收益：** 15 個全零 Group 中可跳 14 個 × 120 Neurons = **1,680 Group**；實測 Cycle **31,161 → 29,481（−1,680，−5.39%）**。
- **合成成本：** Top Area **499,220.61 → 505,781.06（+1.31%）**；Golden／GLS／10 ns Timing PASS（回報）。V9 相較 V7 累計省 **2,016 cycles（−6.40%）**。
- **重要限制：** Group Bitmap 不可硬編碼 Golden 的零值索引，須隨每次輸入動態生成；全部零 Group／沒有零 Group／首尾 Group 和多 Pattern 仍需 Directed Tests。

## 5. 目前硬體架構與成本位置（V9）

**運算共享**：同一組 5 個 PE 分時執行五層 MAC；另有單一 Shared ReLU+Quantizer。**儲存共享**：Shared Line Buffer、15×64-bit FC Buffer，以及 CONV2／FC2 共用的 640-bit Channel PSUM Buffer。

| V9 主要模組 | Cell Area | Top 比例 |
|---|---:|---:|
| `u_shared_line_buffer` | 101,546.95 | 20.1% |
| `u_shared_pe_array` | 69,987.20 | 13.8% |
| `u_shared_ch_temp_buffer` | 58,641.77 | 11.6% |
| `u_fc_buffer` | 56,582.83 | 11.2% |
| `u_shared_quantizer` | 52,680.51 | 10.4% |

**解讀：** 這是五個模組各自的階層面積，沒有將其 Child Instance 另加一次。大模組不代表能無成本地再合併；進一步縮減通常需改動 MUX、多讀埠或資料流，可能讓 10 ns Timing 變差。

## 6. 驗證結果與交付前確認

### 6.1 驗證狀態

| 範圍 | Golden | GLS | 10 ns Setup | Cycle Count | 判定 |
|---|---|---|---|---|---|
| V0～V1 | 個別證據不足 | 個別證據不足 | **PASS（回報）** | 31,497¹ | 只將 Area／部分 Timing 視為已知 |
| V2、V2.1、V3A | 個別證據不足 | 個別證據不足 | 未附 | 31,497¹ | 僅以 DC Area Report 直接支持 |
| **V3B～V7** | **PASS*** | **PASS*** | **PASS*** | **31,497** | 面積最佳化階段完成 |
| **V8** | **PASS*** | **PASS*** | **PASS*** | **31,161** | FC1 Skip 單獨實驗完成 |
| **V9** | **PASS*** | **PASS*** | **PASS*** | **29,481** | 最新完整版本（使用者回報） |

`*` 表示依使用者回報；仍需歸檔原始 Log、測試 Pattern、SDC、WNS/TNS、是否套用 SDF 的 GLS 設定。10 ns 是 **Setup 目標與 PASS 回報**，不能由 Clock Period 設定值自行推定 Timing 已收斂。

### 6.2 最後建議回歸測試

- **多個不同輸入 Pattern**，包括沒有零 Group、連續全零 Group、全部為零、首尾 Group 零值，確認 Zero Bitmap 會更新且不會因跳過最後 Group 卡住。
- **Group Index 與有效訊號**：Activation SRAM／Weight SRAM 的地址、`pe_valid`、PSUM First／Last、Pipeline `valid` 與 Done 拍點保持同步。
- **Memory 邊界**：FC Buffer 對齊讀取、RELOAD84 最後一組 Byte Mask、Line Buffer Chunk 邊界、CONV2/FC2 PSUM Read-Modify-Write。
- **Timing／Netlist 檢查**：補存 `report_timing`（WNS/TNS、Critical Path）、Lint/Latch/Multiple Driver/Width Warnings；確認 GLS 是否進行 SDF Back-Annotation。
- **專案可重現**：每個重要版本的 RTL Snapshot／Git Tag、testbench 設定、Filelist、SDC／DC Script、Golden 與 GLS Log。

## 7. 後續決策與維護方式

**目前：先將 V9 視為 RTL 架構最佳化的收尾版本。** FC2 Zero-Group Skip 在本次 Golden 的可跳過 Group 少、潛在 Cycle 收益小；而把 CONV1/CONV2 Pooling 強行合併會新增模式與控制風險。除非先確認新的重大瓶頸，否則把時間花在多 Pattern 驗證與完整專案文件更有價值。

未來若新增 OPT，請固定記錄：**動機 → RTL 變更（檔案/Commit）→ Top Area、模組 Area、Cells → Cycle/Latency → Golden、Timing、GLS → 取捨與是否保留**。不要重複在不同章節各寫一次量測表。

---


