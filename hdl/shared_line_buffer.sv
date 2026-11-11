
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


    // Banked Window Read
    // Valid col range: 0 ~ 27
    // 6 candidate rows, each outputting 5 bytes.

    logic [63:0] selected8[0:5];
    logic [39:0] window5  [0:5];

    always_comb begin : window_read_mux

        // Step 1: Select 8 consecutive bytes for each row.
        for (int r = 0; r < 6; r++) begin

            case (col[4:2])
                3'd0: selected8[r] = line_buffer[r][7:0];
                3'd1: selected8[r] = line_buffer[r][11:4];
                3'd2: selected8[r] = line_buffer[r][15:8];
                3'd3: selected8[r] = line_buffer[r][19:12];
                3'd4: selected8[r] = line_buffer[r][23:16];
                3'd5: selected8[r] = line_buffer[r][27:20];
                3'd6: selected8[r] = line_buffer[r][31:24];

                default: selected8[r] = 64'd0;
            endcase

            // Step 2: Shift by 0, 8, 16, or 24 bits.
            // Keep the lowest 40 bits = 5 bytes.
            window5[r] = selected8[r] >> {col[1:0], 3'b000};

        end

        // Step 3: Choose 5 out of the 6 rows.
        for (int r = 0; r < 5; r++) begin
            if (!row_sel) pe_window[r] = window5[r];
            else pe_window[r] = window5[r+1];
        end
    end


endmodule
