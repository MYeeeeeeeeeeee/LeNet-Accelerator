import pkg::*;
module PE #(
    parameter int INPUT_WIDTH  = 8,
    parameter int OUTPUT_WIDTH = 19
) (

    input logic signed [4:0][INPUT_WIDTH-1:0] weight,
    input logic signed [4:0][INPUT_WIDTH-1:0] activation,
    input logic valid,
    input pkg::mode_t mode,
    output logic signed [OUTPUT_WIDTH-1:0] result
);
    logic signed [OUTPUT_WIDTH-1:0] product[0:4];

    always_comb begin : compute_product
        case (mode)
            CONV: begin
                for (int i = 0; i < 5; i++) begin
                    product[i] = $signed(weight[i]) * $signed(activation[i]);
                end
            end
            FC: begin
                product[4] = '0;
                for (int i = 0; i < 4; i++) begin
                    product[i] = $signed(weight[i]) * $signed(activation[i]);
                end
            end
        endcase
    end : compute_product

    always_comb begin : add
        case (mode)
            CONV: begin
                if (valid) begin
                    result = (product[0] + product[1]) + (product[2] + product[3]) + product[4];
                end else begin
                    result = '0;
                end
            end
            FC: begin
                if (valid) begin
                    result = product[0] + product[1] + product[2] + product[3];
                end else begin
                    result = '0;
                end
            end
        endcase

    end : add

endmodule
