
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


    // 6 rows x 8 blocks x 32 bits = 192 Bytes
    // Each block contains 4 bytes.
    logic [31:0] blocks[0:5][0:7];

    // Reconstruct the original line_buffer view.
    logic [31:0][7:0] line_buffer[0:5];

    assign vector_data = line_buffer[0][7:0];

    generate
        for (genvar r = 0; r < 6; r++) begin : GEN_ROW
            for (genvar b = 0; b < 8; b++) begin : GEN_BLOCK

                localparam logic [3:0] BLOCK_ID = b;
                localparam logic [2:0] PAIR_ID  = r / 2;

                logic [31:0] shift_source;

                // Each block has one FF owner.
                assign line_buffer[r][b*4+:4] = blocks[r][b];

                // Prevent out-of-range row indexing.
                if (r < 4) begin : GEN_SHIFT_SOURCE
                    assign shift_source = blocks[r+2][b];
                end else begin : GEN_NO_SHIFT
                    assign shift_source = 32'd0;
                end

                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        blocks[r][b] <= 32'd0;
                    end else if (load_valid) begin

                        // CONV3: update the first 8 bytes.
                        if (vector_mode) begin
                            if ((r == 0) && (b == 0)) blocks[r][b] <= wdata0;
                            else if ((r == 0) && (b == 1)) blocks[r][b] <= wdata1;
                        end  // CONV1: shift previous rows,
                             // then load new data into rows 4 and 5.
                        else if (mode_conv1 && !init_load) begin
                            if (r < 4) begin
                                if (shift_rows) blocks[r][b] <= shift_source;
                            end else if (col_blk == BLOCK_ID) begin
                                if (r == 4) blocks[r][b] <= wdata0;
                                else blocks[r][b] <= wdata1;
                            end
                        end  // CONV1 initial load / CONV2 full reload.
                        else if ((row_pair == PAIR_ID) && (col_blk == BLOCK_ID)) begin

                            if ((r % 2) == 0) blocks[r][b] <= wdata0;
                            else blocks[r][b] <= wdata1;
                        end
                    end
                end
            end
        end
    endgenerate

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
