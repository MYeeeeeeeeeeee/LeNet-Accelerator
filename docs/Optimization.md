# LeNet Accelerator — Optimization Log

> 用途：記錄 RTL 架構最佳化、DC 面積與時序、功能驗證，以及每次修改的取捨。  
> 最後更新：2026-11-07  
> 專案：5-Layer Quantized LeNet Accelerator（SystemVerilog）
> **最新完整驗證版本：V7（OPT-07A：四層共用 ReLU + Quantization）｜Total Cell Area 498,037.52｜相較 V6 −9.86%｜相較 V0 累計 −47.42%｜Golden／10 ns Timing／Gate-Level Simulation 全部 PASS｜Cycle Count 31,497（不變；使用者回報）。**  
> **上一版 V6（OPT-06）：** CONV2／FC2 共用 640-bit Channel PSUM Buffer；Area **552,503.69**，較 V5 −2.34%，Sequential Cells −640。V7 進一步讓 CONV1／CONV2／CONV3／FC1 分時共用一組組合式 Quantizer，FC2 原有輸出路徑維持。DC 報告出現唯一 `u_shared_quantizer`（51,470.26）；Sequential Cells 由 5,961 微增為 5,966。

## 1. 最佳化目標與限制

- **主要目標：** 在不破壞 LeNet Golden Result 的前提下，減少 Standard-Cell Area。
- **時序目標：** 維持 **10 ns Clock Period**，不可只為省面積而造成 Setup Violation。
- **製程／Library：** 使用者表示為 **0.13 µm**；此份報告載入 `CBDK_IC_Contest_v2.5 / slow.db`。製程與面積單位應以 Library 資訊再次確認。
- **資料介面：** Activation / Weight SRAM 均為雙 Port、每 Port 32-bit；依 HW3 Spec 保留既定的 SRAM Layout、Top I/O 和輸出格式。
- **功能檢查：** RTL Simulation、Golden 比對、Lint／Latch／Multiple Driver、Synthesis Timing，最後再跑 Gate-Level Simulation。
- **最佳化原則：** 每次只改一個主要因素，保留 Git Commit、DC Report 和模擬結果，才能做公平比較。

## 2. Baseline：第一次 10 ns 合成

### 2.1 合成環境

| 項目 | 記錄 |
|---|---|
| 日期 | 2026-11-05 00:32:10（DC Report） |
| Tool | Synopsys Design Compiler T-2022.03 |
| Design | `lenet` |
| Library | `/usr/cad/Design_Kit/CBDK_IC_Contest_v2.5/SynopsysDC/db/slow.db` |
| Clock Constraint | 10 ns |
| Timing Result | **PASS（使用者回報）**；尚未附上 WNS／TNS／Critical Path Report |
| Area Report | `report_area.log` |
| RTL Snapshot | `hdl(1).zip`（請在 Git 標記對應 Commit） |

### 2.2 Overall Area

| 指標 | Baseline |
|---|---:|
| **Total Cell Area** | **947,242.55** |
| Combinational Cell Area | 733,825.06 |
| Noncombinational Cell Area | 213,417.49 |
| Buf / Inv Area | 36,860.74（報告單獨列示，**勿再加總一次**） |
| Total Cells | 75,699 |
| Combinational Cells | 68,143 |
| Sequential Cells | 6,597 |
| Macro / Black Box | 0 |
| Net Interconnect Area | Undefined（未指定 Wire Load） |

> 數值為 DC 報告的 Cell Area。以下以 **µm²** 表示時，以 .13 µm PDK 的面積單位為假設；**不是** Floorplan Core Area，也不是實際 Layout Area。報告無 Macro/Black Box Area，不能據此推斷 SRAM 實體 Macro 已被納入估算。

### 2.3 Hierarchical Area Breakdown

| Module | Cell Area | 佔總面積 |
|---|---:|---:|
| `u_conv2` | 248,871.09 | 26.3% |
| `u_fc_buffer` | 165,352.22 | 17.5% |
| `u_shared_line_buffer` | 157,500.04 | 16.6% |
| `u_conv1` | 109,465.33 | 11.6% |
| `u_fc2` | 83,206.55 | 8.8% |
| `u_fc1` | 80,246.28 | 8.5% |
| `u_conv3` | 76,450.90 | 8.1% |
| `u_reload_controller` | 10,092.74 | 1.1% |
| `u_shared_weight_buffer` | 9,199.91 | 1.0% |
| Top Local / Other | 約 6,858 | 約 0.7% |

**觀察：** `CONV2`、`FC Buffer`、`Shared Line Buffer` 合計約 **60.4%**，應先從這三項找出浪費，而不是繼續只縮減少量 FF。

### 2.4 V1：OPT-01 合成成果（2026-11-05 01:34:17）

> **已量測：Area 明顯下降；Timing 在 10 ns 條件下 PASS（使用者回報）。** 尚未取得 WNS／TNS、RTL Golden Result 或 Gate-Level Simulation 結果，不能視為所有驗證均完成。

| 項目 | V0 Baseline | V1（OPT-01） | 變化 |
|---|---:|---:|---:|
| **Total Cell Area** | **947,242.55** | **866,592.29** | **−80,650.26（−8.51%）** |
| Combinational Area | 733,825.06 | 653,256.27 | −80,568.79 |
| Noncombinational Area | 213,417.49 | 213,336.01 | −81.48 |
| Total Cells | 75,699 | 69,052 | −6,647 |
| Sequential Cells | 6,597 | 6,597 | 不變 |
| **`u_conv2` Area** | **248,871.09** | **168,253.08** | **−80,618.01（−32.39%）** |
| Clock / Timing | 10 ns／PASS（回報） | **10 ns／PASS（回報）** | Timing 目標維持 |
| WNS / TNS | 未附 Report | 未附 Report | 不填寫 |
| Golden / GLS | 待補 | **待驗證** | 不推定 PASS |

**觀察：** `u_conv2` 的 Area 減少 80,618.01，與整體下降的 80,650.26 接近；其餘層的微小增減可能來自重合成／最佳化差異，不應逕行解讀為另一項架構變更。此輪效果主要是 **Combinational Logic** 下降，而非減少 FF。V1 報告 `u_conv2` 列出一個大型 `mult_535_C577`（37,208.71）及三個比較器 `gt_568`、`gt_571`、`gt_574`，與「四次量化改為一次量化」的預期結構一致。要確認 RTL 實際寫法仍須對應的 V1 Commit / RTL Snapshot。

**報告：** V0 `report_area.log`；V1 `report_area(1).log`。兩份報告均顯示 `slow.db` / DC T-2022.03，但完整 SDC 和 Synthesis Options 尚未一併歸檔，精確可比性應再核對。

### 2.5 V2：OPT-02 合成成果（2026-11-05 09:53:06）

> **已量測：FC Buffer 由動態 Byte Index 改為 15 × 64-bit 對齊 Bank Read，Area 顯著下降。** 此輪僅收到 `report_area(2).log`；**V2 Timing、WNS／TNS、Golden／RTL Simulation、GLS 尚未提供，不得標記 PASS**。

| 指標 | V1（OPT-01） | V2（OPT-02） | V2 − V1 |
|---|---:|---:|---:|
| **Total Cell Area** | **866,592.29** | **758,936.39** | **−107,655.90（−12.42%）** |
| Combinational Area | 653,256.27 | 545,557.94 | −107,698.33 |
| Noncombinational Area | 213,336.01 | 213,378.45 | +42.43 |
| Buf / Inv Area（Combinational 內含） | 32,177.61 | 25,640.92 | −6,536.69 |
| Total Cells | 69,052 | 57,141 | −11,911 |
| Combinational Cells | 61,496 | 49,585 | −11,911 |
| Sequential Cells | 6,597 | 6,597 | 0 |
| **`u_fc_buffer` Total Area** | **165,352.22** | **56,964.74** | **−108,387.48（−65.55%）** |
| `u_fc_buffer` Combinational Area | 134,391.65 | 26,004.17 | −108,387.48（−80.65%） |
| `u_fc_buffer` Noncombinational Area | 30,960.58 | 30,960.58 | 0 |
| Clock Target | 10 ns | **尚待核對此輪 SDC** | 不以 Area Report 證明 Setup PASS |
| Setup / WNS / TNS | 10 ns PASS（使用者回報）；WNS 待補 | **待確認** | 需 `report_timing` |
| Golden / RTL Simulation / GLS | 待補 | **待確認** | 不推定等價 |

**與最初 V0 比較：** `947,242.55 → 758,936.39`，累計減少 **188,306.16（19.88%）**。V2 對 V1 的下降主要來自 FC Buffer 的 Combinational Area；Sequential Cells 沒有減少。`u_fc_buffer` 自身下降 108,387.48，略大於 Top Total Area 的下降 107,655.90，這是其他模組合成映射有少量面積增減所致，不能把單一模組變化直接等同總面積改善。

#### V2 主要模組面積（此版階層報告）

| Module | V1 Area | V2 Area | V2 佔總面積 |
|---|---:|---:|---:|
| `u_conv2` | 168,253.08 | 169,534.61 | 22.3% |
| `u_shared_line_buffer` | 157,673.18 | 157,623.95 | 20.8% |
| `u_conv1` | 109,300.68 | 109,047.77 | 14.4% |
| `u_fc2` | 82,972.31 | 83,181.09 | 11.0% |
| `u_fc1` | 79,957.72 | 79,927.17 | 10.5% |
| `u_conv3` | 76,909.19 | 76,503.52 | 10.1% |
| `u_fc_buffer` | 165,352.22 | 56,964.74 | 7.5% |
| `u_shared_weight_buffer` | 9,189.72 | 9,210.09 | 1.2% |

> `u_shared_weight_buffer` 的 V1 精確值請直接參照 `report_area(1).log`；本表不以推估值取代實測值。

**報告與版本追溯：** V2 `report_area(2).log`（DC T-2022.03，`slow.db`）。請補 Git Commit、RTL Snapshot、DC Script／SDC、Golden 與 Timing Reports，才能完整確認最佳化收益是否能在最終交付條件下保持。

### 2.6 V2.1：Gate-Level Simulation 相關 RTL 修正後重新合成（2026-11-05 20:12:46）

> **版本定位：** 使用者表示本版已針對 Gate Simulation 遇到的程式問題進行修正，並保留 OPT-02（FC Buffer 15 × 64-bit Banked Read）的修改。此版命名 **V2.1 / GS-Fix**，屬於 V2 之後的**功能／可模擬性修正版**，**不是**新增一項面積最佳化。此回合提供的是 `report_area(3).log`，只能直接證實合成後的面積與 Cell Count；**不能僅憑 Area Report 宣稱 Gate Simulation、Golden 或 10 ns Timing PASS**。

#### 合成版本與整體面積

| 項目 | V2：OPT-02 | **V2.1：GS-Fix** | V2.1 − V2 |
|---|---:|---:|---:|
| DC Report Date | 2026-11-05 09:53:06 | **2026-11-05 20:12:46** | — |
| **Total Cell Area** | **758,936.39** | **759,562.73** | **+626.34（+0.083%）** |
| Combinational Area | 545,557.94 | **545,994.17** | +436.23 |
| Noncombinational Area | 213,378.45 | **213,568.56** | +190.11 |
| Buf / Inv Area（已包含於 Combinational） | 25,640.92 | **26,005.87** | +364.94 |
| Total Cells | 57,141 | **57,213** | +72 |
| Combinational Cells | 49,585 | **49,653** | +68 |
| Sequential Cells | 6,597 | **6,601** | +4 |
| Macros / Black Boxes | 0 | **0** | 0 |
| **`u_fc_buffer` Total Area** | **56,964.74** | **56,964.74** | **0.00** |
| `u_fc_buffer` Combinational Area | 26,004.17 | **26,004.17** | 0.00 |
| `u_fc_buffer` Noncombinational Area | 30,960.58 | **30,960.58** | 0.00 |
| Timing（10 ns） | 未提供 Report | **未提供 Report，待確認** | 不可推定 PASS |
| Gate-Level Simulation | 待驗證 | **使用者表示已修正相關 RTL；PASS／FAIL 尚未提供** | 不可推定 PASS |
| Golden／RTL Simulation | 待補 | **待確認** | 不可推定 PASS |

**結論：** 這次 Gate Simulation 相關 RTL 修正之後，Top Cell Area 相較 V2 略增加 **626.34（+0.083%）**，可視為非常小的面積代價；FC Buffer 自身的 56,964.74 **完全不變**，所以 OPT-02 的 Banked Read 面積改善仍保留。Sequential Cells 由 6,597 變成 6,601，增加 **4 個**，但報告未提供逐一暫存元件對照，不能單憑數量斷定它們對應到哪幾個 RTL 訊號。

#### 與歷史版本比較

| 版本 | 改動定位 | Total Cell Area | 相較 V0 | 相較前一版 |
|---|---|---:|---:|---:|
| V0 | Shared Buffer 重構後 Baseline | 947,242.55 | — | — |
| V1 | OPT-01：CONV2 Max before Quantize | 866,592.29 | −8.51% | −8.51% |
| V2 | OPT-02：FC Buffer Banked Read | 758,936.39 | −19.88% | −12.42% |
| **V2.1** | **Gate Sim 相關 RTL 修正、保留 OPT-02** | **759,562.73** | **−19.81%** | **+0.083%** |

**相較 V0 累計面積減少：187,679.82（19.81%）。** 相較 V1 減少 **107,029.56（12.35%）**。這是**V2.1 當時**的實測數字；不可把 V2 的 758,936.39 當作 Gate Sim 修正後版本的面積。

#### V2.1 當時的模組面積

| Module | V2.1 Area | Top Area 比例 |
|---|---:|---:|
| `u_conv2` | 169,519.34 | 22.3% |
| `u_shared_line_buffer` | 157,744.47 | 20.8% |
| `u_conv1` | 109,677.50 | 14.4% |
| `u_fc2` | 82,712.60 | 10.9% |
| `u_fc1` | 80,326.06 | 10.6% |
| `u_conv3` | 76,408.46 | 10.1% |
| `u_fc_buffer` | 56,964.74 | 7.5% |
| `u_reload_controller` | 10,089.35 | 1.3% |
| `u_shared_weight_buffer` | 9,228.76 | 1.2% |

#### V2.1 驗證與追溯待補

- [x] 完成新版 DC 面積量測，來源：`report_area(3).log`。
- [x] `u_fc_buffer` 面積仍維持 V2 Banked Read 的 **56,964.74**。
- [ ] 記錄本次 Gate Simulation 修正的**實際 RTL 檔案／訊號、修正原因與 Git Commit**（本次僅附 Area Report，沒有對應最新 RTL Diff）。
- [ ] 補充完整的 **Gate-Level Simulation PASS/FAIL、Log、是否 SDF、測試向量與最終 10 筆結果**。
- [ ] 確認 **RTL Golden PASS**、各層輸出與 Cycle Count 沒有因修正改變。
- [ ] 補充相同 10 ns SDC 下的 **Setup Timing、WNS／TNS 與 Critical Path**；Area Report 不能當作 Timing 證據。
- [ ] 檢查 Latch、Multiple Driver、Unconnected Port、Width Mismatch 與 Reset／未知值行為。

**版本追溯：** `report_area(3).log`（DC T-2022.03、`slow.db`）；Gate Sim 修正的細節目前僅有使用者的描述，不能從 Area Report 逆推出確切的程式修改。下一步優化目標仍為 **OPT-03：Shared Line Buffer MUX / Decoder**。

### 2.7 V3A：OPT-03A — Shared Line Buffer Static Write Decoder（報告日期：2026-11-05 23:08:12）

> **此次修改目的：** 嘗試將 `shared_line_buffer.sv` 原本使用變動 `row_pair` 與 `col_blk` 的寫入選擇，改為固定 Row／4-Byte Block 的 `generate` 與局部 Write Enable Decode；保留 CONV1 Row Shift、CONV2 Reload、CONV3 Vector Mode、5×5 Window Read 和原本的 Port Interface。這是根據本次討論及使用者所述版本命名，**僅憑 Area Report 尚不能確認實際 RTL Diff 或功能等價性**。
>
> **注意：** 最新 `report_area(5).log` 可與 V2.1 的 `report_area(3).log` 比較：兩份報告均為 Design `lenet`、DC T-2022.03、`slow.db`，而且都有 `u_shared_line_buffer`、`u_fc_buffer` 等相同層級。完整的 SDC 與 compile options 尚未附上，仍請確認一致。

#### V2.1 → V3A：Top Area 與 Cell 統計

| 指標 | V2.1（GS-Fix） | **V3A（Static Write Decode）** | **V3A − V2.1** |
|---|---:|---:|---:|
| **Total Cell Area** | **759,562.73** | **759,250.41** | **−312.32（−0.041%）** |
| Combinational Area | 545,994.17 | 545,800.67 | −193.50 |
| Noncombinational Area | 213,568.56 | 213,449.74 | −118.82 |
| Buf / Inv Area（包含於 Combinational） | 26,005.87 | 26,090.74 | +84.87 |
| Total Cells | 57,213 | **57,224** | +11 |
| Combinational Cells | 49,653 | **49,664** | +11 |
| Sequential Cells | 6,601 | **6,601** | 0 |
| Macro / Black Box | 0 | 0 | 0 |

#### OPT-03A 的目標模組：Shared Line Buffer

| Shared Line Buffer 指標 | V2.1 | **V3A** | 變化 |
|---|---:|---:|---:|
| **Total Area** | **157,744.47** | **157,863.29** | **+118.82（+0.075%）** |
| Combinational Area | 108,207.55 | 108,326.37 | +118.82 |
| Noncombinational Area | 49,536.92 | 49,536.92 | 0 |
| Top Total Area 佔比 | 20.8% | 20.8% | 約相同 |

**觀察與判斷：** Top Total Area 確實下降 312.32，但最佳化的目標 `u_shared_line_buffer` 自身反而增加 118.82。這種不到 **0.1%** 的差異非常小，不能當作 Static Write Decoder 已改善硬體面積的證據；其他模組的 Mapping / Recompile 差異亦會使 Top 總面積小幅變動。更關鍵的是，Buffer 中的 Window Read MUX 仍未修改。

**與歷史版本比較：** V0 947,242.55 → V3A 759,250.41，累計減少 **187,992.14（19.85%）**；V3A 比 V2.1 減少 **312.32（0.041%）**。但相較於 **V2（758,936.39）**，V3A 反而增加 **314.02（0.041%）**，因此不能將 V3A 宣稱為歷史最低面積版本。

**重要：** 本次僅提供 `report_area(5).log`。**V3A 的 Timing PASS、Golden PASS、Gate-Level Simulation PASS、RTL 等價性、實際修改檔案與 Git Commit 均尚待確認**。Clock Target 仍以專案原定 **10 ns** 為目標，但 Area Report 本身不提供 WNS／TNS。

**本輪結論：** **OPT-03A = 已完成面積試驗，但未證明針對 Shared Line Buffer 有有效的面積改善；先保留獨立 Commit 作為 A/B 實驗，不建議只因 Top 減少 0.041% 就直接取代已驗證版本。** 若 Golden 與 Timing 都通過且實作比較有價值，可以暫留；否則回退 Static Write Decoder，接著研究 OPT-03B 的 Window Read MUX。

**相關報告：** `report_area(3).log`（V2.1，2026-11-05 20:12:46）；`report_area(5).log`（V3A，2026-11-05 23:08:12）。`report_area(4).log` 的模組階層為 `PE_B_*`、`PE_T_*`、`shared_qr_*`，沒有原本 `u_shared_line_buffer`，**不屬於本組可直接比較的 LeNet 版本序列，不能視為 OPT-03A 面積結果**。

### 2.8 V3B：OPT-03B — Shared Line Buffer Window Read MUX Optimization（報告日期：2026-11-06 14:18:01）

> **驗證更新（2026-11-06）：Golden PASS、10 ns Timing PASS、Gate-Level Simulation PASS，Cycle Count = 31,497，且與先前版本一致（使用者回報）。** 面積數據來自 DC Area Report，Timing／模擬 PASS 由使用者回報；WNS、TNS 和原始 Log 尚未附上。

> **此次修改方向（根據前一輪建議與使用者描述）：** 保留 6 × 32-Byte Shared Line Buffer、CONV1 Shift、CONV2 Reload 與 CONV3 Vector Mode，將原本 5×5 Window 每個 Byte 的動態 `line_buffer[r][col+c]` 選取，改成 **8-Byte Chunk Selection → Byte Shift → 5×5 Window Row Selection**。此處描述的是討論中的最佳化方案；DC Area Report 本身無法證明實際 RTL Diff；**功能等價性已由使用者回報的 Golden／GLS PASS 支持**，但原始 Log 及 RTL Diff 尚待歸檔。
>
> **比較前提：** V3A `report_area(5).log` 與 V3B `report_area(6).log` 同為 `lenet`、Design Compiler T-2022.03、`slow.db`，而且保有相同的主要階層與 Sequential Cells。**SDC、Compile Options 與完整 RTL Snapshot 尚未附上**，正式論文／作品集比較前應保存並確認條件一致。

#### V3A → V3B：整體 DC Area 與 Cell Count

| 指標 | V3A（Static Write Decoder） | **V3B（Window Read MUX）** | **V3B − V3A** |
|---|---:|---:|---:|
| **Total Cell Area** | 759,250.41 | **699,094.55** | **−60,155.86（−7.92%）** |
| Combinational Area | 545,800.67 | **485,549.76** | **−60,250.91（−11.04%）** |
| Noncombinational Area | 213,449.74 | **213,544.79** | **+95.05（+0.045%）** |
| Buf / Inv Area（Combinational 子集，不重複加總） | 26,090.74 | **24,009.72** | **−2,081.01** |
| Total Cells | 57,224 | **50,608** | **−6,616（−11.56%）** |
| Combinational Cells | 49,664 | **43,047** | **−6,617** |
| Sequential Cells | 6,601 | **6,601** | **0** |
| Macro / Black Box | 0 | 0 | 0 |

#### OPT-03B：Shared Line Buffer 的直接收益

| `u_shared_line_buffer` 指標 | V3A | **V3B** | 變化 |
|---|---:|---:|---:|
| **Total Cell Area** | 157,863.29 | **99,075.54** | **−58,787.75（−37.24%）** |
| Combinational Area | 108,326.37 | **49,538.62** | **−58,787.75（−54.27%）** |
| Noncombinational Area | 49,536.92 | **49,536.92** | **0** |
| 佔 Top Total Cell Area | 20.8% | **14.2%** | **−6.6 個百分點** |

**分析：** 整體 Top 減少 **60,155.86**，其中 Shared Line Buffer 自身減少 **58,787.75**，可解釋約 **97.73%** 的 Top 淨面積下降；目標模組的節省全部來自 Combinational Area，Sequential 面積不變。此為 **OPT-03B 對讀取選擇器有明顯收益的強烈證據**，不是像 OPT-03A 僅有約 0.04% 的 Top 波動。其他模組也有小幅合成變化，因此不應聲稱「Top 的每一點收益」全由該 MUX 直接造成。

**與原始基準 V0 比較：** `947,242.55 → 699,094.55`，累計節省 **248,148.00（26.20%）**，**V3B 是當時同系列 Area Report 中面積最低且功能／時序／GLS 均通過的版本（使用者回報）；後續 V4 面積更低，且 Golden／Timing／GLS 與 Cycle Count 均已通過／確認（使用者回報）**。若只和 V2.1（Gate Sim 相關修正後）比較，下降 **60,468.18（7.96%）**。

**V3B 驗證狀態（2026-11-06 使用者回報）：**

- [x] **RTL Golden Comparison：PASS（使用者回報）**；完整加速器運算完成，Cycle Count **31,497**，與之前版本相同。
- [x] **10 ns Timing：PASS（使用者回報）**；WNS／TNS／Critical Path 數值未附，不能自行填入。
- [x] **Gate-Level Simulation：PASS（使用者回報）**；原始 Log／是否為 SDF Back-Annotated 的細節尚未附。
- [ ] **建議補充的 Directed Test：** 逐 Byte 比對 `col=3→4`、`7→8`、`23→24`、`27`、`row_sel=0/1`；完整 Golden PASS 不等於已提供這些個別 Test Log。
- [ ] **建議確認：** `col` 合法範圍、非法位址的行為及 Chunk Shift 高位捨棄；Row Shift、Channel Reload、Vector Mode 的獨立測試紀錄。
- [ ] 保存 V3A／V3B RTL Snapshot、Git Commit、SDC、DC Script、Golden／GLS／Timing Reports，確認實驗可重現。

**驗證後結論：** **OPT-03B 已達成面積下降且 Golden、10 ns Timing、Gate-Level Simulation 全部 PASS（使用者回報），完成 Cycle Count = 31,497。V3B 是當時已完整驗證的最佳版本；後續 V4 已取得 Golden／10 ns Timing／GLS PASS，且同為 31,497 cycles。** WNS／TNS、逐項模擬 Log、完整 SDC 仍未附檔，應於 Git／實驗資料夾歸檔；OPT-04B 已於後續 V4 實施。

**本輪報告：** `report_area(6).log`；2026-11-06 14:18:01，`lenet`，T-2022.03，`slow.db`。

### 2.9 V4：OPT-04B — CONV1／CONV2 Shared PE Array（報告日期：2026-11-06 21:26:12）

> **V4 驗證更新（2026-11-06）：** 使用者確認 **Golden PASS、10 ns Timing PASS、Gate-Level Simulation PASS，Cycle Count = 31,497（維持與 V3B 一致）**。Gate-Level Simulation PASS 來自前一輪使用者回報；本輪補齊 Golden／Timing／Cycle Count。DC Area Report `report_area(7).log` 顯示 `u_shared_pe_array` 與五個 `gen_shared_pe[*].pe_inst`，不再於 `u_conv1`／`u_conv2` 下列出原本各五個 PE，支持**硬體確實共享一組 PE**。**Area 由 DC 報告支持；驗證 PASS／週期數由使用者回報，WNS／TNS、Golden／GLS 原始 Log、SDC 尚未附檔。**

#### V3B → V4：整體 Cell Area 比較

| 指標 | V3B（OPT-03B） | **V4（OPT-04B）** | **V4 − V3B** |
|---|---:|---:|---:|
| **Total Cell Area** | **699,094.55** | **636,574.22** | **−62,520.33（−8.94%）** |
| Combinational Area | 485,549.76 | **423,068.46** | **−62,481.29（−12.87%）** |
| Noncombinational Area | 213,544.79 | **213,505.75** | **−39.04（−0.018%）** |
| Buf / Inv Area（已包含在組合邏輯內） | 24,009.72 | **20,869.53** | **−3,140.19** |
| Total Cells | 50,608 | **43,780** | **−6,828（−13.49%）** |
| Combinational Cells | 43,047 | **36,287** | **−6,760** |
| Sequential Cells | 6,601 | **6,601** | **0** |
| Nets | 70,874 | **61,205** | **−9,669** |
| Macros / Black Boxes | 0 | **0** | 不變 |

**累計成果：** V0 `947,242.55 → 636,574.22`，累計節省 **310,668.33（32.80%）**。本輪減少幾乎都來自 Combinational Logic；Sequential Cells 完全不變，代表此版 PE Sharing **沒有因減少運算 PE 而直接減少 FF 數量**。

#### 為什麼不能只看 `u_conv1` 和 `u_conv2` 的下降？

| 比較範圍 | V3B Cell Area | **V4 Cell Area** | 變化 |
|---|---:|---:|---:|
| `u_conv1` | 109,684.29 | **47,257.31** | −62,426.98 |
| `u_conv2` | 167,998.47 | **104,659.99** | −63,338.48 |
| `u_shared_pe_array` | **無此階層** | **62,705.35** | 新共享 PE 成本 |
| **上述相關階層合計** | **277,682.76** | **214,622.65** | **−63,060.11（−22.71%）** |
| 整體 Top Total | 699,094.55 | **636,574.22** | **−62,520.33（−8.94%）** |

**分析：** `u_conv1` 與 `u_conv2` 各自減少約 62k～63k，但這包含原先位於 Layer 內的 PE 運算邏輯移到 `u_shared_pe_array`，**不可把兩個 Layer 的下降直接當作淨收益**；需要把新共享 PE 的 **62,705.35** 加回去。兩層相關階層合計淨減 **63,060.11**；和 Top 淨減 **62,520.33** 的差距 **539.77**，反映其他階層重新合成造成的小幅面積變動。相比 V3B，Shared Line Buffer 自身由 **99,075.54 → 99,403.14（+327.60，+0.33%）**，FC Buffer 仍為 **56,964.74**。

#### V4 主要模組分布（不同於原本各 Layer 自帶 PE 的階層）

| Module | V4 Area | Top 比例 |
|---|---:|---:|
| `u_conv2` | 104,659.99 | 16.4% |
| `u_shared_line_buffer` | 99,403.14 | 15.6% |
| `u_fc2` | 82,828.03 | 13.0% |
| `u_fc1` | 80,135.95 | 12.6% |
| `u_conv3` | 76,457.69 | 12.0% |
| **`u_shared_pe_array`** | **62,705.35** | **9.9%** |
| `u_fc_buffer` | 56,964.74 | 8.9% |
| `u_conv1` | 47,257.31 | 7.4% |
| `u_reload_controller` | 10,089.35 | 1.6% |
| `u_shared_weight_buffer` | 9,261.01 | 1.5% |

**PE 硬體實例：** `u_shared_pe_array/gen_shared_pe[0..4].pe_inst` 共 **5 個 PE**。原本 CONV1＋CONV2 總共 10 個 PE（以每 PE 五個 8-bit 乘法器計，為 50 個乘法器），現共用 5 個 PE（25 個乘法器）；這是就 CONV1／CONV2 PE 運算陣列而言，**不包含其他 Layer 與 Quantization 乘法器**。Top FSM 的 Layer Enable 互斥有利於分時共用，但仍須確認 Pipeline 有效週期與最後一筆計算的正確交接。

#### V4 驗證狀態與採用條件

| 項目 | V4 狀態 | 依據 |
|---|---|---|
| Gate-Level Simulation | **PASS（使用者回報）** | 原始 Gate Sim Log／是否套用 SDF 尚未附上 |
| RTL Golden Comparison | **PASS（使用者回報）** | V4 專屬結果已確認；Golden Log 待歸檔 |
| 10 ns Setup Timing | **PASS（使用者回報）** | 10 ns 目標通過；WNS／TNS／Critical Path Report 待歸檔 |
| Cycle Count | **31,497（使用者回報）** | 與 V3B 的 31,497 cycles **完全相同**，沒有增加週期 |
| PE Instance Sharing | **已由 DC Hierarchy 確認** | 一組 `u_shared_pe_array`、五個 PE |
| Sequential Cells | **6,601（不變）** | DC Area Report |

**驗證後結論：** **OPT-04B 已確實降低面積，V4 Golden／10 ns Timing／GLS 全 PASS，完成週期維持 31,497（使用者回報）**，因此 **V4 在當時升格為已驗證的最低面積版本；目前 V6 已進一步降低面積且全數驗證通過**。建議歸檔 `lenet.sv`、`conv1.sv`、`conv2.sv`、`shared_pe_array.sv`、`PE.sv` 的實際 Git Commit／Diff，與 V4 的 Timing Report、Golden／GLS Log 和 SDC；不要自行補填尚未提供的 WNS／TNS 數字。

**本輪報告：** `report_area(7).log`，Synopsys DC T-2022.03、`slow.db`、Design `lenet`、2026-11-06 21:26:12。SDC 與完整 Compile Options 尚未附檔；與 V3B 的公平比較應以相同 10 ns Constraint 和編譯條件再次確認。

### 2.10 V5：OPT-05 — 全五層 Unified 5-PE Array（報告日期：2026-11-06 22:44:44）

> **V5 驗證狀態（2026-11-06 使用者回報）：Golden PASS、Gate-Level Simulation PASS、10 ns Timing PASS，Cycle Count = 31,497（與 V4 一致）。** 本節 Cell Area 與 PE 階層由 `report_area(8).log` 支持；Golden、Timing、GLS PASS 與週期數由使用者直接回報。WNS／TNS、原始 Golden／GLS Log、完整 SDC 與該版 RTL Commit 尚未附上，請勿自行補值。
>
> **本次修改方向（依先前 RTL 討論）：** V4 已使 CONV1／CONV2 共用五顆 PE；V5 進一步移除 CONV3、FC1、FC2 原本每層各兩顆 PE，透過 Top Operand Selection、Layer 對應的 PE Valid 與 Result 回傳，使全五個 Layer **分時使用同一組五顆 PE**。CONV1／CONV2 使用五顆；CONV3／FC1／FC2 使用其中兩顆。各 Layer 的 Controller、PSUM 與 Pipeline 暫存器仍保留。精確 RTL Diff 仍須以 V5 Git Commit 核實。

#### V4 → V5：Top Area 與 Cell Count

| 指標 | V4（OPT-04B） | **V5（OPT-05）** | **V5 − V4** |
|---|---:|---:|---:|
| **Total Cell Area** | 636,574.22 | **565,724.74** | **−70,849.48（−11.13%）** |
| Combinational Area | 423,068.46 | **352,509.24** | **−70,559.22（−16.68%）** |
| Noncombinational Area | 213,505.75 | **213,215.50** | **−290.26（−0.136%）** |
| Buf / Inv Area（已包含於 Combinational） | 20,869.53 | **19,951.24** | **−918.29** |
| Number of Cells | 43,780 | **40,240** | **−3,540（−8.09%）** |
| Combinational Cells | 36,287 | **32,838** | **−3,449** |
| Sequential Cells | 6,601 | **6,601** | **0** |
| Nets | 61,205 | **53,371** | **−7,834** |
| Macros / Black Boxes | 0 | **0** | 不變 |

**累計成果：** V0 `947,242.55 → 565,724.74`，Cell Area 累計減少 **381,517.81（−40.28%）**。V5 的下降主要來自組合邏輯，Sequential Cells 仍是 6,601，未因共享運算 PE 而直接縮減 FF 數量。`Buf / Inv Area` 為 Combinational Area 的子集，不得再重複加總。

#### OPT-05 目標 Layer 與共享 PE 模組的面積

| Module | V4 Area | **V5 Area** | V5 − V4 |
|---|---:|---:|---:|
| `u_conv3` | 76,457.69 | **52,171.29** | **−24,286.40（−31.76%）** |
| `u_fc1` | 80,135.95 | **56,017.59** | **−24,118.36（−30.10%）** |
| `u_fc2` | 82,828.03 | **59,278.30** | **−23,549.73（−28.43%）** |
| **上述三層合計** | **239,421.66** | **167,467.18** | **−71,954.49（−30.05%）** |
| `u_shared_pe_array`（五顆共享 PE） | 62,705.35 | **62,752.88** | **+47.53（+0.08%）** |
| **整個 Top Total Cell Area** | **636,574.22** | **565,724.74** | **−70,849.48（−11.13%）** |

**分析：** CONV3／FC1／FC2 合計下降 **71,954.49**，高於 Top 淨下降的 **70,849.48**；這是因為 Top MUX、其他模組重新映射等因素也會增減 Cell Area。共用的五顆 PE 並未消失，仍占 **62,752.88**，因此不能把三層移除的所有 PE 面積簡單視為全部純收益；**正確的整體實測收益是 −70,849.48（−11.13%）**。這也不是 Design 裡只剩 25 個乘法器：CONV／FC Quantization 等另外列出的 `DW_mult` 仍然存在。

#### V5 Hierarchy：五層共用唯一 5-PE Array

- `u_shared_pe_array`：**62,752.8778**（約占 Top **11.1%**）。
- `u_shared_pe_array/gen_shared_pe[0].pe_inst` 到 `[4].pe_inst`：**報告明確列出五顆 PE**；`u_conv1`、`u_conv2`、`u_conv3`、`u_fc1`、`u_fc2` 階層下不再列出 `gen_pe[*].pe_inst`。
- `u_conv1` **44,750.25**；`u_conv2` **104,361.24**；`u_conv3` **52,171.29**；`u_fc1` **56,017.59**；`u_fc2` **59,278.30**。
- 其餘大模組：`u_shared_line_buffer` **99,058.56**；`u_fc_buffer` **56,964.74**（V4→V5 不變）；`u_shared_weight_buffer` **9,133.71**。
- **功能使用方式：** CONV1／CONV2 同一時間最多使用五顆；CONV3／FC1／FC2 同一時間使用 PE0～PE1，PE2～PE4 無須增加實體。Layer FSM 依序執行，且使用者回報 V5 全數模擬通過、Cycle 不變，支持這一版分時共享機制的功能結果。更嚴謹的 Pipeline 邊界個別測試仍可補存。

#### V5 完整驗證狀態

| 驗證項目 | V5 結果 | 證據狀態 |
|---|---|---|
| RTL Golden Comparison | **PASS** | 使用者於 2026-11-06 回報；原始 Log 待歸檔 |
| Gate-Level Simulation | **PASS** | 使用者回報；GLS Log、SDF 設定待歸檔 |
| 10 ns Setup Timing | **PASS** | 使用者回報；WNS／TNS、Critical Path 待補 |
| Cycle Count | **31,497** | 使用者回報；與 V3B、V4 一致，**新增 0 cycles** |
| DC Synthesis Area | **565,724.739681** | `report_area(8).log` |
| PE 實例數 | **五顆** | DC Hierarchy 的 `u_shared_pe_array/gen_shared_pe[0..4].pe_inst` |
| Sequential Cells | **6,601** | DC `report_area(8).log`；與 V4 相同 |

**驗證後結論（V5 當時）：** **V5（OPT-05）曾為已驗證的最低 DC Cell Area 版本：565,724.74，較 V4 降低 11.13%，較 V0 累計降低 40.28%；Golden、10 ns Timing、GLS 全部 PASS，總 Cycle Count 31,497 不變（使用者回報）。** 建議立即建立 Git Tag、保留 V4／V5 RTL Diff、固定 10 ns SDC、`report_area(7).log`／`report_area(8).log`、Golden／GLS／Timing 原始輸出。Area Report 沒有 Wire Load（`Net Interconnect area: undefined`），不能以此宣稱實際佈線後 Core Area、Power 或 Post-Route Timing 成果。

**本輪報告：** `report_area(8).log`，DC T-2022.03、`slow.db`、Design `lenet`，2026-11-06 22:44:44。


### 2.11 V6：OPT-06 — CONV2／FC2 Shared Channel PSUM Buffer（報告日期：2026-11-06 23:54:47）

> **V6 驗證（使用者於 2026-11-06 回報）：Golden PASS、Gate-Level Simulation PASS、10 ns Timing PASS，Cycle Count = 31,497（與 V5 一致）。** 面積與階層數據取自 `report_area(9).log`（DC T-2022.03、`slow.db`）；Timing WNS／TNS、原始 Golden／GLS Log、SDF 設定與該版 Git Commit／完整 RTL Diff 尚待歸檔。

> **設計方向（根據本次先前討論）：** 將 CONV2／FC2 各自的 `logic signed [9:0][31:0] ch_temp_psum[0:1]`（每份 2 × 10 × 32 = **640 bits**）移出原本 Layer，在 `lenet.sv` 只保留一個 `u_shared_ch_temp_buffer`。由於兩層透過 Top FSM 分時執行，共用一份儲存體；CONV2 的 PSUM 更新與 Pooling 讀取、FC2 的 MAC／Bias 更新與最終輸出由共享模組依接口支援。這是與合成結果相符的預期改動，但確切 RTL 變更仍應以 V5→V6 Git Diff 確認。

#### V5 → V6：Top Area 與 Cell Count

| 指標 | V5（OPT-05） | **V6（OPT-06）** | **V6 − V5** |
|---|---:|---:|---:|
| **Total Cell Area** | 565,724.74 | **552,503.69** | **−13,221.05（−2.34%）** |
| Combinational Area | 352,509.24 | **359,770.72** | **+7,261.48（+2.06%）** |
| Noncombinational Area | 213,215.50 | **192,732.97** | **−20,482.53（−9.61%）** |
| Buf / Inv Area（Combinational 子集） | 19,951.24 | **19,756.04** | **−195.20** |
| Total Cells | 40,240 | **40,169** | **−71** |
| Combinational Cells | 32,838 | **33,402** | **+564** |
| **Sequential Cells** | **6,601** | **5,961** | **−640（−9.70%）** |
| Number of Nets | 53,371 | **53,817** | **+446** |
| Macro / Black Box | 0 | **0** | 0 |

**關鍵觀察：** Sequential Cells 減少 **640 個**，恰好與預期消除的一份 **640-bit Channel PSUM Buffer** 容量一致，是實際減少儲存硬體的強烈支持；但僅憑數量不能逐顆證明全部 640 個 FF 的精確來源。新設計的共享讀寫 MUX、累加與 Decoder 使組合面積增加 **7,261.48**，但非組合面積下降 **20,482.53**，因此 Top 淨減 **13,221.05（2.34%）**。**不可把「兩個 Layer 原本各自下降的面積」直接全算作節省，因為新增的 Shared Buffer 仍佔實體面積。**

#### Shared Channel PSUM Buffer：Hierarchy 與歸因

| Module | V5 Area | **V6 Area** | V6 − V5 |
|---|---:|---:|---:|
| `u_conv2` | 104,361.24 | **66,998.07** | **−37,363.17（−35.80%）** |
| `u_fc2` | 59,278.30 | **25,175.84** | **−34,102.46（−57.53%）** |
| **`u_shared_ch_temp_buffer`** | 不存在 | **57,930.56** | **+57,930.56（新增共享實體）** |
| **上述三模組合計** | **163,639.54** | **150,104.47** | **−13,535.07（−8.27%）** |
| `u_shared_pe_array` | 62,752.88 | **62,717.23** | −35.65 |
| `u_shared_line_buffer` | 99,058.56 | **98,859.97** | −198.60 |
| **Top Total Cell Area** | **565,724.74** | **552,503.69** | **−13,221.05（−2.34%）** |

- 新階層 `u_shared_ch_temp_buffer` **57,930.5636**（約占 Top **10.5%**），Local Combinational 32,764.9119、Local Noncombinational 20,640.3833，另包含子階層加法器；**Global Area 不可再與其 Child Areas 重複加總**。
- `u_conv2` 由 104,361.2428 降到 66,998.0749；`u_fc2` 由 59,278.2990 降到 25,175.8362。這兩層移出的暫存與邏輯已轉移至共享模組，不能只看 Layer 階層下降就宣稱節省約 71,466。
- 三個相關模組合計的淨改善 **13,535.07**，與整體 Top 淨改善 **13,221.05** 接近；差額來自其他階層及 Top 的重新映射。V5→V6 共享 PE Array 仍為五顆（`gen_shared_pe[0..4].pe_inst`），並未增加 PE 數量。
- DC 面積報告的 `Net Interconnect area: undefined`，本結果不等於實際 Placement／Routing Core Area 或整體 Power／PPA。

#### V6 驗證狀態

| 驗證項目 | V6 結果 | 證據狀態 |
|---|---|---|
| RTL Golden Comparison | **PASS** | 使用者回報；完整 Golden Log 待歸檔 |
| Gate-Level Simulation | **PASS** | 使用者回報；GLS Log、SDF 設定待歸檔 |
| 10 ns Setup Timing | **PASS** | 使用者回報；WNS／TNS／Critical Path 數值未提供 |
| Cycle Count | **31,497** | 使用者回報；相較 V5 **+0 cycles** |
| Total Cell Area | **552,503.691758** | DC `report_area(9).log` |
| Sequential Cells | **5,961（−640 vs V5）** | DC `report_area(9).log` |

**累計成果：** V0 `947,242.55 → 552,503.69`，減少 **394,738.86（−41.67%）**；V6 為**當時最低 Cell Area 且 Golden／10 ns Timing／GLS 全 PASS（使用者回報）的版本；其後已有 V7**。建議保存 V5／V6 Git Diff、SDC／DC Compile Script、Golden／GLS Logs、`report_timing`（WNS／TNS）及專用的 CONV2 Pooling／FC2 Bias Read-Modify-Write 測試，確認實驗完全可重現。

**本輪報告：** `report_area(9).log`，Synopsys DC T-2022.03、`slow.db`、Design `lenet`，2026-11-06 23:54:47。

### 2.12 V7：OPT-07A — CONV1／CONV2／CONV3／FC1 Shared ReLU + Quantizer（報告日期：2026-11-07 11:13:57）

> **V7 驗證（2026-11-07 使用者回報）：Golden PASS、Gate-Level Simulation PASS、10 ns Timing PASS、Cycle Count = 31,497，與 V6 一致（0 cycle overhead）。** 面積及階層數據取自 `report_area(10).log`（Synopsys DC T-2022.03、`slow.db`）。尚未附 WNS／TNS、Critical Path、完整模擬 Log、SDF 設定或 V7 Git Commit／RTL Diff；PASS 狀態依使用者回報，不以 Area Report 推定。

> **設計方向（依前輪 RTL 修改討論）：** 將 CONV1、CONV2、CONV3、FC1 各自的 ReLU + Scale Multiply + Shift + Saturation 改由 Top 的唯一 `u_shared_quantizer` 執行。CONV1 維持 **先 Quantize、後 8-bit Pool**；CONV2 維持 **先 32-bit PSUM Max Pool、後 Quantize**；CONV3／FC1 在原 `neuron_data` FF 的時序點取共用結果。FC2 不使用此 Quantizer。Top 透過 Layer State 選擇 PSUM 與 Scale，Quantizer 本身為 Combinational，未意圖插入新 Pipeline Stage。這些是先前約定的 RTL 修改方向，最終精確實現需由 V6→V7 Git Diff 追溯。

#### V6 → V7：DC Top Area 與 Cell Count

| 指標 | V6（OPT-06） | **V7（OPT-07A）** | **V7 − V6** |
|---|---:|---:|---:|
| **Total Cell Area** | 552,503.69 | **498,037.52** | **−54,466.17（−9.86%）** |
| Combinational Area | 359,770.72 | **304,886.99** | **−54,883.73（−15.26%）** |
| Noncombinational Area | 192,732.97 | **193,150.53** | **+417.56（+0.22%）** |
| Buf / Inv Area（已含於 Combinational） | 19,756.04 | **17,410.23** | **−2,345.81** |
| Total Cells | 40,169 | **31,889** | **−8,280（−20.61%）** |
| Combinational Cells | 33,402 | **25,076** | **−8,326** |
| Sequential Cells | 5,961 | **5,966** | **+5** |
| Macro／Black Box | 0 | 0 | 0 |
| Clock／Golden／GLS | 10 ns／PASS／PASS（回報） | **10 ns／PASS／PASS（回報）** | 驗證狀態維持 |
| Cycle Count | 31,497 | **31,497** | **0** |

#### 四個使用 Quantizer 的 Layer 與共享模組

| Hierarchical Module | V6 Area | **V7 Area** | V7 − V6 |
|---|---:|---:|---:|
| `u_conv1` | 44,624.65 | **23,819.61** | **−20,805.03（−46.62%）** |
| `u_conv2` | 66,998.07 | **28,799.79** | **−38,198.29（−57.01%）** |
| `u_conv3` | 52,748.40 | **23,515.78** | **−29,232.62（−55.42%）** |
| `u_fc1` | 56,043.06 | **27,119.36** | **−28,923.70（−51.61%）** |
| `u_shared_quantizer` | 原本未列獨立階層 | **51,470.26** | 新增共享運算實體 |
| └ `mult_18`（Quantizer 內） | — | **50,511.23** | 已包含於上述 `u_shared_quantizer`，**不可重複加總** |
| `u_fc2`（無共享量化路徑） | 25,175.84 | **25,021.37** | −154.46（映射差異） |
| `u_shared_pe_array` | 62,717.23 | **69,326.91** | **+6,609.68** |
| `u_shared_line_buffer` | 98,859.97 | **101,159.95** | +2,299.98 |
| `u_shared_ch_temp_buffer` | 57,930.56 | **58,300.60** | +370.03 |

**分析：** 四個量化 Layer 的 Hierarchical Area 合計明顯下降；但 `u_shared_quantizer` 另佔 **51,470.26**，Top 的 Shared PE、Line Buffer 等階層也因重合成映射而增加。**真正淨收益應採用 Top Total Cell Area 減少的 54,466.17（9.86%）**，不得直接把四層的面積差額相加，亦不可把量化器的 `mult_18` 再額外扣一次。Sequential Cells 並未下降，反而 +5；此次主要節省 **Combinational Logic**。

**Hierarchy 證據：** DC 列出一組 `u_shared_quantizer` 和其一個大型 `mult_18`；四個 Layer 的 Report 不再列出各自原本的大型 Quantization Multiplier，而唯一的 `u_shared_pe_array` 仍含五顆 PE。這支持量化乘法器實體被分時共享；不能由此宣稱晶片總共只有一顆乘法器（PE 及其他數學運算仍有 Multiplier）。

**驗證與追溯：**

- [x] **Golden Comparison：PASS**（使用者回報）；Cycle Count **31,497**，與 V6 一致。
- [x] **10 ns Timing：PASS**（使用者回報）；WNS／TNS／Critical Path 數值仍未提供。
- [x] **Gate-Level Simulation：PASS**（使用者回報）；原始 GLS Log／是否 SDF Back-Annotated 待歸檔。
- [x] **DC Area Report：** `report_area(10).log`，Design `lenet`，2026-11-07 11:13:57，`slow.db`，無 Macro／Black Box。
- [ ] 歸檔 V6→V7 `lenet.sv`、`conv1.sv`、`conv2.sv`、`conv3.sv`、`fc1.sv`、`shared_quantizer.sv` 的精確 RTL Diff 和 Git Commit。
- [ ] 補存 SDC、DC Compile Script、`report_timing`、Golden／GLS Logs；對 `psum_next` 與 Scale Pipeline 對齊、CONV1/2 Pooling 邊界、ReLU 負值及 Saturation 做 Directed Tests。

**結論：** **V7 是目前最低 Cell Area 且完整 Golden／10 ns Timing／GLS 都 PASS（使用者回報）的版本。** V0 `947,242.55 → 498,037.52`，累計減少 **449,205.03（−47.42%）**；V6→V7 減少 **54,466.17（−9.86%）**；Cycle Overhead = **0**。尚未提供 Power、Post-Route Timing 或實體面積，故不宣稱完整 PPA 改善。

**本輪報告：** `report_area(10).log`；DC T-2022.03，2026-11-07 11:13:57，`slow.db`。

## 3. 已進行的架構重構與資源共享

| 編號 | 項目 | 目前設計 | 備註 |
|---|---|---|---|
| R-01 | Shared Line Buffer | CONV1／CONV2／CONV3 使用同一個 `shared_line_buffer` | 一份 6 × 32 Bytes（192 B）儲存體，支援 CONV1 Row Shift、CONV2 Reload 和 CONV3 64-bit Vector |
| R-02 | Shared Weight Buffer | CONV1／CONV2／CONV3／FC1／FC2 共用 `shared_weight_buffer` | 5 × 5 × 8-bit（200 bits）；Conv1/2 用 Kernel Mode，其餘層用 Vector Mode |
| R-03 | Shared FC Buffer | CONV3 寫入 120 Bytes；FC1 讀取；RELOAD84 載入 FC1 輸出後供 FC2 讀取 | 120 × 8-bit；支援 8-bit Write、64-bit Masked Write、64-bit Read |
| R-04 | Weight/Bias 分時讀取 | FC2 先讀 Weight MAC，再以雙 Port 讀 Bias，與 `ch_temp_psum` 相加 | Bias 不進 Shared Weight Buffer |
| **R-05** | **CONV1／CONV2 Shared PE Array** | **V4：CONV1／CONV2 共用 5 個 PE** | **OPT-04B Top Area −8.94% vs V3B；Golden／10 ns Timing／GLS PASS，31,497 cycles（回報）** |
| **R-06** | **全五層共享 5-PE Array** | **V5：CONV1／CONV2 使用五顆；CONV3／FC1／FC2 使用其中兩顆，總共只有五顆 PE** | **OPT-05 Top Area −11.13% vs V4；Golden／10 ns Timing／GLS PASS，31,497 cycles（回報）** |
| **R-07** | **CONV2／FC2 共享 Channel PSUM Buffer** | **V6：Top 只建立一份 640-bit `u_shared_ch_temp_buffer`，兩層分時存取** | **OPT-06 Top Area −2.34% vs V5；Sequential Cells −640；Golden／10 ns Timing／GLS PASS，31,497 cycles（回報）** |
| **R-08** | **四層 Shared ReLU + Quantizer** | **V7：CONV1／CONV2／CONV3／FC1 共用 Top 唯一 `u_shared_quantizer`；保留各自 Pooling／Result FF** | **OPT-07A Top Area −9.86% vs V6；Golden／10 ns Timing／GLS PASS，31,497 cycles（回報）** |

> 注意：**程式重構完成 ≠ 已證實省面積**。R-01～R-04 缺乏重構前同條件的獨立對照，不可宣稱各自省多少；R-05～R-08 則分別有 V3B／V4、V4／V5、V5／V6 及 V6／V7 合成對照；跨階層搬移的 PE／Buffer 面積不能重複計算。

## 4. 各階段最佳化追蹤與下一輪待辦

### OPT-01：CONV2 — Max Pool 與 Quantization 交換順序

**狀態：** **V1 已完成合成量測（10 ns Timing PASS、Area 下降）；功能 / Golden / GLS 待驗證**  
**優先級：** P0  
**檔案：** `conv2.sv`，`pool_max`、`quantize_psum()`

#### 問題

V0 每個 2×2 Pooling Window 先各自執行 Quantization，再比較四個 8-bit 結果：

```systemverilog
q0 = quantize_psum(ch_temp_psum[0][pool_col_base],   scale_CONV2_buf);
q1 = quantize_psum(ch_temp_psum[0][pool_col_base+1], scale_CONV2_buf);
q2 = quantize_psum(ch_temp_psum[1][pool_col_base],   scale_CONV2_buf);
q3 = quantize_psum(ch_temp_psum[1][pool_col_base+1], scale_CONV2_buf);
current_max = max(q0, q1, q2, q3); // 示意
```

合成報告在 `u_conv2` 中列出四個大型乘法單元（`mult_550_C579`～`C582`）：

| Multiplier | Area |
|---|---:|
| `mult_550_C579` | 29,497.42 |
| `mult_550_C580` | 34,547.18 |
| `mult_550_C581` | 27,757.58 |
| `mult_550_C582` | 26,981.87 |
| **合計** | **118,783.99** |

#### 修改假設

如果 `quantize_psum()` 是單調不減函式，則：

`max(Q(a), Q(b), Q(c), Q(d)) = Q(max(a, b, c, d))`

從已檢查的 `conv2.sv` 版本看，`Q` 是 **signed PSUM → ReLU → unsigned scale 相乘 → 右移 16 → 飽和到 127**。在現有 32-bit PSUM、32-bit unsigned scale、64-bit product 的運算定義下，預期具有單調性。修改前仍應核對實際 Bit Width、Signedness、Golden 的等價性。

**V1 最佳化方向：** 先比較四個 **signed 32-bit 原始 PSUM**，再呼叫一次 `quantize_psum()`，取代四個並行 Quantization。新合成報告的結構符合此方向；實際 RTL 修改內容待 Git Commit / RTL Snapshot 核對。

```systemverilog
// 概念示意：實作時保留完整的四項 signed comparison
pool_psum_max = $signed(ch_temp_psum[0][pool_col_base]);
if ($signed(ch_temp_psum[0][pool_col_base+1]) > pool_psum_max)
    pool_psum_max = $signed(ch_temp_psum[0][pool_col_base+1]);
if ($signed(ch_temp_psum[1][pool_col_base]) > pool_psum_max)
    pool_psum_max = $signed(ch_temp_psum[1][pool_col_base]);
if ($signed(ch_temp_psum[1][pool_col_base+1]) > pool_psum_max)
    pool_psum_max = $signed(ch_temp_psum[1][pool_col_base+1]);
current_max = quantize_psum(pool_psum_max, scale_CONV2_buf);
```

**V1 量測結果：** `u_conv2` Area **248,871.09 → 168,253.08（−80,618.01，−32.39%）**；Top Total Area **947,242.55 → 866,592.29（−80,650.26，−8.51%）**。在 V1 `report_area(1).log` 中，原四個大型 Multiplier 改為一個 `mult_535_C577`（37,208.71），另有三個比較器；這是實際合成觀察。原四個乘法器的 118.8k **不等於**實際節省的面積。

**驗證條件：**

- [ ] 確認輸出逐 Byte 與原版及 Golden 完全相同。
- [ ] 比對正數、負數、0、最大值、Saturation、不同 Scale 的測試案例。
- [ ] 確認沒有意外的 Signed/Unsigned Cast 或 Intermediate Overflow。
- [x] 在 10 ns 目標下重跑 DC 並記錄 CONV2 與 Total Area；Timing PASS（使用者回報），待補 WNS／TNS。
- [ ] 檢查 Pooling Compare + Quantization 是否變為 Critical Path（待 `report_timing`）。

### OPT-02：FC Buffer — 8-Byte Aligned Banked Read

**狀態：** **V2 完成 Area 量測（−12.42% vs V1）；V2.1 已完成 Gate Sim 相關 RTL 修正後的 Area 量測，`u_fc_buffer` 面積維持不變。Timing／Golden／GLS PASS 證據仍待補。**  
**優先級：** P1（已實施，待驗證）  
**檔案：** `fc_buffer.sv`（本次主要修改），`reload_controller.sv` 原有對齊寫入介面維持

#### 原本的瓶頸

原 FC Buffer 為 120 × 8-bit，使用以下 Byte-level 動態讀取：

```systemverilog
for (int lane = 0; lane < 8; lane++)
    fc_buf_rdata[lane*8 +: 8] = fc_buf[fc_buf_raddr + lane];
```

即使 FC1／FC2 合法讀取位置僅為 0、8、16、…、112，綜合器仍須處理動態 Byte Selection，造成 Combinational MUX 面積偏高。

#### V2 的架構修改

- 將同樣的 **960 bits** 重排成 `logic [63:0] bank [0:14]`（15 × 64-bit）。
- Read Address 限定 8-Byte Aligned；使用 `fc_buf_raddr[6:3]` 選擇一個 64-bit Bank，直接輸出 8 個 Byte。
- CONV3 單 Byte 寫入改由 Bank Index + Lane Decode 定位；`reload_we` 優先於 `fc_buf_we`。
- RELOAD84 保留 64-bit 寫入及 8-bit `reload_wstrb`，最後一組 Mask 應為 `8'h0F`。
- **不新增資料 Pipeline FF**；Read 仍為 Combinational，既有 Valid Pipeline 在 RTL 等價驗證通過前不視為正確。

#### V2 實測收益

| FC Buffer 指標 | V1 | V2 | 面積改善 |
|---|---:|---:|---:|
| Combinational | 134,391.65 | 26,004.17 | **−80.65%** |
| Noncombinational | 30,960.58 | 30,960.58 | 0% |
| **Total** | **165,352.22** | **56,964.74** | **−65.55%** |

**整體 Total Cell Area：** `866,592.29 → 758,936.39`，下降 **107,655.90（12.42%）**。此數值為 DC Area Report 實測，不是預估；但**不能據此認定功能與 Timing 已通過**。

**待驗證事項：**

- [ ] 逐 Byte 比對 CONV3 寫入的 120 Bytes 與原版。
- [ ] 確認 FC1／FC2 的 Read Address 全部為 8-Byte Aligned，Read Data Byte Order 與原版一致。
- [ ] 確認 RELOAD84 寫入 84 Bytes；Group 10 寫入地址 80，Mask `8'h0F`。
- [ ] 確認 `reload_we` 與 `fc_buf_we` 互斥／優先行為符合原版，以及同步寫入與組合讀取的週期關係不變。
- [ ] 跑完整 RTL Golden Simulation，確認每層輸出與最終 FC2 10 筆結果正確。
- [ ] V2 使用相同 10 ns SDC 跑 `report_timing`；記錄 WNS／TNS、Critical Path。
- [ ] 檢查 Latch／Multiple Driver／Unconnected Port，及必要時 GLS。
- [x] 保存 V2 Area Report：`report_area(2).log`。

### OPT-03：Shared Line Buffer — 靜態寫入 Decode 與 Window MUX

**狀態：** **OPT-03A 面積試驗顯示目標模組 +0.075%，未見效益；OPT-03B 已完成面積量測：Top −7.92%、Shared Line Buffer −37.24%（相較 V3A）。V3B 的 Golden／10 ns Timing／GLS 已 PASS（使用者回報），Cycle Count 為 31,497。**  
**優先級：** P2  
**檔案：** `shared_line_buffer.sv`、必要時各 CONV Controller

**V3B 當時現況：** V3B `u_shared_line_buffer` Total **99,075.54**，其中 Combinational **49,538.62**、Noncombinational **49,536.92**，占 Top **14.2%**。OPT-03B 已顯著減少 Window Read MUX 組合邏輯；V3A 的原始動態讀取方式如下：

```systemverilog
line_buffer[row_pair*2][col_blk*4+:4] <= wdata0;
line_buffer[row_pair*2+1][col_blk*4+:4] <= wdata1;
pe_window[r][c] = line_buffer[r][col+c];
```

**候選方向：**

1. **OPT-03A 已測：** 固定 Row／Column Block 的 `generate` + explicit enable decode。**目標模組面積略增 0.075%**；保留紀錄，避免重複投入。
2. **OPT-03B 已測：** 8-Byte Chunk Selection + Byte Shift + Row Selection，`u_shared_line_buffer` 面積 **157,863.29 → 99,075.54（−37.24%）**；**Golden、10 ns Timing、GLS 均已 PASS（使用者回報）；Cycle Count 31,497**。
3. 分析 CONV1 Row Shift 造成的選擇邏輯與大量 FF 更新。
4. 切勿為省 MUX 擅自增加 Pipeline Stage，除非同時修正 PE Valid / Weight / Activation 對齊。

**驗證條件：** CONV1 每次 Strip Shift、CONV2 每次 Input Channel Reload、CONV3 每組 64-bit Vector 都必須與原版完全相同。

### OPT-04：CONV1／CONV2 跨 Layer PE Sharing（V4：OPT-04B）

**狀態：** **V4 已完成合成與驗證：Top Area −8.94% vs V3B，Golden／10 ns Timing／Gate-Level Simulation 均 PASS（使用者回報）；Cycle Count 31,497，未增加運算週期。**  
**優先級：** P3（已實施並通過驗證，進入成果歸檔）  
**相關檔案：** `shared_pe_array.sv`、`lenet.sv`、`conv1.sv`、`conv2.sv`、`PE.sv`（請以 V4 Git Diff 確認實際修改）

**方案：** 利用 Top FSM 對 CONV1、CONV2 的 Layer Enable 互斥，將兩層原本各五個 PE 改為 `lenet` 下的一組 `u_shared_pe_array`，五個 `gen_shared_pe` PE 各有五個 MAC。Layer Controller、Pipeline Valid 與各自的運算狀態仍需確保相互隔離。

**合成驗證：** 報告顯示 `u_shared_pe_array` **62,705.35**（5 個 PE），兩層相關階層合計 **277,682.76 → 214,622.65（−63,060.11）**，Top **699,094.55 → 636,574.22（−62,520.33，−8.94%）**。這證實並非只是把 PE 封裝成新 Module，而是真正省下一套原本重複的運算硬體。

**驗證與殘餘風險：** Layer Enable 互斥不代表所有 Pipeline Valid 自動互斥，但 V4 已回報 Golden、10 ns Timing、GLS **全部 PASS**，且 **31,497 cycles** 與 V3B 一致，支持本次 PE Sharing 沒有增加整體運算週期。原始 Waveform、Pipeline 交接 Directed Test、WNS／TNS 與 Critical Path Report 仍建議歸檔；**尚未有 Power 報告，不能稱為已量測完整 PPA**。

### OPT-05：CONV1／CONV2／CONV3／FC1／FC2 全五層共用五顆 PE（V5）

**狀態：** **V5 已完成合成及驗證：Top Cell Area 636,574.22 → 565,724.74（−11.13% vs V4），Golden／10 ns Timing／GLS 全部 PASS，Cycle Count 31,497 不變（使用者回報）。**  
**修改範圍（依先前方案）：** `lenet.sv` 的 Operand／Valid／Result Route、`shared_pe_array.sv` 及 CONV3／FC1／FC2 的 PE 結果介面；實際檔案及 Commit 需再以 Git Diff 確認。CONV1／CONV2 五顆全部使用；CONV3／FC1／FC2 共用 PE0～PE1，不增加另外六顆 PE。

**硬體證據：** DC Hierarchy 只有一組 `u_shared_pe_array`，內含 `gen_shared_pe[0..4].pe_inst` 五顆 PE；CONV3／FC1／FC2 不再獨立列出 `gen_pe`；三層合計面積 −71,954.49，Top 淨節省 −70,849.48，主要是組合邏輯下降。注意其他 `DW_mult` 仍可能用於量化或 Layer 其他算術，不能說整體晶片僅有 25 個乘法器。

**實驗結論：** V5 已達成 **共用 PE、10 ns Timing PASS、Golden／GLS PASS、0 Cycle Overhead**。需歸檔原始驗證 Log／WNS／TNS／SDC，未量測 Power 和 Layout PPA。


### OPT-06：CONV2／FC2 共用 640-bit Channel PSUM Buffer（V6）

**狀態：** **V6 已完成合成及驗證：Top Cell Area 565,724.74 → 552,503.69（−2.34% vs V5），Golden／10 ns Timing／GLS 全部 PASS，Cycle Count 31,497 不變（使用者回報）。**

**修改方向：** `conv2.sv` 與 `fc2.sv` 將各自 640-bit `ch_temp_psum` 移到 Top 唯一一份 `shared_ch_temp_buffer.sv`；Top 處理兩個 Layer 的 PSUM Update、Pooling Read、FC2 Bias Write 與 Result Read。實際 Git Diff 尚待歸檔，不以 Area Report 單獨證明所有 RTL 細節。

**實際合成證據：** DC Hierarchy 出現唯一 `u_shared_ch_temp_buffer` **57,930.56**；`u_conv2` 與 `u_fc2` 面積分別 **104,361.24 → 66,998.07**、**59,278.30 → 25,175.84**；**Sequential Cells 6,601 → 5,961（−640）**。新的共用模組與額外組合邏輯已計入後，Top 真正淨節省 **13,221.05（2.34%）**。

**實驗結論：** V6 達成 **實體暫存資源共享、Golden／10 ns Timing／GLS PASS、0 Cycle Overhead**。目前不宣稱功率、Wire Area、Layout／Post-Route Timing 的成果；補存 WNS／TNS、SDC 與原始模擬紀錄。

### OPT-07A：CONV1／CONV2／CONV3／FC1 共享 ReLU + Quantizer（V7）

**狀態：** **V7 已合成且完整驗證：Total Cell Area 552,503.69 → 498,037.52（−9.86% vs V6）；Golden／10 ns Timing／GLS 均 PASS，31,497 cycles（回報）。**

**修改方向：** 新增 `shared_quantizer.sv`，Top 唯一 Instantiate `u_shared_quantizer`，將四個 Layer 的 PSUM／Scale 以 MUX 送入；原 Layer 不再各自保有 ReLU×Scale 乘法器。CONV1 先 Quantize 後 Pool、CONV2 先 Pool 後 Quantize；CONV3／FC1 的 `neuron_data` FF 保留原更新拍點。FC2 不參與。實際對應 RTL 以 V7 Git Diff 為準。

**合成證據：** `u_shared_quantizer` **51,470.26**（其中 `mult_18` **50,511.23**）；四個量化 Layer 面積下降，但 `u_shared_pe_array` **+6,609.68**、`u_shared_line_buffer` **+2,299.98** 等成本亦算進 Top；整體真正節省 **54,466.17（9.86%）**，Sequential Cells **+5**。

**後續可能項目 OPT-07B：** 只在保留 V7 Commit 的前提下評估 Pooling Dataflow；CONV1 的逐次 8-bit Pool 與 CONV2 的平行 32-bit Pool 不應直接合成同一套而不檢查 Valid／數值單調性／Timing。**OPT-07B 尚未實驗，沒有面積數據。**

## 5. 優先順序總覽

| 順序 | ID | 主要目標 | 預期改動範圍 | 風險 | 狀態 |
|---|---|---|---|---|---|
| 1 | OPT-01 | CONV2 去除重複 Quantization | Pooling / Arithmetic | 低～中 | **V1 合成完成：10 ns PASS／Area −8.51%；Golden 待補** |
| 2 | OPT-02 | FC Buffer Banked Read | 讀寫儲存路徑 | 中 | **V2 Area −12.42% vs V1；V2.1 修正後 Area 759,562.73；個別版本 Timing／Golden／GLS 待補** |
| 3 | OPT-03 | Shared Line Buffer MUX / Decoder | Window / Write Decode | 中～高 | **V3A Decoder 無明顯收益；V3B Window Read MUX：Top −7.92%、Buffer −37.24%；Golden／10 ns Timing／GLS PASS；31,497 cycles（使用者回報）** |
| 4 | **OPT-04** | **CONV1/2 PE Sharing** | **Shared PE Array / Layer Datapath** | 高 | **V4 Area −8.94% vs V3B；Golden／10 ns Timing／GLS 全 PASS；31,497 cycles（回報）** |
| 5 | **OPT-05** | **五個 Layer 共用唯一五顆 PE** | **Top Operand MUX + CONV3／FC1／FC2 PE Result Route** | 高 | **V5 Area −11.13% vs V4；Golden／10 ns Timing／GLS 全 PASS；31,497 cycles（回報）** |
| 6 | **OPT-06** | **CONV2／FC2 共用 Channel PSUM Buffer** | **Shared 640-bit PSUM Storage + Pooling／Bias Read-Write MUX** | 中～高 | **V6 Area −2.34% vs V5；Sequential Cells −640；Golden／10 ns Timing／GLS 全 PASS；31,497 cycles（回報）** |
| 7 | **OPT-07A** | **四層共用 ReLU + Quantization** | **Top PSUM／Scale MUX + 單一 `shared_quantizer.sv`** | 中～高 | **V7 Area −9.86% vs V6；Golden／10 ns Timing／GLS 全 PASS；31,497 cycles（回報）** |
| 後續 | OPT-07B | Pooling Dataflow 評估 | CONV1 Sequential Pool vs CONV2 Parallel Pool | 高 | 尚未修改／量測 |

> OPT-01、OPT-02、OPT-03B、OPT-04B、OPT-05、OPT-06、**OPT-07A** 均取得實測面積下降；OPT-03A 的 Static Write Decoder 則未顯著降低目標模組面積。**V7 是目前面積最低且 Golden／10 ns Timing／GLS 均 PASS 的版本（使用者回報）**：Total Cell Area **498,037.52**，相較 V0 **−47.42%**，Cycle Count **31,497**；OPT-07B 尚未測試。

## 6. 每次實驗的量測紀錄

**截至 V7 的累計面積成果：** Cell Area `947,242.55 → 498,037.52`（**−47.42%**）。主要成功最佳化為 OPT-01（CONV2 Quantize）、OPT-02（FC Buffer Banked Read）、OPT-03B（Window Read MUX）、OPT-04B（CONV1／CONV2 Shared PE Array）、OPT-05（五層共用五顆 PE）、OPT-06（CONV2／FC2 共用 640-bit PSUM Buffer）及 **OPT-07A（四層共用 ReLU + Quantizer）**；OPT-03A 保留為 A/B 試驗紀錄。**V7 Golden／10 ns Timing／Gate Sim 全 PASS；31,497 cycles 不變（使用者回報）。**

> 以下比較可確認相同的 DC 版本與 `slow.db` Library，**完整 SDC、Clock Period、Synthesis Options 及同一組 Golden 的設定仍須由實驗版本紀錄核實**。沒有 Timing Report 時，只記錄「使用者確認 Timing PASS」，不要自行填寫 WNS。

**Cycle Count：** 使用者於 2026-11-06～11-07 確認 **V3B、V4、V5、V6、V7 都是 31,497 cycles**，且與歷史版本一致（歷史版本未逐份附 Log）；V4／V5 PE Sharing、V6 PSUM Buffer Sharing 和 V7 Quantizer Sharing **都沒有增加總週期數**。

| Version | 主要改動 | RTL / Golden | Clock | WNS (ns) | Total Cell Area | Area Δ vs Baseline | Cycle Count | 備註 |
|---|---|---|---|---|---:|---:|---|---|
| V0 | Shared Line/Weight/FC Buffer Baseline | 待補 | 10 ns / PASS（回報） | 待補 | **947,242.55** | 0% | **31,497（回報）** | `report_area.log` |
| V1 | OPT-01：Max Pool before Quantization | **待補 Golden** | **10 ns / PASS（回報）** | 待補 | **866,592.29** | **−8.51%（−80,650.26）** | **31,497（回報）** | `report_area(1).log`；合成日期 2026-11-05 01:34:17 |
| V2 | OPT-02：FC Buffer Banked Read | **Golden 待確認** | **10 ns 目標／Timing 未提供** | 待補 | **758,936.39** | **−19.88%（−188,306.16）** | **31,497（回報）** | `report_area(2).log`；V1→V2 −12.42% |
| **V2.1** | **Gate Sim 相關 RTL 修正（保留 OPT-02）** | **Golden／GLS 結果待提供** | **10 ns 目標／Timing 未提供** | 待補 | **759,562.73** | **−19.81%（−187,679.82）** | **31,497（回報）** | **`report_area(3).log`；V2→V2.1 +0.083%；Seq Cells +4；FC Buffer 不變** |
| **V3A** | **OPT-03A：Shared Line Buffer Static Write Decoder** | **Golden／GLS 待確認** | **10 ns 目標／Timing 未提供** | 待補 | **759,250.41** | **−19.85%（−187,992.14）** | **31,497（回報）** | **`report_area(5).log`；相較 V2.1 Top −0.041%，Shared Line Buffer +0.075%** |
| **V3B** | **OPT-03B：8-Byte Chunk + Byte Shift Window MUX** | **Golden PASS／GLS PASS（回報）** | **10 ns／PASS（回報）** | 待補 | **699,094.55** | **−26.20%（−248,148.00）** | **31,497** | **`report_area(6).log`；V3A→V3B Top −7.92%；Buffer −37.24%；驗證完成（使用者回報）** |
| **V4** | **OPT-04B：CONV1／CONV2 共用 5 個 PE** | **Golden／GLS PASS（回報）** | **10 ns / PASS（回報）** | 待補 | **636,574.22** | **−32.80%（−310,668.33）** | **31,497** | **`report_area(7).log`；V3B→V4 Top −8.94%；`u_shared_pe_array` 62,705.35；全數驗證通過（回報）** |
| **V5** | **OPT-05：五個 Layer 共用唯一 5-PE Array** | **Golden／GLS PASS（回報）** | **10 ns / PASS（回報）** | 待補 | **565,724.74** | **−40.28%（−381,517.81）** | **31,497** | **`report_area(8).log`；V4→V5 Top −11.13%；`u_shared_pe_array` 62,752.88；全數驗證通過（回報）** |
| **V6** | **OPT-06：CONV2／FC2 共用 640-bit Channel PSUM Buffer** | **Golden／GLS PASS（回報）** | **10 ns / PASS（回報）** | 待補 | **552,503.69** | **−41.67%（−394,738.86）** | **31,497** | **`report_area(9).log`；V5→V6 Top −2.34%；Sequential Cells −640；`u_shared_ch_temp_buffer` 57,930.56；全數驗證通過（回報）** |
| **V7** | **OPT-07A：四層 Shared ReLU + Quantizer** | **Golden／GLS PASS（回報）** | **10 ns / PASS（回報）** | 待補 | **498,037.52** | **−47.42%（−449,205.03）** | **31,497** | **`report_area(10).log`；V6→V7 Top −9.86%；`u_shared_quantizer` 51,470.26；Combinational Area −54,883.73；全數驗證通過（回報）** |

### 2026-11-05 — OPT-01 實驗紀錄（V1）

- **Git Commit / Branch：** 待補；請保留對應 `conv2.sv` 和 DC Script 版本。
- **修改前：** 2×2 Pool 的四個 PSUM 分別 Quantize，再比較最大值。
- **修改後設計方向：** 先選出最大的 signed PSUM，再 Quantize 一次；需與實際 V1 RTL 再核對。
- **硬體證據：** `u_conv2` 大型量化乘法單元由四個縮成一個，並出現三個 Compare 單元。
- **Clock / Timing：** 10 ns；**PASS（使用者回報）**。WNS / TNS / Critical Path 未提供。
- **Total Cell Area：** 866,592.29（相較 V0 減少 80,650.26，8.51%）。
- **CONV2 Area：** 168,253.08（相較 V0 減少 80,618.01，32.39%）。
- **Sequential Cells：** 6,597（與 V0 相同）。
- **Golden Comparison / RTL Simulation：** 待補，**不可標記為 PASS**。
- **Lint / Latch / Multiple Driver：** 待補。
- **Latency (Cycles)：** 待補。
- **Gate-Level Simulation：** 尚未提供結果。
- **暫定結論：** **保留 V1 作為面積較小且 Timing 已回報過關的候選版本；完整驗證完成前，不升格為最終 Golden Baseline。**

### 2026-11-05 — OPT-02 實驗紀錄（V2）

- **Git Commit / Branch：** 待補；請保存實際採用的 `fc_buffer.sv` 和合成 Script。
- **修改前：** 120×8-bit FC Buffer，8 條動態 Byte Read Selection，組合邏輯成本高。
- **修改後：** 15×64-bit Banked Read，固定 Bank／Lane Decode 保留 CONV3 Byte Write 與 RELOAD84 Masked Write。
- **硬體證據：** `u_fc_buffer` Combinational Area 134,391.65 → 26,004.17，Sequential Area 不變。
- **Clock Constraint：** 延用 10 ns 目標；**V2 Timing 尚未回報**，不得標記 PASS。
- **Total Cell Area：** **758,936.39**；相較 V1 降 **107,655.90（12.42%）**，相較 V0 累計降 **188,306.16（19.88%）**。
- **FC Buffer Area：** **56,964.74**；相較 V1 降 **108,387.48（65.55%）**。
- **Total Cells：** 57,141（比 V1 少 11,911），Sequential Cells 仍為 6,597。
- **Golden Comparison / RTL Simulation：** **待補**。
- **Lint / Latch / Multiple Driver：** 待補。
- **WNS / TNS / Critical Path：** 待補。
- **Latency (Cycles)：** 待補。
- **Gate-Level Simulation：** 待補。
- **暫定結論：** 面積改善已量測且顯著；**只有 Golden、Timing 和檢查通過後才能正式採用 V2 作為驗證後的工作基準**。

### 2026-11-05 — Gate Sim 相關修正後的重新合成紀錄（V2.1）

- **版本定位：** FC Buffer 的 OPT-02 結構繼續使用，另外修正 Gate Simulation 所遇到的 RTL 問題；不是新的 OPT-03。
- **Git Commit / 修改檔案：** 待補（最新 RTL Diff 未隨 Area Report 附上）。
- **面積報告：** `report_area(3).log`，DC T-2022.03，2026-11-05 20:12:46，`slow.db`。
- **Total Cell Area：** **759,562.73**，相較 V2 **增加 626.34（+0.083%）**；相較 V0 **減少 187,679.82（19.81%）**。
- **Combinational / Noncombinational Area：** 545,994.17 / 213,568.56。
- **Total / Sequential Cells：** 57,213 / 6,601（比 V2 多 72 / 4）。
- **FC Buffer Area：** **56,964.74**，與 V2 相同；Banked Read 的面積改善仍在。
- **Clock Target：** 10 ns（沿用專案目標）；**V2.1 Setup PASS 未驗證**，WNS / TNS 待提供。
- **RTL / Golden：** 待提供實測結果。
- **Gate-Level Simulation：** 使用者表示已修正相關程式；**PASS 證據未提供**（尚需 GLS Log／結果）。
- **Latch / Multiple Driver / Width / Reset：** 待提供最新檢查結果。
- **結論：** **V2.1 曾作為後續面積比較的修正版基準**；後續已有 V3A～V6 的面積結果。Golden、GLS、10 ns Timing 仍需逐版本補充驗證。

### 2026-11-05 — OPT-03A Static Write Decoder 合成紀錄（V3A）

- **Git Commit / Branch：** 待補，與 V2.1 應各自保留 RTL Snapshot。
- **修改動機：** 嘗試降低 Shared Line Buffer 的動態 Row／Column Write Selection 面積。
- **修改方向（據對話）：** 採用固定位置的 Block FF 與 Enable Decode；不變更 Buffer 容量、5×5 Read Window 或 Pipeline。
- **合成報告：** `report_area(5).log`，2026-11-05 23:08:12，`slow.db`，DC T-2022.03。
- **Top Cell Area：** **759,250.41**；比 V2.1 減少 **312.32（0.041%）**；比 V0 減少 **187,992.14（19.85%）**。
- **`u_shared_line_buffer` Area：** **157,863.29**；比 V2.1 **增加 118.82（0.075%）**，沒有確認節省目標模組的面積。
- **Sequential Cells：** **6,601**，和 V2.1 一致。
- **Timing：** 10 ns 為既定目標；**本版 Timing PASS 未提供**，WNS／TNS／Critical Path 待補。
- **Golden Comparison / RTL Simulation：** 待提供，不推定 PASS。
- **Gate-Level Simulation：** 待提供，不推定 PASS。
- **合成可比性：** Top/主要 Module 階層一致、同 DC/Library；完整 SDC／Script 尚未提供。
- **結論：** **OPT-03A 面積改善不顯著；目標模組甚至略增。** 保留作為 A/B 實驗結果；若沒有 Timing／功耗／可維護性等額外收益，不應僅因 Top −0.041% 而採用。
- **後續：** 驗證 V3A 功能及 Timing；必要時回退並執行 OPT-03B（Window Read MUX），且同樣逐次保留 DC Area Report。

### 2026-11-06 — OPT-03B Window Read MUX 合成紀錄（V3B）

**2026-11-06 驗證結果補登：** Golden PASS、10 ns Timing PASS、Gate-Level Simulation PASS，Cycle Count = **31,497**（使用者回報）；WNS／TNS、Golden／GLS Log 待歸檔。

- **Git Commit / Branch：** 待補；需對照 V3A 與 V3B 的 `shared_line_buffer.sv` 實際 RTL Diff。
- **修改動機：** 降低 5×5 Window Read 中逐 Byte Dynamic Index 的大量 MUX。
- **修改方向（據前一輪討論）：** 8-Byte Chunk Selection → Byte Shift → 5×5 Row Selection；不增加 Pipeline FF、不改變 192 Bytes 的 Buffer 容量。
- **合成報告：** `report_area(6).log`，2026-11-06 14:18:01，T-2022.03、`slow.db`。
- **Top Total Cell Area：** **699,094.55**；相較 V3A 節省 **60,155.86（7.92%）**；相較 V0 累計節省 **248,148.00（26.20%）**。
- **Shared Line Buffer Area：** **99,075.54**；相較 V3A 節省 **58,787.75（37.24%）**，全部表現在 Buffer 的 Combinational Area。
- **Buffer Combinational Area：** `108,326.37 → 49,538.62`（**−54.27%**）；**Buffer Sequential Area 不變：49,536.92**。
- **Top Combinational / Noncombinational：** **485,549.76 / 213,544.79**。
- **Total / Sequential Cells：** **50,608 / 6,601**（相較 V3A Total Cells −6,616、Sequential Cells 不變）。
- **Timing：** 10 ns 為既定目標；**V3B 10 ns Timing PASS（使用者回報）**；WNS／TNS／Critical Path Report 待補。
- **Golden Comparison / RTL Simulation：** **PASS（使用者回報）**；Cycle Count = **31,497**，和之前版本相同。逐項 Window 邊界的專用測試 Log 尚未附上。
- **Gate-Level Simulation：** **PASS（使用者回報）**；原始 Log 待歸檔。
- **結論：** **OPT-03B 已達成實測面積節省、Golden PASS、10 ns Timing PASS、Gate-Level Simulation PASS（使用者回報），Cycle Count 不變（31,497）；在當時保存為完整驗證最佳版本；其後已有 V4～V6 的面積成果。**
- **後續：** 將 Golden／Timing／GLS Log、SDC、Git Commit 歸檔後，已進行 OPT-04B Shared PE 及 V4 面積量測；請參考下一段。

### 2026-11-06 — OPT-04B Shared PE Array 合成與完整驗證紀錄（V4）

- **修改目標：** 消除 CONV1 與 CONV2 各自持有的一組重複 5-PE 運算陣列；保留兩個 Layer 的控制與其他運算／記憶體結構。
- **實際合成階層：** 新增 `u_shared_pe_array`，內含 **5 個 `gen_shared_pe[*].pe_inst`**；原本 `u_conv1`／`u_conv2` 內的五個 PE 分別不再列於兩個 Layer 下。
- **相關 RTL：** `lenet.sv`、`conv1.sv`、`conv2.sv`、`shared_pe_array.sv`、`PE.sv`；本輪僅附 Area Report，**Git Commit、精確 RTL Diff 待歸檔**。
- **合成報告：** `report_area(7).log`，2026-11-06 21:26:12；Design `lenet`、DC T-2022.03、`slow.db`。
- **Top Total Cell Area：** **636,574.22**，相較 V3B **−62,520.33（−8.94%）**；相較 V0 **−310,668.33（−32.80%）**。
- **V4 Shared PE Array Area：** **62,705.35**。兩個 Layer ＋ Shared PE 合計 **214,622.65**，相較 V3B 兩個 Layer **277,682.76**，淨減 **63,060.11**。
- **Combinational / Noncombinational Area：** **423,068.46 / 213,505.75**。
- **Total / Sequential Cells：** **43,780 / 6,601**；V3B 的 Sequential Cells 也為 6,601。
- **Gate-Level Simulation：** **PASS（使用者回報）**；完整 Log 與 SDF 設定待歸檔。
- **RTL Golden：** **PASS（2026-11-06 使用者回報）**；完整 Golden Log 尚待歸檔。
- **10 ns Timing：** **PASS（2026-11-06 使用者回報）**；WNS／TNS／Critical Path Report 尚待歸檔。
- **Cycle Count：** **31,497（2026-11-06 使用者回報）**；與 V3B 一致，**Cycle Overhead = 0**。
- **保留判斷：** **V4 已同時完成 Area 降低、Golden PASS、10 ns Timing PASS、Gate Sim PASS，且不增加 Cycle Count**；保存為 V4 當時的已驗證最佳面積版本（現已由 V6 取代）。原始驗證 Log、SDC、Git Commit 仍建議保存。

### V4 完整驗證摘要（2026-11-06 使用者回報）

| 驗證項目 | V4 結果 | 證據狀態 |
|---|---|---|
| RTL Golden | **PASS** | 使用者回報，Golden Log 待歸檔 |
| Clock Constraint / Timing | **10 ns / PASS** | 使用者回報，WNS／TNS／Critical Path 待補 |
| Gate-Level Simulation | **PASS** | 使用者回報，GLS Log／是否有 SDF 待歸檔 |
| Cycle Count | **31,497**（與 V3B 一致） | 使用者回報；增加 **0 cycles** |
| Total Cell Area | **636,574.22** | DC `report_area(7).log` |
| Area vs V3B | **−62,520.33（−8.94%）** | 依 DC 面積數據計算 |
| Area vs V0 | **−310,668.33（−32.80%）** | 依 DC 面積數據計算 |

**綜合結論：** OPT-04B 使 CONV1／CONV2 由 10 個 PE 改為共用 5 個 PE，**降低 8.94% Top Cell Area、10 ns Timing 與 Golden／GLS 保持 PASS，且完整運算 Cycle Count 仍是 31,497**。目前不具備 Power、Floorplan / Routing 與實際延遲量測，不可將 DC Cell Area 節省直接等同完整 PPA 最佳化。

### 2026-11-06 — OPT-05 Unified Five-Layer 5-PE Array 合成與完整驗證紀錄（V5）

- **目標：** 讓 CONV3／FC1／FC2 原本各持有的兩顆 PE，也分時使用 V4 已建置的同一組五顆 Shared PE，**全設計五個 Layer 只保留五顆運算 PE**。
- **合成證據：** `u_shared_pe_array` 下僅列出 **五個 `gen_shared_pe[0..4].pe_inst`**；原本 CONV3、FC1、FC2 的 `gen_pe` 不再顯示。仍有獨立 `DW_mult`，不可把運算 PE 總數等同整體 Multiplier 總數。
- **合成報告：** `report_area(8).log`，2026-11-06 22:44:44；DC T-2022.03、`slow.db`、Design `lenet`。
- **Total Cell Area：** **565,724.74**，V4→V5 **−70,849.48（−11.13%）**；V0→V5 **−381,517.81（−40.28%）**。
- **Combinational / Noncombinational Area：** **352,509.24 / 213,215.50**；V4→V5 Combinational −70,559.22。
- **Total / Sequential Cells：** **40,240 / 6,601**；Sequential Cells 對 V4 不變。
- **PE Array Area：** **62,752.88**（V4 為 62,705.35；增加 47.53），五顆 PE 仍佔用硬體面積。
- **CONV3 + FC1 + FC2 Area：** **239,421.66 → 167,467.18（−71,954.49）**；此為跨層階層面積變化，Top 真正節省為 70,849.48。
- **Golden Comparison：** **PASS（使用者 2026-11-06 回報）**。
- **10 ns Timing：** **PASS（使用者回報）**；WNS／TNS／Critical Path 未提供。
- **Gate-Level Simulation：** **PASS（使用者回報）**；SDF 設定與原始 Log 尚待歸檔。
- **Cycle Count：** **31,497（使用者回報）**；與 V4 相同，**Cycle Overhead = 0**。
- **其他注意：** 主要降低 Combinational Area；未提供 Power、Wire-Load、Floorplan／Routing 的實測結果，不宣稱完整 PPA。
- **保留判斷：** **V5 已通過 Golden／10 ns Timing／GLS，完成五層五顆 PE 共用且不增加 Cycle；在當時為最低面積版本，後續已由 V6 取代。** 請保存對應 Git Commit、RTL Diff、SDC、Golden／GLS／Timing Reports。


### 2026-11-06 — OPT-06 Shared Channel PSUM Buffer 合成與完整驗證紀錄（V6）

- **修改目標：** CONV2 與 FC2 各自的 `ch_temp_psum`（640 bits × 2）改為共用一份 640-bit PSUM Buffer；保留 CONV2 Pooling、FC2 Bias／MAC、各層 Pipeline 與 SRAM 輸出行為。
- **修改範圍（依本次討論）：** `conv2.sv`、`fc2.sv`、`lenet.sv`、`shared_ch_temp_buffer.sv`；以 V6 Git Commit／RTL Diff 為準。
- **合成報告：** `report_area(9).log`，2026-11-06 23:54:47；DC T-2022.03、`slow.db`、Design `lenet`。
- **Total Cell Area：** **552,503.69**；V5→V6 **−13,221.05（−2.34%）**；V0→V6 **−394,738.86（−41.67%）**。
- **Combinational／Noncombinational Area：** **359,770.72／192,732.97**；與 V5 相比分別 **+7,261.48／−20,482.53**，共用控制與 MUX 的面積代價已反映於合成結果。
- **Total／Sequential Cells：** **40,169／5,961**；V5 Sequential Cells **6,601**，因此 **−640**（對應預期減少的一份 640-bit Buffer）。
- **共享 Buffer Hierarchy：** `u_shared_ch_temp_buffer` **57,930.56**；`u_conv2` **66,998.07**；`u_fc2` **25,175.84**。三個模組合計相較 V5 的兩層面積降低 **13,535.07**；Top 淨下降 **13,221.05**。
- **共享 PE：** `u_shared_pe_array` **62,717.23**，Hierarchy 仍列出 5 個 PE，不增加共享 PE 數量。
- **Golden Comparison：** **PASS（使用者 2026-11-06 回報）**。
- **10 ns Timing：** **PASS（使用者回報）**；WNS／TNS／Critical Path 未提供。
- **Gate-Level Simulation：** **PASS（使用者回報）**；是否 SDF Back-Annotated、原始 Log 待歸檔。
- **Cycle Count：** **31,497（使用者回報）**；與 V5 相同，**Cycle Overhead = 0**。
- **保留判斷：** **V6 已通過 Golden／10 ns Timing／GLS，且 DC 面積比 V5 降低 2.34%，因此在當時成為最低面積版本（目前已由 V7 取代）。** 完整 RTL Diff、SDC、Golden／Timing／GLS 原始輸出仍需歸檔；尚未量測 Power 和 Layout PPA。

### 2026-11-07 — OPT-07A Shared ReLU + Quantizer 合成與完整驗證紀錄（V7）

- **目標：** CONV1、CONV2、CONV3、FC1 分時使用 Top 的一份 ReLU／Scale Multiply／Shift／Saturate；保留 Pooling 原有先後順序及各 Layer 的 Result FF／Pipeline。
- **修改範圍（依前輪實作方案）：** `lenet.sv`、`conv1.sv`、`conv2.sv`、`conv3.sv`、`fc1.sv`，新增 `shared_quantizer.sv`；實際 RTL Snapshot／Git Diff 待歸檔。
- **DC Area Report：** `report_area(10).log`，2026-11-07 11:13:57，Design `lenet`、T-2022.03、`slow.db`。
- **Total Cell Area：** **498,037.52**；相較 V6 **−54,466.17（−9.86%）**；相較 V0 **−449,205.03（−47.42%）**。
- **Combinational／Noncombinational：** **304,886.99／193,150.53**，V6→V7 分別 **−54,883.73／+417.56**。
- **Cell Count：** Total **31,889（−8,280）**，Sequential **5,966（+5）**。並非節省 Sequential Buffer，而是減少重複 Combinational 量化乘法器。
- **新共享模組：** `u_shared_quantizer` **51,470.26**，含 `mult_18` **50,511.23**（子階層不重複加總）；原四層面積均明顯下降。
- **共用 PE：** `u_shared_pe_array` **69,326.91**（較 V6 +6,609.68），仍保留 **五顆**共享 PE。
- **Golden Comparison：** **PASS（2026-11-07 使用者回報）**。
- **10 ns Timing：** **PASS（使用者回報）**；WNS／TNS、Critical Path 待補。
- **Gate-Level Simulation：** **PASS（使用者回報）**；原始 Log、SDF 設定待歸檔。
- **Cycle Count：** **31,497**，與 V6 相同，**Cycle Overhead = 0**。
- **結論：** **V7 已通過 Golden／10 ns Timing／GLS，且 DC Cell Area 比 V6 下降 9.86%，為當前已驗證最低面積版本。** 真正淨收益以 Top 面積下降為準；尚未量測 Power、實體繞線面積或 Post-Route PPA。

### V3B 功能／時序／Gate-Level 驗證摘要（使用者回報）

| 驗證項目 | V3B 結果 | 證據狀態 |
|---|---|---|
| RTL Golden | **PASS** | 使用者回報，Log 待歸檔 |
| Clock Constraint / Timing | **10 ns / PASS** | 使用者回報，WNS／TNS 待補 |
| Gate-Level Simulation | **PASS** | 使用者回報，GLS Log 待歸檔 |
| Cycle Count | **31,497**（與各歷史版本一致） | 使用者回報 |
| Total Cell Area | **699,094.55** | DC `report_area(6).log` |

**Area Saving 計算：** `Saving (%) = (Baseline Area - New Area) / Baseline Area × 100%`

**判斷一次最佳化是否成功：** Golden PASS、10 ns Setup PASS、Latch / Multiple Driver 沒有新增問題，且 Total Area 確實下降；若 Cycle Count 增加，需另記錄 Area–Latency Trade-off。

## 7. 最佳化實驗 SOP

1. 為目前可合成版本建立 Git Tag／Commit，保留 Baseline `report_area.log` 與 Timing Report。
2. 只做一項 OPT 修改；Commit Message 寫清楚修改目的和 RTL 差異。
3. 用原始 Testbench 執行 RTL Simulation、比對 **各 Layer** Golden；避免只看 FC2 最終輸出。
4. 執行 Lint / SpyGlass，檢查 Latch、Multiple Driver、Width Mismatch、Unconnected Ports。
5. 用同一套 10 ns SDC 合成：保存 Area Report、Timing Report、Critical Path、警告訊息。
6. 若 Timing 和 Area 都較好，再跑 Gate-Level Simulation，確認沒有 Setup / Hold Violation。
7. 在第 6 節填入實測值；沒過的修改記錄原因並回退或獨立分支保存。

## 8. 單次實驗記錄模板

```markdown
### YYYY-MM-DD — OPT-XX：<修改名稱>

- Git Commit / Branch：
- 修改檔案：
- 修改前的硬體結構：
- 修改後的硬體結構：
- 為什麼預期會省面積：
- RTL Simulation：PASS / FAIL
- Golden Comparison：PASS / FAIL
- Lint / Latch / Multiple Driver：
- Clock Constraint：10 ns
- WNS / TNS：
- Total Cell Area：
- Area Saving vs V0：
- Latency (Cycles)：
- Gate-Level Simulation：PASS / FAIL / NOT RUN
- 結論：保留 / 回退 / 待研究
- 後續問題：
```

## 9. 重要備註

- **已取得 V0、V1、V2、V2.1、V3A、V3B、V4、V5、V6、V7 Area Reports**：V1 對 V0 −8.51%；V2 對 V1 −12.42%；V2.1 對 V2 +0.083%；V3A 對 V2.1 −0.041%；V3B 對 V3A −7.92%；V4 對 V3B −8.94%；V5 對 V4 −11.13%；V6 對 V5 −2.34%；**最新 V7 對 V6 −9.86%，對 V0 累計 −47.42%**。**V3B、V4、V5、V6、V7 Golden／10 ns Timing／GLS 均 PASS，Cycle Count 都是 31,497（使用者回報）**；需歸檔 `report_timing`、WNS／TNS、Golden／GLS Log 和完整 Synthesis Options。
- V0 `report_area.log` 顯示 CONV2 四個大型量化乘法器；V1 `report_area(1).log` 的相關大型 Multiplier 變為一個，且有三個 Comparator。**實際節省的是 Top Total Area 80,650.26**；不要把單一 Multiplier 的 Hierarchical Area 當作節省量。
- V2～V3B 面積結果證實 **FC Buffer 動態 Byte Index 是主要面積瓶頸之一**：Banked Read 後 `u_fc_buffer` Combinational Area 下降 80.65%。**V3A Static Write Decoder 沒有減少 Shared Line Buffer 的面積；V3B 的 Window Read MUX 最佳化則使 Shared Line Buffer Combinational Area 下降 54.27%**。V3B 整體 Golden 和 GLS 已 PASS（使用者回報）；若需要更嚴謹的模組級證據，可額外保存 Chunk 邊界、`row_sel` 與 Valid / SRAM 對齊的 Directed Tests。
- `shared_line_buffer` 和 `shared_weight_buffer` 已是共用實體；再次「抽 Module」本身不會再省面積，要最佳化的是實際綜合後的 Decoder、MUX、Register 及 Datapath。
- **V4／V5 的 PE Sharing：** V4 先讓 CONV1／CONV2 共用五顆 PE，V5 再讓 CONV3／FC1／FC2 分時使用同一組五顆；`u_shared_pe_array` 在 V5 為 **62,752.88**，不得把三個 Layer 移走的 PE 面積當作純粹總收益，真正的 V4→V5 Top 淨下降為 **70,849.48（11.13%）**。此外其他 Quantization / Arithmetic Multiplier 仍存在。
- **V6 的 Channel PSUM Buffer Sharing：** CONV2／FC2 共用一份 640-bit `u_shared_ch_temp_buffer`，Sequential Cells **−640**，但 Combinational Area **+7,261.48**；故不能把兩個 Layer 的合計下降 **71,465.63** 當作 Top 節省，新增共享模組自身 **57,930.56** 已計入，真正 Top 淨節省為 **13,221.05（2.34%）**。
- **V7 的 ReLU + Quantizer Sharing：** CONV1／CONV2／CONV3／FC1 使用 Top 唯一 `u_shared_quantizer`，面積 **51,470.26**；Sequential Cells **+5**、Combinational Area **−54,883.73**；`u_shared_pe_array` 及其他 Buffer 重新映射的增量已計入 Top，所以真正 Top 淨下降為 **54,466.17（9.86%）**。
- 若未來修改 Top Output FF 或 SRAM MUX，要同步檢查 SRAM 讀寫一拍延遲、最後一筆 Write 和 `compute_finish` 時序。

---

**資料來源：** V0 `report_area.log`（2026-11-05 00:32:10）、V1 `report_area(1).log`（01:34:17）、V2 `report_area(2).log`（09:53:06）、V2.1 `report_area(3).log`（20:12:46）、V3A `report_area(5).log`（23:08:12）、V3B `report_area(6).log`（2026-11-06 14:18:01）、V4 `report_area(7).log`（2026-11-06 21:26:12）、V5 `report_area(8).log`（2026-11-06 22:44:44）、V6 `report_area(9).log`（2026-11-06 23:54:47）、**V7 `report_area(10).log`（2026-11-07 11:13:57）**；先前 RTL 修改討論及使用者回報的 Simulation／Timing 狀態。另 `report_area(4).log` 為不同階層設計結果，不納入同架構比較。**V3B／V4／V5／V6／V7 Golden、10 ns Timing、GLS 均 PASS（使用者回報），Cycle Count 均為 31,497；V7 累計面積節省 47.42%；原始驗證 Log、WNS／TNS 與 SDC 待歸檔。**
