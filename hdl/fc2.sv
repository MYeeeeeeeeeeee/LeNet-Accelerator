// Read/write arbitration and packing retained.
// "enable" is a LEVEL while Top is in FC2, not an additional start pulse.
module fc2 (
    // FC2 control and completion handshake.
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    output logic        done,      // delayed final FC2 packed word; 1-cycle pulse
    input  logic [31:0] scale_FC2,

    // Two-port weight SRAM interface.
    output logic [ 3:0] sram_weight_wea0,
    output logic [15:0] sram_weight_addr0,
    output logic [31:0] sram_weight_wdata0,
    input  logic [31:0] sram_weight_rdata0,
    output logic [ 3:0] sram_weight_wea1,
    output logic [15:0] sram_weight_addr1,
    output logic [31:0] sram_weight_wdata1,
    input  logic [31:0] sram_weight_rdata1,

    // Two-port activation SRAM interface.
    output logic [ 3:0] sram_act_wea0,
    output logic [15:0] sram_act_addr0,
    output logic [31:0] sram_act_wdata0,
    input  logic [31:0] sram_act_rdata0,
    output logic [ 3:0] sram_act_wea1,
    output logic [15:0] sram_act_addr1,
    output logic [31:0] sram_act_wdata1,
    input  logic [31:0] sram_act_rdata1,

    // FC activation-vector buffer interface.
    output logic        fc_buf_re,
    output logic [ 6:0] fc_buf_raddr,
    input  logic [63:0] fc_buf_rdata

);

    localparam shortint fc2_weight_offset   = 16'd15540;
    localparam shortint fc2_out_offset   = 16'd743;
    localparam shortint fc2_bias_offset   = 16'd15750;

    // input enable buffered to preserve SRAM timing
    logic enable_buf;

    // Registered external weight inputs.
    logic [31:0] sram_weight_rdata0_buf, sram_weight_rdata1_buf;

    // Valid pipeline: request, activation return, and weight return timing.
    logic s1_valid, s2_valid, s3_valid, s4_valid;
    logic load_valid_s1, load_valid_s2, load_valid_s3, load_valid_s4;
    logic weight_valid_s1, weight_valid_s2, weight_valid_s3, weight_valid_s4;
    logic pe_valid;
    logic vector_read_fire;

    // Output-neuron, activation-vector, and MAC-group control state.
    logic change_out_ch;
    logic [7:0] out_ch;
    logic [4:0] act_idx;
    logic [5:0] weight_idx;
    logic [5:0] group_idx_s2, group_idx_s3, group_idx_s4;
    logic [5:0] group_idx_buf;
    logic vector_buf_valid;
    logic [5:0] group_idx_mac_s4;
    logic neuron_valid;

    // Address calculations and output write position.
    logic [15:0] global_w_offset;
    logic [16:0] write_addr;
    logic [15:0] w_0_idex, w_1_idex;
    logic [16:0] buffer_act_addr;

    // PE input vectors and registered PE results.
    logic signed [19:0] pe_out_s4[0:4];
    logic signed [4:0][7:0] weight_reg[0:4];
    logic signed [19:0] pe_out[0:4];
    logic [63:0] fc_act_d1, fc_act_d2, fc_act_vec_buf;

    // PSUM accumulation, quantization, and four-neuron packing.
    logic signed [19:0] conv_sum;
    logic signed [31:0] conv_sum_ext;
    logic signed [31:0] scalar_psum;
    logic signed [31:0] psum_next;

    // Completion state.
    logic fc2_done;
    logic [1:0] done_delay;

    logic mac_done;

    logic signed [9:0][31:0] ch_temp_psum[0:1];

    logic [2:0] bias_idx;
    logic bias_load_valid;
    logic bias_valid_s2, bias_valid_s3, bias_valid_s4;
    logic [2:0] bias_idx_s2, bias_idx_s3, bias_idx_s4;
    logic [15:0] b_0_idex, b_1_idex;

    logic       result_ready;
    logic       result_write_fire;
    

    // Global valid and transaction-control assignments.
    assign s1_valid = enable_buf;
    assign load_valid_s1 = s1_valid && (act_idx < 5'd11) && (out_ch < 'd10);
    assign bias_load_valid = enable_buf && mac_done  && (bias_idx < 5'd5);

    // Global pipeline-valid assignments.
    assign vector_read_fire = load_valid_s1 ;
    assign weight_valid_s1 = vector_read_fire;
    assign change_out_ch = neuron_valid && (out_ch < 'd10);
    assign pe_valid = s3_valid && vector_buf_valid;

    // Global output-write arbitration assignment.
    assign result_write_fire = enable_buf && result_ready &&  (write_addr < 17'd10);

    // Pipeline 1: arbitrate activation-vector reads and packed-output writes.
    // A packed output write takes priority over issuing a new vector read.
    // This address calculation is local to the activation address generator.
    assign buffer_act_addr = act_idx * 8;
    always_ff @(posedge clk or negedge rst_n) begin : act_addr_gen
        if (!rst_n) begin
            sram_act_addr0 <= '0;
            fc_buf_raddr <= '0;
            write_addr <= '0;
        end else if (result_write_fire) begin
            sram_act_addr0 <= fc2_out_offset + write_addr;
            write_addr <= write_addr + 1;
        end else if (vector_read_fire) begin
            fc_buf_raddr <= buffer_act_addr;
        end else begin
            sram_act_addr0 <= sram_act_addr0;
        end
    end : act_addr_gen

    // Pipeline 1: generate the activation-buffer read enable.
    always_ff @(posedge clk or negedge rst_n) begin : fc_read_en_ff
        if (!rst_n) fc_buf_re <= 1'b0;
        else if (vector_read_fire) fc_buf_re <= 1'b1;
        else fc_buf_re <= 1'b0;
    end : fc_read_en_ff

    

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mac_done <= 1'b0;
        else if (!enable)
            mac_done <= 1'b0;
        else if (neuron_valid && out_ch == 8'd9)
            mac_done <= 1'b1;
    end

    // Pipeline 1: advance or restart the activation-vector index.
    always_ff @(posedge clk or negedge rst_n) begin : act_read_idx_ff
        if (!rst_n) begin
            act_idx <= 17'd0;
        end else if (change_out_ch) begin
            act_idx <= 17'd0;
        end else if (vector_read_fire) begin
            act_idx <= act_idx + 1'b1;
        end else begin
            act_idx <= act_idx;
        end
    end : act_read_idx_ff


    // Pipeline 1: decode and issue weight addresses for the current vector.
    // Each request fetches two adjacent weight words for the two PEs.
    // These address calculations are local to the weight address generator.
    assign global_w_offset = out_ch * 16'd21 + fc2_weight_offset;
    assign w_0_idex = {weight_idx, 1'b0};
    assign w_1_idex = {weight_idx, 1'b1};
    assign b_0_idex = {bias_idx, 1'b0};
    assign b_1_idex = {bias_idx, 1'b1};

    always_ff @(posedge clk or negedge rst_n) begin : weight_addr_gen
        if (!rst_n) begin
            sram_weight_addr0 <= '0;
            sram_weight_addr1 <= '0;
        end else if (vector_read_fire) begin
            sram_weight_addr0 <= global_w_offset + w_0_idex;
            sram_weight_addr1 <= global_w_offset + w_1_idex;
        end
        else if(bias_load_valid)begin
            sram_weight_addr0 <= fc2_bias_offset + b_0_idex;
            sram_weight_addr1 <= fc2_bias_offset + b_1_idex;
        end else begin
            sram_weight_addr0 <= sram_weight_addr0;
            sram_weight_addr1 <= sram_weight_addr1;
        end
    end : weight_addr_gen

    // Pipeline 1: advance or restart the weight-vector index.
    always_ff @(posedge clk or negedge rst_n) begin : weight_read_idx_ff
        if (!rst_n) begin
            weight_idx <= '0;
        end else if (change_out_ch) begin
            weight_idx <= '0;
        end else if (vector_read_fire) begin
            weight_idx <= weight_idx + 1;
        end else begin
            weight_idx <= weight_idx;
        end
    end

    // Pipeline 1: advance the bias-vector index for the next bias read.
    always_ff @(posedge clk or negedge rst_n) begin : bias_read_idx_ff
        if(!rst_n) begin
            bias_idx <= '0;
        end else if (bias_load_valid) begin
            bias_idx <= bias_idx + 1;
        end else begin
            bias_idx <= bias_idx;
        end
    end: bias_read_idx_ff

    // Hold unused write-side ports at reset values. These ports remain in the
    // module interface because they are connected by the surrounding design.
    always_ff @(posedge clk or negedge rst_n) begin : unused_sram_ff
        if (!rst_n) begin
            sram_act_addr1 <= 16'd0;
            sram_weight_wdata0 <= 32'd0;
            sram_weight_wdata1 <= 32'd0;
            sram_weight_wea0 <= 4'd0;
            sram_weight_wea1 <= 4'd0;

        end else begin
            sram_act_addr1 <= sram_act_addr1;
            sram_weight_wdata0 <= sram_weight_wdata0;
            sram_weight_wdata1 <= sram_weight_wdata1;
            sram_weight_wea0 <= sram_weight_wea0;
            sram_weight_wea1 <= sram_weight_wea1;
        end
    end : unused_sram_ff


    // Buffer SRAM inputs and scale. The activation read inputs are retained
    // to preserve the SRAM interface; activation vectors use fc_buf_rdata.
    always_ff @(posedge clk or negedge rst_n) begin : input_buffer
        if (!rst_n) begin
            enable_buf             <= 1'b0;
            sram_weight_rdata0_buf <= 32'd0;
            sram_weight_rdata1_buf <= 32'd0;

        end else begin
            enable_buf             <= enable;
            sram_weight_rdata0_buf <= sram_weight_rdata0;
            sram_weight_rdata1_buf <= sram_weight_rdata1;
        end
    end : input_buffer

    // Pipeline 1-4: delay the request valid until PE/PSUM processing.
    // s4_valid is asserted from the PE input-valid condition.
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

    // Pipeline 1-4: align activation-buffer read timing with returned data.
    always_ff @(posedge clk or negedge rst_n) begin : load_valid_pipeline
        if (!rst_n) begin
            load_valid_s2 <= 1'b0;
            load_valid_s3 <= 1'b0;
            load_valid_s4 <= 1'b0;
        end else begin
            load_valid_s2 <= vector_read_fire;
            load_valid_s3 <= load_valid_s2;
            load_valid_s4 <= load_valid_s3;
        end
    end : load_valid_pipeline

    // Pipeline 1-4: align weight read timing with returned weight data.
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



    // Pipeline 1-4: align bias read timing with returned bias data.
    always_ff @(posedge clk or negedge rst_n) begin : bias_valid_pipeline
        if (!rst_n) begin
            bias_valid_s2 <= 1'b0;
            bias_valid_s3 <= 1'b0;
            bias_valid_s4 <= 1'b0;
        end else begin
            bias_valid_s2 <= bias_load_valid;
            bias_valid_s3 <= bias_valid_s2;
            bias_valid_s4 <= bias_valid_s3;
        end
    end : bias_valid_pipeline

    // Pipeline 1-4: align the bias index with returned bias data.
    always_ff @(posedge clk or negedge rst_n) begin : bias_idx_pipeline
        if (!rst_n) begin
            bias_idx_s2 <= '0;
            bias_idx_s3 <= '0;
            bias_idx_s4 <= '0;
        end else begin
            bias_idx_s2 <= bias_idx;
            bias_idx_s3 <= bias_idx_s2;
            bias_idx_s4 <= bias_idx_s3;
        end
    end: bias_idx_pipeline

    // Pipeline 2-4: carry the vector-group index through read latency.
    // group_idx_buf holds the index associated with the returned vector.
    always_ff @(posedge clk or negedge rst_n) begin : group_idx_pipeline
        if (!rst_n) begin
            group_idx_s2  <= '0;
            group_idx_s3  <= '0;
            group_idx_s4  <= '0;
            group_idx_buf <= '0;
        end else begin
            group_idx_s2 <= act_idx;
            group_idx_s3 <= group_idx_s2;
            group_idx_s4 <= group_idx_s3;

            if (load_valid_s4)
                group_idx_buf <= group_idx_s4;
            else group_idx_buf <= group_idx_buf;
        end
    end : group_idx_pipeline

    // Pipeline 2-3: delay the activation vector to match the PE input stage.
    // The two delay registers model the FC activation-buffer read latency.
    always_ff @(posedge clk or negedge rst_n) begin : fc_act_vec_ff
        if (!rst_n) begin
            fc_act_d1      <= '0;
            fc_act_d2      <= '0;
            fc_act_vec_buf <= '0;
        end else begin
            fc_act_d1 <= fc_buf_rdata;
            fc_act_d2 <= fc_act_d1;

            if (load_valid_s4) begin
                if (group_idx_s4 == 6'd10)
                    fc_act_vec_buf <= {32'd0, fc_act_d2[31:0]};
                else
                fc_act_vec_buf <= fc_act_d2;
            end
            else fc_act_vec_buf <= fc_act_vec_buf;
        end
    end : fc_act_vec_ff

    // Pipeline 3-4: mark the delayed activation vector as available to the PEs.
    always_ff @(posedge clk or negedge rst_n) begin : vector_buf_valid_ff
        if (!rst_n) vector_buf_valid <= 1'b0;
        else vector_buf_valid <= load_valid_s4;
    end : vector_buf_valid_ff

    // Pipeline 3-4: register returned weight words before PE consumption.
    always_ff @(posedge clk or negedge rst_n) begin : weight_reg_ff
        if (!rst_n) begin
            foreach (weight_reg[i]) weight_reg[i] <= '0;
        end else if (weight_valid_s4) begin
            weight_reg[0][3:0] <= sram_weight_rdata0_buf;
            if (group_idx_s4 == 6'd10) weight_reg[1][3:0] <= 'd0;
            else weight_reg[1][3:0] <= sram_weight_rdata1_buf;
        end
    end : weight_reg_ff

    // Pipeline 3: multiply one buffered activation vector with two weights.
    genvar i;
    generate
        for (i = 0; i < 2; i++) begin : gen_pe
            PE #(
                .INPUT_WIDTH (8),
                .OUTPUT_WIDTH(20)
            ) pe_inst (
                .weight({8'd0, weight_reg[i][3:0]}),
                .activation({8'd0, fc_act_vec_buf[i*32+:32]}),
                .valid(pe_valid),
                .mode(FC),
                .result(pe_out[i])
            );
        end : gen_pe
    endgenerate

    // Pipeline 4: register PE results before summing and PSUM update.
    // Only valid PE results replace the previous registered values.
    always_ff @(posedge clk or negedge rst_n) begin : pe_out_ff
        if (!rst_n) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= '0;
        end else if (pe_valid) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= pe_out[i];
        end else begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= pe_out_s4[i];
        end
    end : pe_out_ff

    // Pipeline 4: align the group index with the registered PE result.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) group_idx_mac_s4 <= '0;
        else if (pe_valid) group_idx_mac_s4 <= group_idx_buf;
    end

    // Pipeline 4: sum PE results and select or accumulate the PSUM value.
    // Local PSUM arithmetic assignments.
    assign conv_sum = $signed(pe_out_s4[0]) + $signed(pe_out_s4[1]);
    assign conv_sum_ext = {{12{conv_sum[19]}}, conv_sum};
    assign psum_next = (group_idx_mac_s4 == 6'd0) ? conv_sum_ext : scalar_psum + conv_sum_ext;

    // Pipeline 4: update PSUM and emit one quantized neuron per completed vector.
    // Group 10 is the final vector group for one output neuron.
    always_ff @(posedge clk or negedge rst_n) begin : psum_update
        if (!rst_n) begin
            scalar_psum  <= '0;
            neuron_valid <= 1'b0;

            foreach (ch_temp_psum[i])
                ch_temp_psum[i] <= '0;
        end
        else begin
            neuron_valid <= 1'b0;

            // 第一階段：Weight MAC
            if (s4_valid) begin
                scalar_psum <= psum_next;

                if (group_idx_mac_s4 == 6'd10) begin
                    ch_temp_psum[0][out_ch] <= psum_next;
                    neuron_valid <= 1'b1;
                end
                else begin
                    ch_temp_psum[0] <= ch_temp_psum[0];
                end
            end

            // 第二階段：Bias + PSUM
            else if (bias_valid_s4) begin
                ch_temp_psum[1][{bias_idx_s4, 1'b0}]
                    <= ch_temp_psum[0][{bias_idx_s4, 1'b0}]
                    + $signed(sram_weight_rdata0_buf);

                ch_temp_psum[1][{bias_idx_s4, 1'b1}]
                    <= ch_temp_psum[0][{bias_idx_s4, 1'b1}]
                    + $signed(sram_weight_rdata1_buf);
            end
            else begin
                ch_temp_psum[1] <= ch_temp_psum[1];
            end
        end
    end : psum_update

    // Pipeline 4 control: advance to the next output neuron after completion.
    always_ff @(posedge clk or negedge rst_n) begin : ch_counter
        if (!rst_n) begin
            out_ch <= 8'd0;
        end else if (change_out_ch) begin
            out_ch <= out_ch + 1'b1;
        end else begin
            out_ch <= out_ch;
        end
    end : ch_counter

    // Output packing: collect four quantized neurons into one SRAM word.
    always_ff @(posedge clk or negedge rst_n) begin : result_ready_ff
    if (!rst_n)
        result_ready <= 1'b0;
    else if (!enable_buf)
        result_ready <= 1'b0;
    else if (bias_valid_s4 && bias_idx_s4 == 3'd4)
        result_ready <= 1'b1;
    end : result_ready_ff

    // Output packing: write the completed packed word to activation SRAM.

    always_ff @(posedge clk or negedge rst_n) begin : act_sram_write
        if (!rst_n) begin
            sram_act_wea0   <= 4'd0;
            sram_act_wdata0 <= 32'd0;
            sram_act_wea1   <= 4'd0;
            sram_act_wdata1 <= 32'd0;
        end else begin
            sram_act_wea0 <= 4'd0;
            sram_act_wea1 <= 4'd0;
            if (result_write_fire) begin
                sram_act_wea0   <= 4'hF;
                sram_act_wdata0 <=  ch_temp_psum[1][write_addr];
            end
        end
    end : act_sram_write

    // Completion: detect the final packed word and delay the top-level pulse.
    // write_addr and out_ch identify the last FC2 output word.
    // These assignments are local to completion signaling.
    assign fc2_done = enable_buf && (write_addr == 17'd10) && (sram_act_wea0 == 4'hF);
    assign done = done_delay[1];

    always_ff @(posedge clk or negedge rst_n) begin : done_delay_ff
        if (!rst_n) done_delay <= 1'b0;
        else done_delay <= {done_delay[0], fc2_done};
    end : done_delay_ff

endmodule
