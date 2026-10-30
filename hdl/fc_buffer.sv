module fc_buffer (
    // Clock and active-low asynchronous reset.
    input logic       clk,
    input logic       rst_n,
    // Single-byte write interface; valid write addresses are 0 to 119.
    input logic       fc_buf_we,
    input logic [6:0] fc_buf_waddr,
    input logic [7:0] fc_buf_wdata,

    // Read interface; reads eight consecutive bytes starting at the read address.
    input logic fc_buf_re,
    input logic [6:0] fc_buf_raddr,
    output logic [63:0] fc_buf_rdata
);
    // 120-byte buffer indexed by byte address.
    logic [119:0][7:0] fc_buf;
    logic load_en;

    // Ignore writes to addresses 120 to 127 to prevent out-of-range access.
    assign load_en = fc_buf_we && fc_buf_waddr < 'd120;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear the entire buffer during asynchronous reset.
            fc_buf <= '0;
        end else if (load_en) begin
            // Write one byte on the rising edge of the clock.
            fc_buf[fc_buf_waddr] <= fc_buf_wdata;
        end else begin
            // Hold the current value when there is no valid write request.
            fc_buf <= fc_buf;
        end
    end

    always_comb begin
        // Keep unread bytes at zero when reading is disabled or near the buffer end.
        fc_buf_rdata = '0;

        if (fc_buf_re) begin
            for (int lane = 0; lane < 8; lane++) begin
                // Do not read beyond the end of the buffer.
                if ((int'(fc_buf_raddr) + lane) < 120) begin
                    // Pack the first read byte into the least-significant bits.
                    fc_buf_rdata[lane*8+:8] = fc_buf[fc_buf_raddr+lane];
                end
            end
        end
    end
endmodule
