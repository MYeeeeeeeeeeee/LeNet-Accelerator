// OPT-06 candidate: one shared 2 x 10 x 32-bit channel PSUM register bank.
// Intended for temporally exclusive CONV2 and FC2 operation.
// This module has combinational reads and synchronous writes: no added pipeline cycle.
// Source mappings are documented in README_shared_ch_temp_buffer.md.
module shared_ch_temp_buffer (
    input  logic                    clk,
    input  logic                    rst_n,

    // CONV2: update one PSUM per valid Pipeline-4 transaction.
    input  logic                    conv2_update_valid,
    input  logic                    conv2_first_in_ch,
    input  logic                    conv2_write_row,
    input  logic [3:0]              conv2_write_col,
    input  logic signed [31:0]      conv2_sum_ext,

    // CONV2: four simultaneous combinational reads for 2x2 max pooling.
    input  logic [3:0]              conv2_pool_col_base,
    output logic signed [31:0]      conv2_pool00,
    output logic signed [31:0]      conv2_pool01,
    output logic signed [31:0]      conv2_pool10,
    output logic signed [31:0]      conv2_pool11,

    // FC2: write the final MAC PSUM of one output neuron into row 0.
    input  logic                    fc2_mac_write_valid,
    input  logic [3:0]              fc2_mac_out_ch,
    input  logic signed [31:0]      fc2_psum_next,

    // FC2: apply two biases in parallel, writing row 1 (even / odd).
    input  logic                    fc2_bias_write_valid,
    input  logic [2:0]              fc2_bias_idx,
    input  logic signed [31:0]      fc2_bias0,
    input  logic signed [31:0]      fc2_bias1,

    // FC2: combinational result read; original FC2 registers SRAM wdata.
    input  logic [3:0]              fc2_result_raddr,
    output logic signed [31:0]      fc2_result_rdata
);

    // Same packed-array shape as both original layers:
    //   logic signed [9:0][31:0] ch_temp_psum[0:1];
    logic signed [9:0][31:0] psum [0:1];
    logic [3:0] pool_next_col;
    logic [3:0] bias_even_col;
    logic [3:0] bias_odd_col;

    assign pool_next_col = conv2_pool_col_base + 4'd1;
    assign bias_even_col = {fc2_bias_idx, 1'b0};
    assign bias_odd_col  = {fc2_bias_idx, 1'b1};

    // Preserve original nonblocking assignment read/modify/write semantics.
    // The write-enable conditions must already be aligned to each layer's
    // existing Pipeline-4 signals. Only one layer may own the buffer at a time.
    always_ff @(posedge clk or negedge rst_n) begin : channel_psum_ff
        if (!rst_n) begin
            foreach (psum[r]) psum[r] <= '0;
        end else if (conv2_update_valid) begin
            if (conv2_first_in_ch) begin
                psum[conv2_write_row][conv2_write_col] <= conv2_sum_ext;
            end else begin
                psum[conv2_write_row][conv2_write_col] <=
                    psum[conv2_write_row][conv2_write_col] + conv2_sum_ext;
            end
        end else if (fc2_mac_write_valid) begin
            psum[0][fc2_mac_out_ch] <= fc2_psum_next;
        end else if (fc2_bias_write_valid) begin
            psum[1][bias_even_col] <=
                psum[0][bias_even_col] + fc2_bias0;
            psum[1][bias_odd_col] <=
                psum[0][bias_odd_col] + fc2_bias1;
        end
    end

    // Read combinationally to preserve the original pooling / SRAM timing.
    assign conv2_pool00 = psum[0][conv2_pool_col_base];
    assign conv2_pool01 = psum[0][pool_next_col];
    assign conv2_pool10 = psum[1][conv2_pool_col_base];
    assign conv2_pool11 = psum[1][pool_next_col];

    assign fc2_result_rdata = psum[1][fc2_result_raddr];

endmodule
