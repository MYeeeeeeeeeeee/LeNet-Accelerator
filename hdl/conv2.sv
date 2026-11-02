// Existing pipeline, read/write arbitration, packing and SRAM timing retained.
// "enable" is a LEVEL while Top is in CONV2, not an additional start pulse.
module conv2 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    output logic        done,        // delayed final CONV2 packed word; 1-cycle pulse
    input  logic [31:0] scale_CONV2,

    output logic [ 3:0] sram_weight_wea0,
    output logic [15:0] sram_weight_addr0,
    output logic [31:0] sram_weight_wdata0,
    input  logic [31:0] sram_weight_rdata0,
    output logic [ 3:0] sram_weight_wea1,
    output logic [15:0] sram_weight_addr1,
    output logic [31:0] sram_weight_wdata1,
    input  logic [31:0] sram_weight_rdata1,

    output logic [ 3:0] sram_act_wea0,
    output logic [15:0] sram_act_addr0,
    output logic [31:0] sram_act_wdata0,
    input  logic [31:0] sram_act_rdata0,
    output logic [ 3:0] sram_act_wea1,
    output logic [15:0] sram_act_addr1,
    output logic [31:0] sram_act_wdata1,
    input  logic [31:0] sram_act_rdata1,


    // Shared Line Buffer write request
    output logic        lb_load_valid,
    output logic        lb_init_load,
    output logic        lb_shift_rows,
    output logic [ 2:0] lb_row_pair,
    output logic [ 3:0] lb_col_blk,
    output logic [31:0] lb_wdata0,
    output logic [31:0] lb_wdata1,

    // Shared Line Buffer window selection
    output logic       lb_row_sel,
    output logic [4:0] lb_col,

    // Window returned from the shared buffer
    input logic [4:0][7:0] pe_window[0:4],

    output logic        wb_load_valid,
    output logic [ 3:0] wb_kernel_idx,
    output logic [31:0] wb_wdata0,

    input logic signed [4:0][7:0] shared_weight[0:4]

);
    // input enable buffered to preserve SRAM timing
    logic enable_buf;

    // Inputs buffered inside layer, at the SAME edge as in former lenet.sv.
    logic [31:0] scale_CONV2_buf;
    logic [31:0] sram_weight_rdata0_buf;
    logic [31:0] sram_act_rdata0_buf, sram_act_rdata1_buf;

    // Activation and weight address counters.
    logic row_sel;
    logic [4:0] col;
    logic [4:0] strip_idx;
    logic [4:0] fill_cnt;
    logic [4:0] load_idx_s2, load_idx_s3, load_idx_s4;
    logic [2:0] act_row_pair_s1, act_row_pair_s4;
    logic [3:0] act_col_blk_s1, act_col_blk_s4;

    logic [15:0] global_w_offset;
    logic [15:0] local_w_offset;
    logic [ 3:0] kernel_idx;
    logic [3:0] kernel_idx_s2, kernel_idx_s3, kernel_idx_s4;
    logic [16:0] write_addr;

    // Pooling and output packing counters.
    logic [ 1:0] package_cnt;
    logic [ 3:0] pool_col_base;
    logic [ 2:0] pool_emit_idx;

    // Processing-stage validity pipeline.
    // Main pipeline stages:
    //   Pipeline 1: issue SRAM reads and capture the current control state.
    //   Pipeline 2: align read data and sideband signals.
    //   Pipeline 3: present a valid sliding-window operation to the PE array.
    //   Pipeline 4: register PE results before quantization and pooling.
    logic s1_valid, s2_valid, s3_valid, s4_valid;

    // Four-stage activation-load side pipeline.
    // These signals carry one activation read from Pipeline 1 through
    // Pipelines 2-4 so SRAM data and line-buffer writes remain aligned.
    logic load_valid_s1, load_valid_s2, load_valid_s3, load_valid_s4;

    // Four-stage weight-load side pipeline.
    // The validity and kernel index travel through the same four stages as
    // the packed weight data returned by SRAM.
    logic weight_valid_s1, weight_valid_s2, weight_valid_s3, weight_valid_s4;

    // Processing readiness.
    logic line_buffer_ready;
    logic weight_ready;
    logic pe_valid;

    // Strip and processing control.
    logic flush;
    logic channel_mac_done;
    logic last_mac_fire;

    // Activation read controls.
    logic act_read_fire;

    // Pooling and output-packing validity.
    logic pool_valid;
    logic pack_valid;

    // Output-channel transition control.
    logic change_out_ch;

    // Sliding-window data path.
    // PE inputs are selected from six buffered rows; PE results are registered
    // at Pipeline 4 before the arithmetic post-processing block.
    logic signed [18:0] pe_out_s4[0:4];
    //logic signed [4:0][7:0] weight_reg[0:4];
    logic signed [9:0][31:0] ch_temp_psum[0:1];
    logic signed [18:0] pe_out[0:4];

    // Quantization, pooling, and output-packing data.
    logic [7:0] current_max;
    logic [31:0] pack_data;
    logic signed [3:0][7:0] result_reg;
    logic signed [19:0] conv_sum;
    logic signed [31:0] conv_sum_ext;
    logic psum_reg_full;
    logic pool_emit_active;
    logic [7:0] q0, q1, q2, q3;

    // Completion state is owned by this layer instead of the parent Top.
    logic conv2_done;

    logic [1:0] done_delay;

    logic [2:0] in_ch;
    logic [3:0] out_ch;
    logic change_in_ch;

    logic channel_last_pool;
    logic strip_next;
    logic end_input_mac;
    logic [16:0] in_ch_offset;

    logic [2:0] in_ch_s4;
    logic [4:0] col_s4;
    logic row_sel_s4;

    // Shared combinational control. Keep cross-block assignments together;
    // assignments used by one sequential block remain next to that block.
    // Pipeline 1 is valid whenever CONV2 is enabled. Activation reads are
    // issued only while the current strip still needs input words, and are
    // blocked when the output packer is using the activation SRAM port.
    assign s1_valid = enable_buf;
    assign load_valid_s1 = s1_valid && (fill_cnt < 5'd12);
    assign act_read_fire = load_valid_s1 && !pack_valid;

    // A weight read is valid for the ten packed words belonging to the
    // current input/output-channel pair.
    assign weight_valid_s1 = s1_valid && (kernel_idx < 4'd10);

    // Decode the Pipeline 1 activation word index into a row pair and column
    // block. The same fields are decoded again from the delayed Pipeline 4
    // index when the SRAM data reaches the line buffer.
    assign act_row_pair_s1 = fill_cnt[3:2];  // Row pairs 0/1, 2/3, and 4/5.
    assign act_col_blk_s1 = fill_cnt[1:0];  // Column block 0 through 7.
    assign act_row_pair_s4 = load_idx_s4[3:2];
    assign act_col_blk_s4 = load_idx_s4[1:0];

    // Assert at the lower-row/right-edge MAC that ends the current input
    // channel. These flags reset the input-channel state or advance to the
    // next strip/output channel at their respective boundaries.
    assign end_input_mac = pe_valid && (row_sel == 1'b1) && (col == 5'd9);
    assign change_in_ch = end_input_mac && (in_ch < 3'd5);
    assign channel_last_pool = pool_valid && (pool_emit_idx == 3'd4) &&
                               (strip_idx == 5'd4) && (in_ch == 3'd5);
    assign change_out_ch = channel_last_pool && (out_ch < 4'd15);

    // A PE operation is allowed only after Pipeline 3 is valid and both the
    // activation line buffer and the packed weights are ready.
    assign pe_valid = s3_valid && line_buffer_ready && weight_ready && !channel_mac_done;

    // Flush the activation-load counter at the end of an input-channel
    // strip, or advance to the next strip after the last input channel.
    assign flush = pe_valid && (row_sel == 1'b1) && (col == 5'd9) &&
                   (strip_idx < 5'd4) && (in_ch < 3'd5);
    assign strip_next = end_input_mac && (in_ch == 3'd5) && (strip_idx < 5'd4);

    // pool_emit_active opens the five-cycle pooling window after the final
    // PSUM write; every fourth pooled byte completes one output word.
    assign pool_valid = pool_emit_active;
    assign pack_valid = pool_valid && (package_cnt == 2'd3);

    // Generate-loop index for the processing elements.
    genvar i;

    assign lb_load_valid = load_valid_s4;

    // CONV2 always reloads six rows
    assign lb_init_load  = 1'b1;
    assign lb_shift_rows = 1'b0;

    assign lb_row_pair   = act_row_pair_s4;
    assign lb_col_blk    = act_col_blk_s4;

    assign lb_wdata0     = sram_act_rdata0_buf;
    assign lb_wdata1     = sram_act_rdata1_buf;

    assign lb_row_sel    = row_sel;
    assign lb_col        = col;

    // CONV2 weight buffer
    assign wb_load_valid = weight_valid_s4;
    assign wb_kernel_idx = kernel_idx_s4;
    assign wb_wdata0     = sram_weight_rdata0_buf;

    // Static SRAM output assignments. CONV2 reads weights only; activation
    // writes are generated later by the output-packing path.
    always_ff @(posedge clk or negedge rst_n) begin : unused_sram_ff
        if (!rst_n) begin
            sram_weight_addr1  <= 16'd0;
            sram_weight_wdata0 <= 32'd0;
            sram_weight_wdata1 <= 32'd0;
            sram_weight_wea0   <= 4'd0;
            sram_weight_wea1   <= 4'd0;
        end else begin
            sram_weight_addr1  <= sram_weight_addr1;
            sram_weight_wdata0 <= sram_weight_wdata0;
            sram_weight_wdata1 <= sram_weight_wdata1;
            sram_weight_wea0   <= sram_weight_wea0;
            sram_weight_wea1   <= sram_weight_wea1;
        end
    end : unused_sram_ff

    // Input buffering remains one register deep, preserving the original
    // SRAM timing from the former combined lenet module.
    always_ff @(posedge clk or negedge rst_n) begin : input_buffer
        if (!rst_n) begin
            enable_buf             <= 1'b0;
            scale_CONV2_buf        <= 32'd0;
            sram_weight_rdata0_buf <= 32'd0;
            sram_act_rdata0_buf    <= 32'd0;
            sram_act_rdata1_buf    <= 32'd0;
        end else begin
            enable_buf             <= enable;
            scale_CONV2_buf        <= scale_CONV2;
            sram_weight_rdata0_buf <= sram_weight_rdata0;
            sram_act_rdata0_buf    <= sram_act_rdata0;
            sram_act_rdata1_buf    <= sram_act_rdata1;
        end
    end : input_buffer

    // Pipeline 1 control: activation read address and fill counter.
    // The same address block also services Pipeline 4 output writeback.
    assign in_ch_offset = in_ch * 16'd56;

    always_ff @(posedge clk or negedge rst_n) begin : act_addr_gen
        if (!rst_n) begin
            sram_act_addr0 <= '0;
            sram_act_addr1 <= '0;
            write_addr <= '0;
        end else if (pack_valid) begin
            sram_act_addr0 <= conv2_out_offset + write_addr;
            write_addr <= write_addr + 1;
        end else if (act_read_fire) begin
            sram_act_addr0 <= conv2_in_offset + in_ch_offset +
                              ((strip_idx * 2 + act_row_pair_s1 * 2) * 4) +
                              act_col_blk_s1;
            sram_act_addr1 <= conv2_in_offset + in_ch_offset +
                              ((strip_idx * 2 + act_row_pair_s1 * 2 + 1) * 4) +
                              act_col_blk_s1;
        end else begin
            sram_act_addr0 <= sram_act_addr0;
            sram_act_addr1 <= sram_act_addr1;
        end
    end : act_addr_gen

    always_ff @(posedge clk or negedge rst_n) begin : line_counter
        if (!rst_n) begin
            fill_cnt <= 5'd0;
        end else if (change_in_ch || strip_next || change_out_ch) begin
            fill_cnt <= 5'd0;
        end else if (flush) begin
            fill_cnt <= 5'd0;
        end else if (act_read_fire) begin
            if (fill_cnt == 5'd12) fill_cnt <= fill_cnt;
            else fill_cnt <= fill_cnt + 1;
        end else begin
            fill_cnt <= fill_cnt;
        end
    end : line_counter

    // Pipeline 1 control: packed-weight address and channel counters.
    // Channel transitions are feedback from the Pipeline 4 completion path.
    assign local_w_offset  = in_ch * 16'd10;
    assign global_w_offset = out_ch * 16'd60 + conv2_weight_offset;

    always_ff @(posedge clk or negedge rst_n) begin : weight_addr_gen
        if (!rst_n) begin
            sram_weight_addr0 <= '0;
        end else if (s1_valid && kernel_idx < 10) begin
            sram_weight_addr0 <= global_w_offset + local_w_offset + kernel_idx;
        end else begin
            sram_weight_addr0 <= sram_weight_addr0;
        end
    end : weight_addr_gen

    always_ff @(posedge clk or negedge rst_n) begin : ch_counter
        if (!rst_n) begin
            in_ch  <= 3'd0;
            out_ch <= 4'd0;
        end else if (change_out_ch) begin
            in_ch  <= 3'd0;
            out_ch <= out_ch + 1'b1;
        end else if (strip_next) begin
            in_ch <= 3'd0;
        end else if (change_in_ch) begin
            in_ch <= in_ch + 1'b1;
        end else begin
            in_ch  <= in_ch;
            out_ch <= out_ch;
        end
    end : ch_counter

    always_ff @(posedge clk or negedge rst_n) begin : kernel_counter
        if (!rst_n) begin
            kernel_idx <= 4'd0;
        end else if (s1_valid) begin
            if (change_out_ch || change_in_ch || strip_next) begin
                kernel_idx <= 4'd0;
            end else if (kernel_idx < 4'd10) begin
                kernel_idx <= kernel_idx + 1;
            end else begin
                kernel_idx <= kernel_idx;
            end
        end else begin
            kernel_idx <= kernel_idx;
        end
    end : kernel_counter

    // Main four-stage valid pipeline.
    // Pipeline 1 is driven directly by enable; each following pipeline
    // advances one clock later, with Pipeline 4 marking PE output timing.
    always_ff @(posedge clk or negedge rst_n) begin : valid_pipeline
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            s4_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s3_valid <= s2_valid;
            s4_valid <= pe_valid;
        end
    end : valid_pipeline

    // Pipeline 1 activation-read qualification.
    // The request is suppressed while an output word is being packed so that
    // activation SRAM address and write traffic do not conflict.
    // Activation side pipeline: Pipeline 1 -> Pipeline 2 -> Pipeline 3
    // -> Pipeline 4. The Pipeline 4 pulse performs the delayed write.
    always_ff @(posedge clk or negedge rst_n) begin : load_valid_pipeline
        if (!rst_n) begin
            load_valid_s2 <= 1'b0;
            load_valid_s3 <= 1'b0;
            load_valid_s4 <= 1'b0;
        end else begin
            load_valid_s2 <= act_read_fire;
            load_valid_s3 <= load_valid_s2;
            load_valid_s4 <= load_valid_s3;
        end
    end : load_valid_pipeline

    // Activation side pipeline: delay the SRAM word index alongside valid.
    always_ff @(posedge clk or negedge rst_n) begin : load_idx_pipeline
        if (!rst_n) begin
            load_idx_s2 <= 5'd0;
            load_idx_s3 <= 5'd0;
            load_idx_s4 <= 5'd0;
        end else begin
            load_idx_s2 <= fill_cnt;
            load_idx_s3 <= load_idx_s2;
            load_idx_s4 <= load_idx_s3;
        end
    end : load_idx_pipeline

    // Weight side pipeline: Pipeline 1 -> Pipeline 2 -> Pipeline 3
    // -> Pipeline 4. Pipeline 4 updates the packed kernel register.
    always_ff @(posedge clk or negedge rst_n) begin : weight_valid_pipeline
        if (!rst_n) begin
            weight_valid_s2 <= 1'b0;
            weight_valid_s3 <= 1'b0;
            weight_valid_s4 <= 1'b0;
        end else begin
            weight_valid_s2 <= weight_valid_s1;
            weight_valid_s3 <= weight_valid_s2;
            weight_valid_s4 <= weight_valid_s3;
        end
    end : weight_valid_pipeline

    // Weight side pipeline: delay the packed-kernel word index with validity.
    always_ff @(posedge clk or negedge rst_n) begin : kernel_idx_pipeline
        if (!rst_n) begin
            kernel_idx_s2 <= 4'd0;
            kernel_idx_s3 <= 4'd0;
            kernel_idx_s4 <= 4'd0;
        end else begin
            kernel_idx_s2 <= kernel_idx;
            kernel_idx_s3 <= kernel_idx_s2;
            kernel_idx_s4 <= kernel_idx_s3;
        end
    end : kernel_idx_pipeline

    // Processing readiness: Pipeline 3 cannot issue PE work until both the
    // activation line buffer and the complete packed kernel are available.
    always_ff @(posedge clk or negedge rst_n) begin : line_buffer_status
        if (!rst_n) line_buffer_ready <= 1'b0;
        else if (change_in_ch || strip_next || change_out_ch) line_buffer_ready <= 1'b0;
        else if (load_valid_s4 && load_idx_s4 == 5'd11) line_buffer_ready <= 1'b1;
        else line_buffer_ready <= line_buffer_ready;
    end : line_buffer_status

    always_ff @(posedge clk or negedge rst_n) begin : weight_status
        if (!rst_n) weight_ready <= 1'b0;
        else if (change_in_ch || change_out_ch || strip_next) weight_ready <= 1'b0;
        else if (weight_valid_s4 && kernel_idx_s4 == 4'd9) weight_ready <= 1'b1;
        else weight_ready <= weight_ready;
    end : weight_status

    // Pipeline 3 PE issue control and end-of-channel detection.
    // A PE operation is issued only after the Pipeline 2/3 control path,
    // activation line buffer, and weight registers are all ready.
    // Detect the final MAC operation for the current output channel.
    assign last_mac_fire = end_input_mac && (in_ch == 3'd5) && (strip_idx == 5'd4);

    always_ff @(posedge clk or negedge rst_n) begin : channel_mac_done_ff
        if (!rst_n) channel_mac_done <= 1'b0;
        else if (change_out_ch) channel_mac_done <= 1'b0;
        else if (last_mac_fire) channel_mac_done <= 1'b1;
        else channel_mac_done <= channel_mac_done;
    end : channel_mac_done_ff

    // Pipeline 3 window traversal. Each valid PE operation processes two row
    // positions before moving to the next column or strip.

    always_ff @(posedge clk or negedge rst_n) begin : compute_counter
        if (!rst_n) begin
            col <= 5'd0;
            row_sel <= 1'b0;
            strip_idx <= 5'd0;
        end else if (change_out_ch) begin
            col <= 5'd0;
            row_sel <= 1'b0;
            strip_idx <= 5'd0;
        end else if (flush) begin
            col <= 5'd0;
            row_sel <= 1'b0;
            strip_idx <= strip_idx;
        end else if (strip_next) begin
            col <= 5'd0;
            row_sel <= 1'b0;
            strip_idx <= strip_idx + 1'b1;
        end else if (pe_valid) begin
            if (row_sel == 1'b1) begin
                row_sel <= 1'b0;  // Both row positions are complete; move right.
                if (col == 5'd9) begin
                    col <= 5'd0;
                end else begin
                    col <= col + 1;
                end
            end else begin
                row_sel <= 1'b1;  // Process the lower row position next.
            end
        end
    end : compute_counter

    // Pipeline 3 parallel convolution. Five PE instances calculate one
    // 5x5 channel result in parallel from the selected sliding window.
    generate
        for (i = 0; i < 5; i++) begin : gen_pe
            PE #(
                .INPUT_WIDTH (8),
                .OUTPUT_WIDTH(20)
            ) pe_inst (
                .weight(shared_weight[i]),
                .activation(pe_window[i]),
                .valid(pe_valid),
                .mode(CONV),
                .result(pe_out[i])
            );
        end : gen_pe
    endgenerate

    // Pipeline 4: assemble the packed weight word returned by the weight
    // side pipeline before it is consumed by the PE.
    /*
    always_ff @(posedge clk or negedge rst_n) begin : weight_reg_ff
        if (!rst_n) begin
            foreach (weight_reg[i]) weight_reg[i] <= '0;
        end else if (weight_valid_s4) begin
            if (kernel_idx_s4[0] == 1'b0)
                weight_reg[kernel_idx_s4[3:1]][3:0] <= sram_weight_rdata0_buf;
            else weight_reg[kernel_idx_s4[3:1]][4] <= sram_weight_rdata0_buf[7:0];
        end
    end : weight_reg_ff
     */

    // Pipeline 4 result register. This register isolates the PE combinational
    // result from the quantization and pooling logic.
    always_ff @(posedge clk or negedge rst_n) begin : pe_psum_loc
        if (!rst_n) begin
            in_ch_s4   <= '0;
            col_s4     <= '0;
            row_sel_s4 <= '0;
        end else if (pe_valid) begin
            in_ch_s4   <= in_ch;
            col_s4     <= col;
            row_sel_s4 <= row_sel;
        end else begin
            in_ch_s4   <= in_ch_s4;
            col_s4     <= col_s4;
            row_sel_s4 <= row_sel_s4;
        end
    end : pe_psum_loc

    always_ff @(posedge clk or negedge rst_n) begin : pe_out_ff
        if (!rst_n) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= '0;
        end else if (pe_valid) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= pe_out[i];
        end else begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= pe_out_s4[i];
        end
    end : pe_out_ff

    // Pipeline 4 arithmetic post-processing: accumulate the five PE results and
    // extend the signed value before channel PSUM accumulation.
    assign conv_sum = $signed(
        pe_out_s4[0]
    ) + $signed(
        pe_out_s4[1]
    ) + $signed(
        pe_out_s4[2]
    ) + $signed(
        pe_out_s4[3]
    ) + $signed(
        pe_out_s4[4]
    );

    // Mark the final PSUM write for the current spatial position.
    assign psum_reg_full = s4_valid && (in_ch_s4 == 3'd5) &&
                           (col_s4 == 5'd9) && (row_sel_s4 == 1'b1);

    assign conv_sum_ext = {{12{conv_sum[19]}}, conv_sum};

    always_ff @(posedge clk or negedge rst_n) begin : channel_psum_ff
        if (!rst_n) foreach (ch_temp_psum[i]) ch_temp_psum[i] <= '0;
        else if (s4_valid) begin
            if (in_ch_s4 == 3'd0) begin
                ch_temp_psum[row_sel_s4][col_s4] <= conv_sum_ext;
            end else begin
                ch_temp_psum[row_sel_s4][col_s4] <= ch_temp_psum[row_sel_s4][col_s4] + conv_sum_ext;
            end
        end else begin
            foreach (ch_temp_psum[i]) ch_temp_psum[i] <= ch_temp_psum[i];
        end
    end : channel_psum_ff

    // 32-bit PSUM -> ReLU -> Quantization
    function automatic logic [7:0] quantize_psum(input logic signed [31:0] psum_value,
                                                 input logic [31:0] scale_value);
        logic [31:0] positive;
        logic [63:0] product;
        logic [63:0] shifted;

        begin
            if (psum_value <= 0) return 8'd0;
            positive = $unsigned(psum_value);
            product  = positive * scale_value;
            shifted  = product >> 16;

            if (shifted > 64'd127) return 8'd127;
            else return shifted[7:0];
        end
    endfunction

    // Wait for the final PSUM write to complete.
    always_ff @(posedge clk or negedge rst_n) begin : pool_emit_control
        if (!rst_n) begin
            pool_emit_active <= 1'b0;
            pool_emit_idx    <= 3'd0;
        end else if (psum_reg_full) begin
            pool_emit_active <= 1'b1;
            pool_emit_idx    <= 3'd0;
        end else if (pool_emit_active) begin
            if (pool_emit_idx == 3'd4) begin
                pool_emit_active <= 1'b0;
            end else begin
                pool_emit_idx <= pool_emit_idx + 1'b1;
            end
        end
    end : pool_emit_control

    // Select the two adjacent columns used by the current 2x2 pooling window.
    assign pool_col_base = {pool_emit_idx, 1'b0};

    always_comb begin : pool_max
        q0 = quantize_psum($signed(ch_temp_psum[0][pool_col_base]), scale_CONV2_buf);
        q1 = quantize_psum($signed(ch_temp_psum[0][pool_col_base+1]), scale_CONV2_buf);
        q2 = quantize_psum($signed(ch_temp_psum[1][pool_col_base]), scale_CONV2_buf);
        q3 = quantize_psum($signed(ch_temp_psum[1][pool_col_base+1]), scale_CONV2_buf);
        current_max = q0;
        if (q1 > current_max) current_max = q1;
        if (q2 > current_max) current_max = q2;
        if (q3 > current_max) current_max = q3;
    end : pool_max

    // Output packer. Four pooled bytes form one 32-bit word; the final item
    // in each row emits a padded tail word.
    always_ff @(posedge clk or negedge rst_n) begin : package_act
        if (!rst_n) begin
            package_cnt <= '0;
            result_reg  <= '0;
        end else if (pool_valid) begin
            result_reg[package_cnt] <= current_max;
            package_cnt <= package_cnt + 1'b1;
        end
    end : package_act

    // Activation SRAM writeback for packed CONV2 output words.
    // Pack the current pooled byte with the three previously buffered bytes.
    assign pack_data = {current_max, result_reg[2:0]};

    always_ff @(posedge clk or negedge rst_n) begin : act_sram_write
        if (!rst_n) begin
            sram_act_wea0   <= 4'd0;
            sram_act_wdata0 <= 32'd0;
            sram_act_wea1   <= 4'd0;
            sram_act_wdata1 <= 32'd0;
        end else begin
            sram_act_wea0 <= 4'd0;
            sram_act_wea1 <= 4'd0;
            if (pack_valid) begin
                sram_act_wea0   <= 4'hF;
                sram_act_wdata0 <= pack_data;
            end
        end
    end : act_sram_write

    // Completion delay. Keep done as a one-cycle pulse aligned with the
    // final packed word after the output-channel sequence is complete.
    assign conv2_done = pack_valid && (write_addr == 17'd99) && (out_ch == 4'd15);
    assign done = done_delay[1];

    always_ff @(posedge clk or negedge rst_n) begin : done_delay_ff
        if (!rst_n) done_delay <= 1'b0;
        else done_delay <= {done_delay[0], conv2_done};
    end : done_delay_ff

endmodule
