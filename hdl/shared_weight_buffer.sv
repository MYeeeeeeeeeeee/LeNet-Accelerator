module shared_weight_buffer (
    input logic clk,
    input logic rst_n,

    input logic       load_valid,
    input logic       vector_mode,
    input logic [3:0] kernel_idx,

    input logic [31:0] wdata0,
    input logic [31:0] wdata1,

    output logic signed [4:0][7:0] weight_reg [0:4]
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            foreach (weight_reg[i])
                weight_reg[i] <= '0;
        end
        else if (load_valid) begin
            if (vector_mode) begin
                // CONV3: 8 weights each cycle
                weight_reg[0][3:0] <= wdata0;
                weight_reg[1][3:0] <= wdata1;
            end
            else if (kernel_idx < 4'd10) begin
                // CONV1 / CONV2: 5x5 kernel
                if (!kernel_idx[0])
                    weight_reg[kernel_idx[3:1]][3:0]
                        <= wdata0;
                else
                    weight_reg[kernel_idx[3:1]][4]
                        <= wdata0[7:0];
            end
        end
    end

endmodule
