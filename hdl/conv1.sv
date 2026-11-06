// CONV1 layer engine split from lenet(20261021-103200).sv.
// Existing pipeline, read/write arbitration, packing and SRAM timing retained.
// "enable" is a LEVEL while Top is in CONV1, not an additional start pulse.
module conv1 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    output logic        done,        // delayed final CONV1 packed word; 1-cycle pulse
    input  logic [31:0] scale_CONV1,

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

    input logic signed [4:0][7:0] shared_weight[0:4],

    // OPT-04B: request shared CONV1/CONV2 combinational PE array.
    output logic pe_req,
    input logic signed [19:0] shared_pe_result[0:4]

);
    // input enable buffered to preserve SRAM timing
    logic enable_buf;

    // Inputs buffered inside layer, at the SAME edge as in former lenet.sv.
    logic [31:0] scale_CONV1_buf;
    logic [31:0] sram_weight_rdata0_buf, sram_weight_rdata1_buf;
    logic [31:0] sram_act_rdata0_buf, sram_act_rdata1_buf;

    // Activation and weight address counters.
    logic row_sel;
    logic [4:0] col;
    logic [4:0] strip_idx;
    logic [4:0] fill_cnt;
    logic [4:0] load_idx_s2, load_idx_s3, load_idx_s4;
    logic [2:0] act_row_pair_s1, act_row_pair_s4;
    logic [3:0] act_col_blk_s1, act_col_blk_s4;

    logic [5:0] w_offset;
    logic [3:0] kernel_idx;
    logic [3:0] kernel_idx_s2, kernel_idx_s3, kernel_idx_s4;
    logic [ 3:0] kernel_group;
    logic [16:0] write_addr;

    // Pooling and output packing counters.
    logic [ 2:0] pool_cnt;
    logic [ 1:0] package_cnt;
    logic [ 3:0] pool_out_col;

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
    // The validity and kernel index travel through the same four pipelines as
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
    logic init_valid;
    logic new_valid;

    // Pooling and output-packing validity.
    logic pool_valid;
    logic full_word_valid;
    logic row_tail_valid;
    logic pack_valid;

    // Output-channel transition control.
    logic change_out_ch;

    // Sliding-window data path.
    // PE inputs are selected from six buffered rows; PE results are registered
    // at Pipeline 4 before the arithmetic post-processing block.
    logic signed [19:0] pe_out_s4[0:4];
    logic signed [19:0] pe_out[0:4];

    // Quantization, pooling, and output-packing data.
    logic [7:0] max_pool;
    logic [7:0] current_max;
    logic [31:0] pack_data;
    logic signed [3:0][7:0] result_reg;
    logic signed [19:0] conv_sum;
    logic [19:0] relu_out;
    logic [7:0] quant_out;
    logic [63:0] scale_temp;
    logic [63:0] quant_shifted;

    // Completion state is owned by this layer instead of the parent Top.
    logic conv1_done;
    logic channel_last_pack;
    logic [1:0] done_delay;

    // Shared combinational control. Keep cross-block assignments together;
    // assignments used by one sequential block remain next to that block.
    assign s1_valid = enable_buf;
    assign init_valid = (strip_idx == 5'd0) && (fill_cnt < 5'd24);
    assign new_valid = (strip_idx != 5'd0) && (fill_cnt < 5'd8);
    assign load_valid_s1 = s1_valid && (init_valid || new_valid);
    assign act_read_fire = load_valid_s1 && !pack_valid;

    // Pipeline 1 address fields and delayed Pipeline 4 writeback fields.
    assign act_row_pair_s1 = fill_cnt[4:3];  // Row pairs 0/1, 2/3, and 4/5.
    assign act_col_blk_s1 = fill_cnt[2:0];  // Column block 0 through 7.
    assign act_row_pair_s4 = load_idx_s4[4:3];
    assign act_col_blk_s4 = load_idx_s4[2:0];

    // Output-channel transition and processing-valid control.
    assign channel_last_pack = pack_valid && (write_addr == (kernel_group * 16'd56 + 16'd55));
    assign change_out_ch = channel_last_pack && (kernel_group < 4'd5);
    assign pe_valid = s3_valid && line_buffer_ready && weight_ready && !channel_mac_done;
    assign flush = pe_valid && (row_sel == 1'b1) && (col == 5'd27) && (strip_idx < 5'd13);

    // Pooling and output-packing validity.
    assign pool_valid = s4_valid && (pool_cnt == 3'd3);
    assign full_word_valid = pool_valid && (package_cnt == 2'd3);
    assign row_tail_valid = pool_valid && (pool_out_col == 4'd13);
    assign pack_valid = full_word_valid || row_tail_valid;
    assign w_offset = kernel_group * 10;
    assign weight_valid_s1 = s1_valid && (kernel_idx < 4'd10);
    assign last_mac_fire = pe_valid && (strip_idx == 5'd13) && (row_sel == 1'b1) && (col == 5'd27);
    assign conv1_done = channel_last_pack && (kernel_group == 4'd5);

    // Generate-loop index for the processing elements.
    genvar i;

    assign lb_load_valid = load_valid_s4;

    // Original CONV1 strip behavior
    assign lb_init_load  = (strip_idx == 5'd0);
    assign lb_shift_rows = (strip_idx != 5'd0) && (load_idx_s4 == 5'd0);

    assign lb_row_pair   = act_row_pair_s4;
    assign lb_col_blk    = act_col_blk_s4;

    assign lb_wdata0     = sram_act_rdata0_buf;
    assign lb_wdata1     = sram_act_rdata1_buf;

    assign lb_row_sel    = row_sel;
    assign lb_col        = col;

    // CONV1 weight buffer
    assign wb_load_valid = weight_valid_s4;
    assign wb_kernel_idx = kernel_idx_s4;
    assign wb_wdata0     = sram_weight_rdata0_buf;

    // Static SRAM output assignments. CONV1 reads weights only; activation
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
            scale_CONV1_buf        <= 32'd0;
            sram_weight_rdata0_buf <= 32'd0;
            sram_weight_rdata1_buf <= 32'd0;
            sram_act_rdata0_buf    <= 32'd0;
            sram_act_rdata1_buf    <= 32'd0;
        end else begin
            enable_buf             <= enable;
            scale_CONV1_buf        <= scale_CONV1;
            sram_weight_rdata0_buf <= sram_weight_rdata0;
            sram_weight_rdata1_buf <= sram_weight_rdata1;
            sram_act_rdata0_buf    <= sram_act_rdata0;
            sram_act_rdata1_buf    <= sram_act_rdata1;
        end
    end : input_buffer

    // Pipeline 1 control: activation read address and fill counter.
    // The address block also services Pipeline 4 output writeback.
    always_ff @(posedge clk or negedge rst_n) begin : act_addr_gen
        if (!rst_n) begin
            sram_act_addr0 <= '0;
            sram_act_addr1 <= '0;
            write_addr <= 'd0;
        end else if (pack_valid) begin
            sram_act_addr0 <= conv1_out_offset + write_addr;
            write_addr <= write_addr + 1;
        end else if (act_read_fire) begin
            if (init_valid) begin
                sram_act_addr0 <= conv1_in_offset + ((act_row_pair_s1 * 2) * 8) + act_col_blk_s1;
                sram_act_addr1 <= conv1_in_offset + ((act_row_pair_s1 * 2 + 1) * 8) + act_col_blk_s1;
            end else if (new_valid) begin
                sram_act_addr0 <= conv1_in_offset + ((strip_idx * 2 + 4) * 8) + fill_cnt;
                sram_act_addr1 <= conv1_in_offset + ((strip_idx * 2 + 5) * 8) + fill_cnt;
            end
        end
    end : act_addr_gen

    always_ff @(posedge clk or negedge rst_n) begin : line_counter
        if (!rst_n) begin
            fill_cnt <= 5'd0;
        end else if (change_out_ch) begin
            fill_cnt <= 5'd0;
        end else if (flush) begin
            fill_cnt <= 5'd0;
        end else if (act_read_fire) begin
            if (strip_idx == 5'd0) begin
                if (fill_cnt != 5'd24)
                    fill_cnt <= fill_cnt + 1;
            end else begin
                if (fill_cnt != 5'd8)
                    fill_cnt <= fill_cnt + 1;
            end
        end
    end : line_counter

    // Pipeline 1 control: packed-weight address and kernel counters.
    always_ff @(posedge clk or negedge rst_n) begin : weight_addr_gen
        if (!rst_n) begin
            sram_weight_addr0 <= '0;
        end else if (s1_valid && kernel_idx < 10) begin
            sram_weight_addr0 <= w_offset + kernel_idx;
        end
    end : weight_addr_gen

    always_ff @(posedge clk or negedge rst_n) begin : kernel_counter
        if (!rst_n) begin
            kernel_idx <= 4'd0;
        end else if (s1_valid) begin
            if (change_out_ch) begin
                kernel_idx <= 4'd0;
            end else if (kernel_idx < 4'd10) begin
                kernel_idx <= kernel_idx + 1;
            end
        end
    end : kernel_counter

    always_ff @(posedge clk or negedge rst_n) begin : kernel_group_counter
        if (!rst_n) begin
            kernel_group <= 4'd0;
        end else if (s1_valid) begin
            if (change_out_ch) begin
                if (kernel_group == 4'd5) kernel_group <= 4'd0;
                else kernel_group <= kernel_group + 1'b1;
            end
        end
    end : kernel_group_counter

    // Main four-pipeline valid path.
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
    // Pipeline 2-4 carries activation valid.
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

    // Pipeline 2-2: delay the SRAM word index alongside activation valid.
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
    // Pipeline 2-3 carries weight valid.
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

    // Pipeline 2-4: delay the packed-kernel word index with weight valid.
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
        if (!rst_n) begin
            line_buffer_ready <= 1'b0;
        end else if (change_out_ch) begin
            line_buffer_ready <= 1'b0;
        end else if (flush) begin
            line_buffer_ready <= 1'b0;
        end         else if (load_valid_s4 && ((strip_idx == 5'd0 && load_idx_s4 == 5'd23) ||
         (strip_idx != 5'd0 && load_idx_s4 == 5'd7))) begin
            line_buffer_ready <= 1'b1;
        end
    end : line_buffer_status

    always_ff @(posedge clk or negedge rst_n) begin : weight_status
        if (!rst_n) weight_ready <= 1'b0;
        else if (change_out_ch) weight_ready <= 1'b0;
        else if (weight_valid_s4 && kernel_idx_s4 == 4'd9) weight_ready <= 1'b1;
    end

    // Pipeline 3 PE issue control and end-of-channel detection.
    // A PE operation is issued only after the Pipeline 2/3 control path,
    // activation line buffer, and weight registers are all ready.
    // Detect the final MAC operation of the final strip for this channel.
    always_ff @(posedge clk or negedge rst_n) begin : channel_mac_done_ff
        if (!rst_n) channel_mac_done <= 1'b0;
        else if (change_out_ch) channel_mac_done <= 1'b0;
        else if (last_mac_fire) channel_mac_done <= 1'b1;
    end

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
            strip_idx <= strip_idx + 1;
        end else if (pe_valid) begin
            if (row_sel == 1'b1) begin
                row_sel <= 1'b0;  // Both row positions are complete; move right.
                if (col == 5'd27) begin
                    col <= 5'd0;  // The right edge is complete; start the next strip.
                end else begin
                    col <= col + 1;
                end
            end else begin
                row_sel <= 1'b1;  // Process the lower row position next.
            end
        end
    end : compute_counter

    // PE arithmetic now lives in lenet.sv (one shared PE array).
    // Preserve original invalid-cycle zero at the local pe_out boundary.
    assign pe_req = pe_valid;
    generate
        for (i = 0; i < 5; i++) begin : gen_pe_result
            assign pe_out[i] = pe_valid ? shared_pe_result[i] : '0;
        end
    endgenerate



    // Pipeline 4 result register. This register isolates the PE combinational
    // result from the quantization and pooling logic.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= '0;
        end else if (pe_valid) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= pe_out[i];
        end
    end

    // Pipeline 4 arithmetic post-processing: accumulate the five PE results,
    // apply ReLU, multiply by the layer scale, shift, and saturate to 8 bits.
    always_comb begin : relu_quant
        if (s4_valid) begin
            conv_sum = $signed(pe_out_s4[0]) + $signed(pe_out_s4[1]) + $signed(pe_out_s4[2]) +
                $signed(pe_out_s4[3]) + $signed(pe_out_s4[4]);

            relu_out = (conv_sum < 0) ? '0 : $unsigned(conv_sum);

            scale_temp = relu_out * scale_CONV1_buf;
            quant_shifted = scale_temp >> 16;

            if (quant_shifted > 64'd127) quant_out = 8'd127;
            else quant_out = quant_shifted[7:0];
        end else begin
            conv_sum = '0;
            relu_out = '0;
            scale_temp = '0;
            quant_shifted = '0;
            quant_out = '0;
        end
    end

    // Compare the current quantized result with the running 2x2 pool maximum.
    always_comb begin : compare_max
        if (pool_cnt == 3'd0) current_max = quant_out;
        else current_max = (quant_out > max_pool) ? quant_out : max_pool;
    end

    // Four-result pooling accumulator. pool_cnt tracks the position inside
    // each pooling group and max_pool stores its current maximum.
    always_ff @(posedge clk or negedge rst_n) begin : max_pool_ff
        if (!rst_n) begin
            max_pool <= '0;
            pool_cnt <= '0;
        end else if (s4_valid) begin
            max_pool <= current_max;
            pool_cnt <= (pool_cnt == 3'd3) ? 3'd0 : pool_cnt + 1'b1;
        end
    end

    // Output packer. Four pooled bytes form one 32-bit word; the final item
    // in each row emits a padded tail word.
    always_ff @(posedge clk or negedge rst_n) begin : package_act
        if (!rst_n) begin
            pool_out_col <= '0;
            package_cnt  <= '0;
            result_reg   <= '0;
        end else if (pool_valid) begin
            if (pool_out_col == 4'd13) begin
                // Last item in the column: complete the padding word.
                pool_out_col <= 4'd0;
                package_cnt  <= 2'd0;
                result_reg   <= '0;
            end else begin
                pool_out_col <= pool_out_col + 1'b1;
                result_reg[package_cnt] <= current_max;
                package_cnt <= package_cnt + 1'b1;
            end
        end
    end

    // Activation SRAM writeback for packed CONV1 output words.
    // Place the current pooled bytes into the full word or padded tail format.
    assign pack_data = row_tail_valid
                 ? {16'd0, current_max, result_reg[0]}
                 : {current_max, result_reg[2:0]};

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
    end

    // Completion delay. Keep done as a one-cycle pulse aligned with the
    // final packed word after the output-channel sequence is complete.
    // The completion flag is asserted only for the last output channel.

    always_ff @(posedge clk or negedge rst_n) begin : done_delay_ff
        if (!rst_n) begin
            done <= 1'b0;
            done_delay <= 1'b0;
        end 
        else begin
            done_delay <= {done_delay[0], conv1_done};
            done <= done_delay[1];
        end
    end

endmodule
