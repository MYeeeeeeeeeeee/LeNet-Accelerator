// OPT-04B: One physical 5-PE array shared by CONV1 and CONV2.
// Combinational only. Per-layer pipeline FFs stay inside conv1.sv/conv2.sv.
module shared_pe_array #(
    parameter int INPUT_WIDTH  = 8,
    parameter int OUTPUT_WIDTH = 18
) (
    input  logic signed [4:0][INPUT_WIDTH-1:0] weight     [0:4],
    input  logic        [4:0][INPUT_WIDTH-1:0] activation [0:4],
    input  logic valid,
    output logic signed [OUTPUT_WIDTH-1:0] result        [0:4]
);

    for (genvar pe_i = 0; pe_i < 5; pe_i++) begin : gen_shared_pe
        PE #(
            .INPUT_WIDTH(INPUT_WIDTH),
            .OUTPUT_WIDTH(OUTPUT_WIDTH)
        ) pe_inst (
            .weight     (weight[pe_i]),
            .activation (activation[pe_i]),
            .valid      (valid),
            .mode       (pkg::CONV),
            .result     (result[pe_i])
        );
    end

endmodule
