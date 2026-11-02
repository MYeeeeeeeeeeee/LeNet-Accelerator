
module shared_line_buffer (
    input logic clk,
    input logic rst_n,

    // 1: CONV1, 0: CONV2
    input logic mode_conv1,
    input logic vector_mode,

    // Write controls
    input logic        load_valid,
    input logic        init_load,
    input logic        shift_rows,
    input logic [ 2:0] row_pair,
    input logic [ 3:0] col_blk,
    input logic [31:0] wdata0,
    input logic [31:0] wdata1,

    // Window selection
    input logic       row_sel,
    input logic [4:0] col,

    output logic [4:0][7:0] pe_window[0:4],
    output logic [63:0] vector_data
);

    logic [31:0][7:0] line_buffer[0:5];

    assign vector_data = line_buffer[0][7:0];

    // Single FF owner for all stored bytes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            foreach (line_buffer[i]) line_buffer[i] <= '0;
        end else if (load_valid) begin
            if (vector_mode) begin
                line_buffer[0][3:0] <= wdata0;
                line_buffer[0][7:4] <= wdata1;
            end else if (mode_conv1 && !init_load) begin  // CONV1 after the initial strip

                if (shift_rows) begin
                    for (int i = 0; i < 4; i++) line_buffer[i] <= line_buffer[i+2];
                end else begin
                end

                line_buffer[4][col_blk*4+:4] <= wdata0;
                line_buffer[5][col_blk*4+:4] <= wdata1;

            end else begin
                // CONV1 initial load, or CONV2 full reload
                line_buffer[row_pair*2][col_blk*4+:4]   <= wdata0;
                line_buffer[row_pair*2+1][col_blk*4+:4] <= wdata1;
            end
        end
    end

    // Same 5x5 selection as existing CONV1 / CONV2
    always_comb begin
        for (int r = 0; r < 5; r++) begin
            for (int c = 0; c < 5; c++) begin
                if (!row_sel) pe_window[r][c] = line_buffer[r][col+c];
                else pe_window[r][c] = line_buffer[r+1][col+c];
            end
        end
    end

endmodule
