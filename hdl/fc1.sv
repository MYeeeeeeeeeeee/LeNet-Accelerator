// Read/write arbitration and packing retained.
// "enable" is a LEVEL while Top is in FC1, not an additional start pulse.
module fc1#(
    parameter PE_OUTPUT_WIDTH = 18
) (
    // FC1 control and completion handshake.
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    output logic        done,      // delayed final FC1 packed word; 1-cycle pulse
    input  logic [31:0] scale_FC1,

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
    input  logic [63:0] fc_buf_rdata,
    input  logic [14:0] fc1_group_nonzero,

    output logic       fc_buf_we,
    output logic [6:0] fc_buf_waddr,
    output logic [7:0] fc_buf_wdata,

    // Shared weight-buffer write request (same cycle as the old weight_reg FF).
    output logic                    wb_load_valid,
    output logic        [31:0]      wb_wdata0,
    output logic        [31:0]      wb_wdata1,
    input  logic signed [ 4:0][7:0] shared_weight[0:4],

    // PE interface for FC1 activation-vector and result return.
    output logic [63:0] pe_act_vec,
    output logic pe_req,
    input logic signed [PE_OUTPUT_WIDTH-1:0] shared_pe_result[0:4],

    output logic signed [31:0] quant_psum,
    output logic        [31:0] quant_scale,
    input  logic        [ 7:0] shared_quant_result
);
    // input enable buffered to preserve SRAM timing
    logic enable_buf;

    // Registered external inputs. The activation SRAM read data is retained
    // for interface compatibility; the active vector path uses fc_buf_rdata.
    logic [31:0] scale_FC1_buf;
    logic [31:0] sram_weight_rdata0_buf, sram_weight_rdata1_buf;
    logic [31:0] sram_act_rdata0_buf, sram_act_rdata1_buf;

    // Valid pipeline: request, activation return, and weight return timing.
    logic s1_valid, s2_valid, s3_valid, s4_valid;
    logic load_valid_s1, load_valid_s2, load_valid_s3, load_valid_s4;
    logic weight_valid_s1, weight_valid_s2, weight_valid_s3, weight_valid_s4;
    logic        pe_valid;
    logic        vector_read_fire;
    logic        pack_valid;

    // Output-neuron, activation-vector, and MAC-group control state.
    logic        change_out_ch;
    logic [ 7:0] out_ch;
    logic [ 4:0] act_idx;

    logic [14:0] issue_mask;
    logic [ 4:0] issue_group;
    logic        issue_found;

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
    logic signed [19:0] pe_out[0:4];
    logic [63:0] fc_act_d1, fc_act_d2, fc_act_vec_buf;

    // PSUM accumulation, quantization, and four-neuron packing.
    logic signed [19:0] conv_sum;
    logic signed [31:0] conv_sum_ext;
    logic signed [31:0] scalar_psum;
    logic signed [31:0] psum_next;
    logic [7:0] neuron_data;
    logic [1:0] package_cnt;
    logic signed [3:0][7:0] result_reg;
    logic [31:0] pack_data;

    // Completion state.
    logic fc1_done;
    logic [1:0] done_delay;

    // Common pipeline control assignments.
    assign s1_valid         = enable_buf;
    assign load_valid_s1    = s1_valid && issue_found && (out_ch < 8'd84);
    assign vector_read_fire = load_valid_s1 && !pack_valid;
    assign weight_valid_s1  = vector_read_fire;
    assign wb_load_valid    = weight_valid_s4;
    assign wb_wdata0        = sram_weight_rdata0_buf;
    assign wb_wdata1        = sram_weight_rdata1_buf;
    assign change_out_ch    = neuron_valid && (out_ch < 'd83);
    assign pe_valid         = s3_valid && vector_buf_valid;
    assign pack_valid       = neuron_valid && (package_cnt == 2'd3);

    // shared PE interface 
    assign pe_act_vec       = fc_act_vec_buf;
    assign pe_req           = pe_valid;

    // Pipeline 1: arbitrate activation-vector reads and packed-output writes.
    // A packed output write takes priority over issuing a new vector read.
    assign buffer_act_addr  = {issue_group, 3'b000};
    always_ff @(posedge clk or negedge rst_n) begin : act_addr_gen
        if (!rst_n) begin
            sram_act_addr0 <= '0;
            fc_buf_raddr <= '0;
            write_addr <= '0;
        end else if (pack_valid) begin
            sram_act_addr0 <= fc1_out_offset + write_addr;
            write_addr <= write_addr + 1;
        end else if (vector_read_fire) begin
            fc_buf_raddr <= buffer_act_addr;
        end
    end : act_addr_gen

    // Pipeline 1: generate the activation-buffer read enable.
    always_ff @(posedge clk or negedge rst_n) begin : fc_read_en_ff
        if (!rst_n) fc_buf_re <= 1'b0;
        else if (vector_read_fire) fc_buf_re <= 1'b1;
        else fc_buf_re <= 1'b0;
    end : fc_read_en_ff

    // Pipeline 1: advance or restart the activation-vector index.
    always_ff @(posedge clk or negedge rst_n) begin : act_read_idx_ff
        if (!rst_n) begin
            act_idx <= 17'd0;
        end else if (change_out_ch) begin
            act_idx <= 17'd0;
        end else if (vector_read_fire) begin
            act_idx <= issue_group + 5'd1;
        end
    end : act_read_idx_ff


    // Pipeline 1: decode and issue weight addresses for the current vector.
    // Each request fetches two adjacent weight words for the two PEs.
    assign global_w_offset = out_ch * 16'd30 + fc1_weight_offset;
    assign w_0_idex = {issue_group, 1'b0};
    assign w_1_idex = {issue_group, 1'b1};
    always_ff @(posedge clk or negedge rst_n) begin : weight_addr_gen
        if (!rst_n) begin
            sram_weight_addr0 <= '0;
            sram_weight_addr1 <= '0;
        end else if (vector_read_fire) begin
            sram_weight_addr0 <= global_w_offset + w_0_idex;
            sram_weight_addr1 <= global_w_offset + w_1_idex;
        end
    end : weight_addr_gen


    // Hold unused write-side ports at reset values. These ports remain in the
    // module interface because they are connected by the surrounding design.
    always_ff @(posedge clk or negedge rst_n) begin : unused_sram_ff
        if (!rst_n) begin
            sram_act_addr1 <= 16'd0;
            sram_weight_wdata0 <= 32'd0;
            sram_weight_wdata1 <= 32'd0;
            sram_weight_wea0 <= 4'd0;
            sram_weight_wea1 <= 4'd0;

            fc_buf_we <= 1'b0;
            fc_buf_waddr <= 7'd0;
            fc_buf_wdata <= 8'd0;

        end
    end : unused_sram_ff


    // Buffer SRAM inputs and scale. The activation read inputs are retained
    // to preserve the SRAM interface; activation vectors use fc_buf_rdata.
    always_ff @(posedge clk or negedge rst_n) begin : input_buffer
        if (!rst_n) begin
            enable_buf             <= 1'b0;
            scale_FC1_buf          <= 32'd0;
            sram_weight_rdata0_buf <= 32'd0;
            sram_weight_rdata1_buf <= 32'd0;
            sram_act_rdata0_buf    <= 32'd0;
            sram_act_rdata1_buf    <= 32'd0;

        end else begin
            enable_buf             <= enable;
            scale_FC1_buf          <= scale_FC1;
            sram_weight_rdata0_buf <= sram_weight_rdata0;
            sram_weight_rdata1_buf <= sram_weight_rdata1;
            sram_act_rdata0_buf    <= sram_act_rdata0;
            sram_act_rdata1_buf    <= sram_act_rdata1;
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

    // Pipeline 2-4: carry the vector-group index through read latency.
    // group_idx_buf holds the index associated with the returned vector.
    always_ff @(posedge clk or negedge rst_n) begin : group_idx_pipeline
        if (!rst_n) begin
            group_idx_s2  <= '0;
            group_idx_s3  <= '0;
            group_idx_s4  <= '0;
            group_idx_buf <= '0;
        end else begin
            group_idx_s2 <= issue_group;
            group_idx_s3 <= group_idx_s2;
            group_idx_s4 <= group_idx_s3;

            if (load_valid_s4) group_idx_buf <= group_idx_s4;
        end
    end : group_idx_pipeline


    // Force group 0 and 14 to execute.
    // This preserves the existing first/last-group logic.
    assign issue_mask = fc1_group_nonzero | 15'h4001;

    always_comb begin : next_nonzero_group
        issue_group = 5'd0;
        issue_found = 1'b0;

        for (int g = 0; g < 15; g++) begin
            if (!issue_found && (g[4:0] >= act_idx) && issue_mask[g]) begin

                issue_group = g[4:0];
                issue_found = 1'b1;
            end
        end
    end


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

            if (load_valid_s4) fc_act_vec_buf <= fc_act_d2;
        end
    end : fc_act_vec_ff

    // Pipeline 3-4: mark the delayed activation vector as available to the PEs.
    always_ff @(posedge clk or negedge rst_n) begin : vector_buf_valid_ff
        if (!rst_n) vector_buf_valid <= 1'b0;
        else vector_buf_valid <= load_valid_s4;
    end : vector_buf_valid_ff

    // Weight words are registered by the one shared_weight_buffer in lenet.sv.
    // No local weight_reg FF here, so this remains a single physical register bank.

    // Pipeline 4: register PE results before summing and PSUM update.
    // Only valid PE results replace the previous registered values.
    always_ff @(posedge clk or negedge rst_n) begin : pe_out_ff
        if (!rst_n) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= '0;
        end else if (pe_valid) begin
            for (int i = 0; i < 2; i++) begin
                pe_out_s4[i] <= shared_pe_result[i];
            end
        end
    end : pe_out_ff

    // Pipeline 4: align the group index with the registered PE result.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) group_idx_mac_s4 <= '0;
        else if (pe_valid) group_idx_mac_s4 <= group_idx_buf;
    end

    // Pipeline 4: sum PE results and select or accumulate the PSUM value.
    assign conv_sum = $signed(pe_out_s4[0]) + $signed(pe_out_s4[1]);
    assign conv_sum_ext = {{12{conv_sum[19]}}, conv_sum};
    assign psum_next = (group_idx_mac_s4 == 6'd0) ? conv_sum_ext : scalar_psum + conv_sum_ext;
    assign quant_psum = psum_next;
    assign quant_scale = scale_FC1_buf;

    // Pipeline 4: update PSUM and emit one quantized neuron per completed vector.
    // Group 14 is the final vector group for one output neuron.
    always_ff @(posedge clk or negedge rst_n) begin : psum_update
        if (!rst_n) begin
            scalar_psum  <= '0;
            neuron_valid <= 1'b0;
            neuron_data  <= '0;
        end else begin
            neuron_valid <= 1'b0;

            if (s4_valid) begin
                scalar_psum <= psum_next;

                if (group_idx_mac_s4 == 6'd14) begin
                    neuron_data  <= shared_quant_result;
                    neuron_valid <= 1'b1;
                end else begin
                    neuron_data  <= '0;
                    neuron_valid <= 1'b0;
                end
            end else begin
                neuron_data  <= '0;
                neuron_valid <= 1'b0;
            end
        end
    end : psum_update

    // Pipeline 4 control: advance to the next output neuron after completion.
    always_ff @(posedge clk or negedge rst_n) begin : ch_counter
        if (!rst_n) begin
            out_ch <= 8'd0;
        end else if (change_out_ch) begin
            out_ch <= out_ch + 1'b1;
        end
    end : ch_counter

    // Quantization: apply ReLU, scale, and saturation to the accumulated PSUM.
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

    // Output packing: collect four quantized neurons into one SRAM word.
    // package_cnt selects the byte receiving the current neuron.
    always_ff @(posedge clk or negedge rst_n) begin : package_act
        if (!rst_n) begin
            package_cnt <= '0;
            result_reg  <= '0;
        end else if (neuron_valid) begin
            result_reg[package_cnt] <= neuron_data;
            package_cnt <= package_cnt + 1'b1;
        end
    end : package_act

    // Output packing: place the current neuron in the most-significant byte
    // and the preceding three neurons in the remaining bytes.
    assign pack_data = {neuron_data, result_reg[2:0]};

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

    // Completion: detect the final packed word and delay the top-level pulse.
    // write_addr and out_ch identify the last FC1 output word.
    assign fc1_done = pack_valid && (write_addr == 17'd20) && (out_ch == 8'd83);
    always_ff @(posedge clk or negedge rst_n) begin : done_delay_ff
        if (!rst_n) begin
            done <= 1'b0;
            done_delay <= 1'b0;
        end else begin
            done_delay <= {done_delay[0], fc1_done};
            done <= done_delay[1];
        end
    end : done_delay_ff

endmodule
