module fc_buffer (
    // Clock and active-low asynchronous reset.
    input logic       clk,
    input logic       rst_n,
    // Single-byte write interface; valid write addresses are 0 to 119.
    input logic       fc_buf_we,
    input logic [6:0] fc_buf_waddr,
    input logic [7:0] fc_buf_wdata,

    input logic        reload_we,
    input logic [ 6:0] reload_waddr,
    input logic [63:0] reload_wdata, // 兩個 SRAM Port 組成的 64-bit 資料
    input logic [7:0]  reload_wstrb, // 8-bit Byte Enable，最後一組只啟用低四個 Bytes

    // Read interface; reads eight consecutive bytes starting at the read address.
    input logic fc_buf_re,
    input logic [6:0] fc_buf_raddr,
    output logic [63:0] fc_buf_rdata
);
    // 120-byte buffer indexed by byte address.
    logic [119:0][7:0] fc_buf;
    logic load_en;
    logic reload_en;

    // Ignore writes to addresses 120 to 127 to prevent out-of-range access.
    assign load_en = fc_buf_we && fc_buf_waddr < 'd120;

    always_ff @(posedge clk or negedge rst_n) begin : load_buffer
        if (!rst_n) begin
            fc_buf <= '0;
        end else if (reload_we) begin
            for (int i = 0; i < 8; i++) begin
                if (reload_wstrb[i] && (int'(reload_waddr) + i < 120)) begin

                    fc_buf[reload_waddr+i] <= reload_wdata[i*8+:8];
                end
            end
        end else if (load_en) begin
            fc_buf[fc_buf_waddr] <= fc_buf_wdata;
        end
    end : load_buffer

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
