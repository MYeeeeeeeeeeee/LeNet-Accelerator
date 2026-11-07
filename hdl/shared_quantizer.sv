module shared_quantizer (
    input  logic signed [31:0] psum_in,
    input  logic        [31:0] scale_in,
    output logic        [7:0]  quant_out
);

    logic [31:0] relu_out;
    logic [63:0] product;
    logic [63:0] shifted;

    always_comb begin
        // ReLU
        relu_out = (psum_in <= 0)
                 ? 32'd0
                 : $unsigned(psum_in);

        // Quantization
        product = relu_out * scale_in;
        shifted = product >> 16;

        // Saturation
        if (shifted > 64'd127)
            quant_out = 8'd127;
        else
            quant_out = shifted[7:0];
    end

endmodule
