# LeNet Accelerator — Optimization Log

> 用途：記錄 RTL 架構最佳化、DC 面積與時序、功能驗證，以及每次修改的取捨。  
> 最後更新：2026-11-05  
> 專案：5-Layer Quantized LeNet Accelerator（SystemVerilog）
> **最新量測版本：V2.1（Gate Sim 相關 RTL 修正後）｜Total Cell Area 759,562.73｜Area Saving vs V0 = 19.81%｜Timing／GLS 結果待附證明**

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

**相較 V0 累計面積減少：187,679.82（19.81%）。** 相較 V1 減少 **107,029.56（12.35%）**。這是**最新版本**的實測數字；不可再把 V2 的 758,936.39 當作 Gate Sim 修正後版本的面積。

#### 最新模組面積（V2.1）

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

## 3. 已進行的架構重構（尚未單獨量測面積收益）

| 編號 | 項目 | 目前設計 | 備註 |
|---|---|---|---|
| R-01 | Shared Line Buffer | CONV1／CONV2／CONV3 使用同一個 `shared_line_buffer` | 一份 6 × 32 Bytes（192 B）儲存體，支援 CONV1 Row Shift、CONV2 Reload 和 CONV3 64-bit Vector |
| R-02 | Shared Weight Buffer | CONV1／CONV2／CONV3／FC1／FC2 共用 `shared_weight_buffer` | 5 × 5 × 8-bit（200 bits）；Conv1/2 用 Kernel Mode，其餘層用 Vector Mode |
| R-03 | Shared FC Buffer | CONV3 寫入 120 Bytes；FC1 讀取；RELOAD84 載入 FC1 輸出後供 FC2 讀取 | 120 × 8-bit；支援 8-bit Write、64-bit Masked Write、64-bit Read |
| R-04 | Weight/Bias 分時讀取 | FC2 先讀 Weight MAC，再以雙 Port 讀 Bias，與 `ch_temp_psum` 相加 | Bias 不進 Shared Weight Buffer |

> 注意：**程式重構完成 ≠ 已證實省面積**。V0 947k 為重構後的首次總量測；若沒有重構前、相同 Constraint 的 Area Report，無法宣稱上述各項實際各省多少。

## 4. 下一輪最佳化待辦（按優先順序）

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

**狀態：** **V2 完成 Area 量測（−12.42% vs V1）；V2.1 已完成 Gate Sim 相關 RTL 修正後的最新 Area 量測，`u_fc_buffer` 面積維持不變。Timing／Golden／GLS PASS 證據仍待補。**  
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

**狀態：** 待設計 / 待驗證  
**優先級：** P2  
**檔案：** `shared_line_buffer.sv`、必要時各 CONV Controller

**現況：** 最新 V2.1 `u_shared_line_buffer` Total **157,744.47**，其中 Combinational **108,207.55**、Noncombinational **49,536.92**，占 Top **20.8%**。目前是主要的 Buffer 最佳化對象；可能較貴的結構包括：

```systemverilog
line_buffer[row_pair*2][col_blk*4+:4] <= wdata0;
line_buffer[row_pair*2+1][col_blk*4+:4] <= wdata1;
pe_window[r][c] = line_buffer[r][col+c];
```

**候選方向：**

1. 用固定 Row、固定 Column Block 的 `generate` / explicit enable decode 取代部分動態寫入位置。
2. 依 CONV1/2 的合法 Column 範圍限制 Window MUX；比較扇入數與 Critical Path。
3. 分析 CONV1 Row Shift 造成的選擇邏輯與大量 FF 更新。
4. 切勿為省 MUX 擅自增加 Pipeline Stage，除非同時修正 PE Valid / Weight / Activation 對齊。

**驗證條件：** CONV1 每次 Strip Shift、CONV2 每次 Input Channel Reload、CONV3 每組 64-bit Vector 都必須與原版完全相同。

### OPT-04：跨 Layer PE Sharing（最後再做）

**狀態：** 待可行性評估  
**優先級：** P3  

CONV1 與 CONV2 目前各自例化 5 個 PE、每個 PE 5 個 8-bit Multipliers，執行時間不重疊。可研究共用 PE / MAC Datapath，但需要重構 `pe_valid`、Metadata Pipeline、PSUM / Pooling 和 Controller，不適合與 Buffer 最佳化同時實施。

**風險：** 可能增加 Operand MUX、降低 Fmax、影響 Cycle 數；必須同時評估 Area、Latency 和 Throughput。

## 5. 優先順序總覽

| 順序 | ID | 主要目標 | 預期改動範圍 | 風險 | 狀態 |
|---|---|---|---|---|---|
| 1 | OPT-01 | CONV2 去除重複 Quantization | Pooling / Arithmetic | 低～中 | **V1 合成完成：10 ns PASS／Area −8.51%；Golden 待補** |
| 2 | OPT-02 | FC Buffer Banked Read | 讀寫儲存路徑 | 中 | **V2 Area −12.42% vs V1；V2.1 修正後 Area 759,562.73；Timing／Golden／GLS 待確認** |
| 3 | OPT-03 | Shared Line Buffer MUX / Decoder | Window / Write Decode | 中～高 | 待實作 |
| 4 | OPT-04 | CONV1/2 PE Sharing | Datapath / Control / Pipeline | 高 | 待評估 |

> OPT-01 與 OPT-02 均已完成合成面積量測。**最新可追溯的合成面積版本為 V2.1**，不是 V2。先確認 V2.1 的 Golden、Gate-Level Simulation 與 Timing，再進行 OPT-03（Shared Line Buffer）。

## 6. 每次實驗的量測紀錄

> 所有版本使用相同 Library、SDC、Clock Period、Synthesis Options 和同一組 Golden。沒有完整 Timing Report 時，只記錄「使用者確認 Timing PASS」，不要自行填寫 WNS。

| Version | 主要改動 | RTL / Golden | Clock | WNS (ns) | Total Cell Area | Area Δ vs Baseline | Cycle Count | 備註 |
|---|---|---|---|---|---:|---:|---|---|
| V0 | Shared Line/Weight/FC Buffer Baseline | 待補 | 10 ns / PASS（回報） | 待補 | **947,242.55** | 0% | 待補 | `report_area.log` |
| V1 | OPT-01：Max Pool before Quantization | **待補 Golden** | **10 ns / PASS（回報）** | 待補 | **866,592.29** | **−8.51%（−80,650.26）** | 待補 | `report_area(1).log`；合成日期 2026-11-05 01:34:17 |
| V2 | OPT-02：FC Buffer Banked Read | **Golden 待確認** | **10 ns 目標／Timing 未提供** | 待補 | **758,936.39** | **−19.88%（−188,306.16）** | 待補 | `report_area(2).log`；V1→V2 −12.42% |
| **V2.1** | **Gate Sim 相關 RTL 修正（保留 OPT-02）** | **Golden／GLS 結果待提供** | **10 ns 目標／Timing 未提供** | 待補 | **759,562.73** | **−19.81%（−187,679.82）** | 待補 | **`report_area(3).log`；V2→V2.1 +0.083%；Seq Cells +4；FC Buffer 不變** |
| V3 | OPT-03：Line Buffer MUX Optimization | 待測 | 待測 | 待測 | 待測 | 待測 | 待測 |  |
| V4 | OPT-04：Shared PE（如實施） | 待測 | 待測 | 待測 | 待測 | 待測 | 待測 |  |

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
- **結論：** **以 V2.1 作為後續面積比較的最新修正版基準**；待 Golden、GLS、10 ns Timing 完成驗證，再確認是否可定為正式 Golden Baseline。

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

- **已取得 V0、V1、V2、V2.1 Area Reports**：V1 相對 V0 減少 8.51%；V2 相對 V1 減少 12.42%；**最新 V2.1 相對 V2 增加 0.083%，相對 V0 累計減少 19.81%**。仍缺 V2.1 `report_timing`、WNS／TNS、Golden／RTL Simulation、Gate-Level Simulation Log 和完整 Synthesis Options，**不得宣稱 V2.1 Timing／Golden／GLS PASS**。
- V0 `report_area.log` 顯示 CONV2 四個大型量化乘法器；V1 `report_area(1).log` 的相關大型 Multiplier 變為一個，且有三個 Comparator。**實際節省的是 Top Total Area 80,650.26**；不要把單一 Multiplier 的 Hierarchical Area 當作節省量。
- V2、V2.1 面積結果證實 **FC Buffer 動態 Byte Index 是主要面積瓶頸之一**：Banked Read 後 `u_fc_buffer` Combinational Area 下降 80.65%。Shared Line Buffer 的動態 Window／Write Decode 仍是下一個優化對象。
- `shared_line_buffer` 和 `shared_weight_buffer` 已是共用實體；再次「抽 Module」本身不會再省面積，要最佳化的是實際綜合後的 Decoder、MUX、Register 及 Datapath。
- 若未來修改 Top Output FF 或 SRAM MUX，要同步檢查 SRAM 讀寫一拍延遲、最後一筆 Write 和 `compute_finish` 時序。

---

**資料來源：** V0 `report_area.log`（2026-11-05 00:32:10）、V1 `report_area(1).log`（01:34:17）、V2 `report_area(2).log`（09:53:06）、**V2.1 `report_area(3).log`（20:12:46）**；先前 RTL／FC Buffer 修改討論，以及使用者回報的 V0／V1 10 ns Timing PASS。本次 Gate Sim 相關修正的確切 RTL Diff 和 GLS PASS 證據未附上；**V2.1 Timing、Golden／GLS 均待確認**。
