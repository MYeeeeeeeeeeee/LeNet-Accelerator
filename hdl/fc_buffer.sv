
module fc_buffer (
    input logic clk,
    input logic rst_n,

    // CONV3: 8-bit byte write
    input logic       fc_buf_we,
    input logic [6:0] fc_buf_waddr,
    input logic [7:0] fc_buf_wdata,

    // RELOAD84: 64-bit aligned write
    input logic        reload_we,
    input logic [ 6:0] reload_waddr,
    input logic [63:0] reload_wdata,
    input logic [ 7:0] reload_wstrb,

    // FC1 / FC2: 64-bit aligned read
    input  logic        fc_buf_re,
    input  logic [ 6:0] fc_buf_raddr,
    output logic [63:0] fc_buf_rdata,

    output logic [14:0] fc1_group_nonzero
);

    // 15 words x 64 bits = 120 bytes
    logic [63:0] bank[0:14];

    // Static bank and byte-lane decoding
    for (genvar b = 0; b < 15; b++) begin : GEN_BANK
        assign fc1_group_nonzero[b] = |bank[b];
        for (genvar lane = 0; lane < 8; lane++) begin : GEN_LANE

            localparam logic [3:0] BANK_ID = b;
            localparam logic [2:0] LANE_ID = lane;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    bank[b][lane*8+:8] <= 8'd0;
                end else if (reload_we) begin
                    // RELOAD has higher priority.
                    // Address must be 8-byte aligned.
                    if ((reload_waddr < 7'd120) &&
                        (reload_waddr[2:0] == 3'd0) &&
                        (reload_waddr[6:3] == BANK_ID) &&
                        reload_wstrb[lane]) begin

                        bank[b][lane*8+:8] <= reload_wdata[lane*8+:8];
                    end
                end
                else if (
                    fc_buf_we &&
                    (fc_buf_waddr < 7'd120) &&
                    (fc_buf_waddr[6:3] == BANK_ID) &&
                    (fc_buf_waddr[2:0] == LANE_ID)
                ) begin
                    // CONV3 writes one byte at a time.
                    bank[b][lane*8+:8] <= fc_buf_wdata;
                end
            end
        end
    end

    // Select one complete 64-bit word.
    // No additional pipeline stage is introduced.
    always_comb begin
        fc_buf_rdata = 64'd0;

        if (fc_buf_re && (fc_buf_raddr < 7'd120) && (fc_buf_raddr[2:0] == 3'd0)) begin

            fc_buf_rdata = bank[fc_buf_raddr[6:3]];
        end
    end

endmodule
