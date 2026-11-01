// Read/write arbitration and packing retained.
// "enable" is a LEVEL while Top is in CONV3, not an additional start pulse.
module conv3 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    output logic        done,        // delayed final CONV3 packed word; 1-cycle pulse
    input  logic [31:0] scale_CONV3,

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

    output logic       fc_buf_we,
    output logic [6:0] fc_buf_waddr,
    output logic [7:0] fc_buf_wdata
);
    // input enable buffered to preserve SRAM timing
    logic enable_buf;


    // Buffered inputs and scale.
    logic [31:0] scale_CONV3_buf;
    logic [31:0] sram_weight_rdata0_buf, sram_weight_rdata1_buf;
    logic [31:0] sram_act_rdata0_buf, sram_act_rdata1_buf;

    // Read counters, weight offset, and output address.
    logic [ 4:0] fill_cnt;
    logic [15:0] global_w_offset;
    logic [16:0] write_addr;

    // Bytes in the current output word.
    logic [ 1:0] package_cnt;

    // Processing valid pipeline.
    logic s1_valid, s2_valid, s3_valid, s4_valid;

    // Activation-read valid pipeline.
    logic load_valid_s1, load_valid_s2, load_valid_s3, load_valid_s4;

    // Weight-read valid pipeline.
    logic weight_valid_s1, weight_valid_s2, weight_valid_s3, weight_valid_s4;

    // PE validity.
    logic pe_valid;

    // Activation read handshake.
    logic vector_read_fire;

    // Output-word valid.
    logic pack_valid;

    // Output-neuron transition.
    logic change_out_ch;

    // FC vector data path.
    logic signed [18:0] pe_out_s4[0:4];
    logic [31:0][7:0] line_buffer[0:5];
    logic signed [4:0][7:0] weight_reg[0:4];
    logic signed [18:0] pe_out[0:4];

    // PSUM and output data.
    logic [31:0] pack_data;
    logic signed [3:0][7:0] result_reg;
    logic signed [19:0] conv_sum;
    logic signed [31:0] conv_sum_ext;

    // Completion state.
    logic conv3_done;
    logic [1:0] done_delay;

    // Output-neuron and activation indices.
    logic [6:0] out_ch;
    logic [6:0] act_idx;

    // Vector-group index pipeline.
    logic [5:0] group_idx_s2;
    logic [5:0] group_idx_s3;
    logic [5:0] group_idx_s4;
    logic [5:0] group_idx_buf;
    logic vector_buf_valid;

    // Weight index and neuron valid.
    logic [5:0] weight_idx;
    logic neuron_valid;

    // Address offsets.
    logic [16:0] act_0_idex, act_1_idex;
    logic [15:0] w_0_idex, w_1_idex;

    // PSUM state.
    logic [5:0] group_idx_mac_s4;
    logic signed [31:0] scalar_psum;
    logic signed [31:0] psum_next;
    logic [7:0] neuron_data;

    // Pipeline 1: qualify the vector request and issue SRAM reads.
    assign s1_valid = enable_buf;
    assign load_valid_s1 = s1_valid && (act_idx < 6'd50) && (out_ch < 'd120);
    assign vector_read_fire = load_valid_s1 && !pack_valid;

    // Pipeline 1: activation and weight reads share the same request valid.
    assign weight_valid_s1 = vector_read_fire;

    // Advance after each neuron.
    assign change_out_ch = neuron_valid && (out_ch < 'd119);

    // Pipeline 3/4 boundary: start PE processing after data buffering.
    assign pe_valid = s3_valid && vector_buf_valid;

    // Four neurons form one output word.
    assign pack_valid = neuron_valid && (package_cnt == 2'd3);

    // Pipeline 1: decode and issue activation addresses.
    assign act_0_idex = {act_idx, 1'b0};
    assign act_1_idex = {act_idx, 1'b1};

    always_ff @(posedge clk or negedge rst_n) begin : act_addr_gen
        if (!rst_n) begin
            sram_act_addr0 <= '0;
            sram_act_addr1 <= '0;
            write_addr <= '0;
        end else if (pack_valid) begin
            sram_act_addr0 <= conv3_out_offset + write_addr;
            write_addr <= write_addr + 1;
        end else if (vector_read_fire) begin
            sram_act_addr0 <= conv3_in_offset + act_0_idex;
            sram_act_addr1 <= conv3_in_offset + act_1_idex;
        end else begin
            sram_act_addr0 <= sram_act_addr0;
            sram_act_addr1 <= sram_act_addr1;
        end
    end : act_addr_gen

    // Pipeline 1 control: advance or restart the activation read index.
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

    // Pipeline 1: decode and issue weight addresses.
    assign global_w_offset = out_ch * 16'd100 + conv3_weight_offset;
    assign w_0_idex = {weight_idx, 1'b0};
    assign w_1_idex = {weight_idx, 1'b1};

    always_ff @(posedge clk or negedge rst_n) begin : weight_addr_gen
        if (!rst_n) begin
            sram_weight_addr0 <= '0;
            sram_weight_addr1 <= '0;
        end else if (vector_read_fire) begin
            sram_weight_addr0 <= global_w_offset + w_0_idex;
            sram_weight_addr1 <= global_w_offset + w_1_idex;
        end else begin
            sram_weight_addr0 <= sram_weight_addr0;
            sram_weight_addr1 <= sram_weight_addr1;
        end
    end : weight_addr_gen

    // Pipeline 1 control: advance or restart the weight read index.
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

    // Generate-loop index for the processing elements.
    genvar i;

    // Weight SRAM writes are unused.
    always_ff @(posedge clk or negedge rst_n) begin : unused_sram_ff
        if (!rst_n) begin
            sram_weight_wdata0 <= 32'd0;
            sram_weight_wdata1 <= 32'd0;
            sram_weight_wea0   <= 4'd0;
            sram_weight_wea1   <= 4'd0;
        end else begin
            sram_weight_wdata0 <= sram_weight_wdata0;
            sram_weight_wdata1 <= sram_weight_wdata1;
            sram_weight_wea0   <= sram_weight_wea0;
            sram_weight_wea1   <= sram_weight_wea1;
        end
    end : unused_sram_ff

    // Buffer SRAM inputs and scale.
    always_ff @(posedge clk or negedge rst_n) begin : input_buffer
        if (!rst_n) begin
            enable_buf             <= 1'b0;
            scale_CONV3_buf        <= 32'd0;
            sram_weight_rdata0_buf <= 32'd0;
            sram_weight_rdata1_buf <= 32'd0;
            sram_act_rdata0_buf    <= 32'd0;
            sram_act_rdata1_buf    <= 32'd0;
        end else begin
            enable_buf             <= enable;
            scale_CONV3_buf        <= scale_CONV3;
            sram_weight_rdata0_buf <= sram_weight_rdata0;
            sram_weight_rdata1_buf <= sram_weight_rdata1;
            sram_act_rdata0_buf    <= sram_act_rdata0;
            sram_act_rdata1_buf    <= sram_act_rdata1;
        end
    end : input_buffer

    // Main pipeline valid: Pipeline 1 request -> Pipeline 2 read/align
    // -> Pipeline 3 PE input -> Pipeline 4 PE/PSUM processing.
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

    // Pipeline 2 local paths delay data and valid signals together; their
    // *_s4 results are consumed by Pipeline 4.

    // Pipeline 2-1: delay activation-read valid to the SRAM return stage,
    // then use it to write the activation buffer.
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

    // Pipeline 2-2: delay weight valid to the returned-weight stage before
    // loading the weight registers.
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

    // Pipeline 2-3: carry the vector-group index through the activation-read
    // latency for PSUM accumulation.
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

            if (load_valid_s4) group_idx_buf <= group_idx_s4;
            else group_idx_buf <= group_idx_buf;
        end
    end : group_idx_pipeline

    // Pipeline 3: multiply the buffered activation and weight vectors.
    generate
        for (i = 0; i < 2; i++) begin : gen_pe
            PE #(
                .INPUT_WIDTH (8),
                .OUTPUT_WIDTH(20)
            ) pe_inst (
                .weight({8'd0, weight_reg[i][3:0]}),
                .activation({8'd0, line_buffer[0][i*4+:4]}),
                .valid(pe_valid),
                .mode(FC),
                .result(pe_out[i])
            );
        end : gen_pe
    endgenerate

    // Pipeline 4: register the activation vector returned through
    // Pipeline 2-1~2-2 before it is consumed by the PE.
    always_ff @(posedge clk or negedge rst_n) begin : line_buffer_ff
        if (!rst_n) begin
            foreach (line_buffer[i]) line_buffer[i] <= '0;
        end else if (load_valid_s4) begin
            line_buffer[0][3:0] <= sram_act_rdata0_buf;
            line_buffer[0][7:4] <= sram_act_rdata1_buf;
        end else begin
            foreach (line_buffer[i]) line_buffer[i] <= line_buffer[i];
        end
    end : line_buffer_ff

    // Pipeline 4: mark the returned activation vector as available to PE.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vector_buf_valid <= 1'b0;
        else vector_buf_valid <= load_valid_s4;
    end

    // Pipeline 4: register weight words returned through Pipeline 2-3
    // before they are consumed by the PE.
    always_ff @(posedge clk or negedge rst_n) begin : weight_reg_ff
        if (!rst_n) begin
            foreach (weight_reg[i]) weight_reg[i] <= '0;
        end else if (weight_valid_s4) begin
            weight_reg[0][3:0] <= sram_weight_rdata0_buf;
            weight_reg[1][3:0] <= sram_weight_rdata1_buf;
        end
    end : weight_reg_ff

    // Pipeline 4: register PE results before summing and PSUM update.
    always_ff @(posedge clk or negedge rst_n) begin : pe_out_ff
        if (!rst_n) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= '0;
        end else if (pe_valid) begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= pe_out[i];
        end else begin
            foreach (pe_out_s4[i]) pe_out_s4[i] <= pe_out_s4[i];
        end
    end : pe_out_ff

    // Pipeline 4: sum PE results and sign-extend the partial sum.
    assign conv_sum = $signed(pe_out_s4[0]) + $signed(pe_out_s4[1]);
    assign conv_sum_ext = {{12{conv_sum[19]}}, conv_sum};

    // Pipeline 4: align the group index with the registered PE result.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) group_idx_mac_s4 <= '0;
        else if (pe_valid) group_idx_mac_s4 <= group_idx_buf;
    end

    // Pipeline 4: select the first-group sum or accumulate the PSUM.
    assign psum_next = (group_idx_mac_s4 == 6'd0) ? conv_sum_ext : scalar_psum + conv_sum_ext;

    // Pipeline 4: update PSUM and emit one quantized neuron per completed vector.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scalar_psum  <= '0;
            neuron_valid <= 1'b0;
            neuron_data  <= '0;
        end else begin
            neuron_valid <= 1'b0;

            if (s4_valid) begin
                scalar_psum <= psum_next;

                if (group_idx_mac_s4 == 6'd49) begin
                    neuron_data  <= quantize_psum(psum_next, scale_CONV3_buf);
                    neuron_valid <= 1'b1;
                end else begin
                    neuron_data  <= '0;
                    neuron_valid <= 1'b0;
                end
            end else begin
                scalar_psum  <= scalar_psum;
                neuron_data  <= '0;
                neuron_valid <= 1'b0;
            end
        end
    end

    // Pipeline 4 control: advance to the next output neuron after completion.
    always_ff @(posedge clk or negedge rst_n) begin : ch_counter
        if (!rst_n) begin
            out_ch <= 7'd0;
        end else if (change_out_ch) begin
            out_ch <= out_ch + 1'b1;
        end else begin
            out_ch <= out_ch;
        end
    end : ch_counter

    // ReLU, scale, and saturate the PSUM.
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

    // Pipeline 4 output: pack four quantized neurons into one SRAM word.
    always_ff @(posedge clk or negedge rst_n) begin : package_act
        if (!rst_n) begin
            package_cnt <= '0;
            result_reg  <= '0;
        end else if (neuron_valid) begin
            result_reg[package_cnt] <= neuron_data;
            package_cnt <= package_cnt + 1'b1;
        end
    end : package_act

    // Pipeline 4 output: write the quantized neuron to the FC buffer.
    always_ff @(posedge clk or negedge rst_n) begin : write_fc_buffer
        if (!rst_n) begin
            fc_buf_we    <= 1'b0;
            fc_buf_waddr <= 7'd0;
            fc_buf_wdata <= 8'd0;
        end else if (neuron_valid) begin
            fc_buf_we    <= 1'b1;
            fc_buf_waddr <= out_ch;
            fc_buf_wdata <= neuron_data;
        end else begin
            fc_buf_we    <= 1'b0;
            fc_buf_waddr <= fc_buf_waddr;
            fc_buf_wdata <= fc_buf_wdata;
        end
    end

    // Pipeline 4 output: write the packed neuron word to activation SRAM.
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

    // Pipeline 4 output: detect the final word and delay completion for the
    // top-level interface.
    assign conv3_done = pack_valid && (write_addr == 17'd29) && (out_ch == 8'd119);
    assign done = done_delay[1];

    always_ff @(posedge clk or negedge rst_n) begin : done_delay_ff
        if (!rst_n) done_delay <= 1'b0;
        else done_delay <= {done_delay[0], conv3_done};
    end : done_delay_ff

endmodule
