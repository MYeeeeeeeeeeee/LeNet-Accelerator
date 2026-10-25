module lenet (
    input logic clk,
    input logic rst_n,

    input  logic compute_start,
    output logic compute_finish,

    // Per-layer quantization scales, consumed by the corresponding layer.
    input logic [31:0] scale_CONV1,
    input logic [31:0] scale_CONV2,
    input logic [31:0] scale_CONV3,
    input logic [31:0] scale_FC1,
    input logic [31:0] scale_FC2,

    // Dual-port weight SRAM interface. Each port exposes byte write enables.
    output logic [ 3:0] sram_weight_wea0,
    output logic [15:0] sram_weight_addr0,
    output logic [31:0] sram_weight_wdata0,
    input  logic [31:0] sram_weight_rdata0,
    output logic [ 3:0] sram_weight_wea1,
    output logic [15:0] sram_weight_addr1,
    output logic [31:0] sram_weight_wdata1,
    input  logic [31:0] sram_weight_rdata1,

    // Dual-port activation SRAM interface. Each port exposes byte write enables.
    output logic [ 3:0] sram_act_wea0,
    output logic [15:0] sram_act_addr0,
    output logic [31:0] sram_act_wdata0,
    input  logic [31:0] sram_act_rdata0,
    output logic [ 3:0] sram_act_wea1,
    output logic [15:0] sram_act_addr1,
    output logic [31:0] sram_act_wdata1,
    input  logic [31:0] sram_act_rdata1
);
    // Activation SRAM map. Offsets are word addresses reserved by each layer.
    localparam shortint conv1_in_offset  = 16'd0;
    localparam shortint conv2_in_offset  = 16'd256;
    localparam shortint conv3_in_offset  = 16'd592;
    localparam shortint fc1_in_offset    = 16'd692;
    localparam shortint fc2_in_offset    = 16'd722;
    localparam shortint conv1_out_offset = 16'd256;
    localparam shortint conv2_out_offset = 16'd592;
    localparam shortint conv3_out_offset = 16'd692;
    localparam shortint fc1_out_offset   = 16'd722;
    localparam shortint fc2_out_offset   = 16'd743;

    // Weight SRAM map. Offsets are word addresses reserved by each layer.
    localparam shortint conv1_weight_offset = 16'd0;
    localparam shortint conv2_weight_offset = 16'd60;
    localparam shortint conv3_weight_offset = 16'd1020;
    localparam shortint fc1_weight_offset   = 16'd13020;
    localparam shortint fc2_weight_offset   = 16'd15540;
    localparam shortint fc3_weight_offset   = 16'd15750;

    // The controller advances through the layers in network order.
    typedef enum logic [2:0] {
        IDLE,
        CONV1,
        CONV2,
        CONV3,
        FC1,
        FC2
    } state_t;

    state_t cs, ns;
    logic compute_start_buf;  // Delayed start request used by the FSM.

    logic conv1_enable;
    logic conv1_done;

    logic conv2_enable;
    logic conv2_done;

    logic conv3_enable;
    logic conv3_done;

    logic conv1_done_reg;
    logic conv2_done_reg;
    logic conv3_done_reg;

    logic all_layers_done;

    // CONV1's private SRAM request signals.
    logic [3:0] c1_weight_wea0, c1_weight_wea1;
    logic [15:0] c1_weight_addr0, c1_weight_addr1;
    logic [31:0] c1_weight_wdata0, c1_weight_wdata1;
    logic [3:0] c1_act_wea0, c1_act_wea1;
    logic [15:0] c1_act_addr0, c1_act_addr1;
    logic [31:0] c1_act_wdata0, c1_act_wdata1;
    // CONV2's private SRAM request signals.
    logic [3:0] c2_weight_wea0, c2_weight_wea1;
    logic [15:0] c2_weight_addr0, c2_weight_addr1;
    logic [31:0] c2_weight_wdata0, c2_weight_wdata1;
    logic [3:0] c2_act_wea0, c2_act_wea1;
    logic [15:0] c2_act_addr0, c2_act_addr1;
    logic [31:0] c2_act_wdata0, c2_act_wdata1;
    // CONV3's private SRAM request signals.
    logic [3:0] c3_weight_wea0, c3_weight_wea1;
    logic [15:0] c3_weight_addr0, c3_weight_addr1;
    logic [31:0] c3_weight_wdata0, c3_weight_wdata1;
    logic [3:0] c3_act_wea0, c3_act_wea1;
    logic [15:0] c3_act_addr0, c3_act_addr1;
    logic [31:0] c3_act_wdata0, c3_act_wdata1;

    // Delay the external start request by one clock before entering CONV1.
    always_ff @(posedge clk or negedge rst_n) begin : input_flag
        if (!rst_n) compute_start_buf <= 1'b0;
        else compute_start_buf <= compute_start;
    end

    always_ff @(posedge clk or negedge rst_n) begin : fsm
        if (!rst_n) cs <= IDLE;
        else cs <= ns;
    end

    always_comb begin : fsm_ns
        ns = cs;  // Hold the current state unless a transition is selected.
        case (cs)
            IDLE: begin
                if (compute_start_buf) ns = CONV1;
                else ns = IDLE;
            end
            CONV1:   if (conv1_done) ns = CONV2;
            // Later states remain here until their completion transitions are added.
            CONV2:   ns = CONV2;
            CONV3:   ns = CONV3;
            FC1:     ns = FC1;
            FC2:     ns = FC2;
            default: ns = IDLE;
        endcase
    end

    // Layer enables stay high while their state is active and the layer is
    // incomplete. The done registers prevent a completed layer from restarting.
    assign all_layers_done = conv1_done_reg && conv2_done_reg && conv3_done_reg;



    assign conv1_enable = (cs == CONV1) && !conv1_done_reg;
    assign conv2_enable = (cs == CONV2) && conv1_done_reg && !conv2_done_reg;
    //assign conv3_enable = (cs == CONV3) && conv2_done_reg && !conv3_done_reg;


    always_ff @(posedge clk or negedge rst_n) begin : layer_done_ff
        if (!rst_n) begin
            conv1_done_reg <= 1'b0;
            conv2_done_reg <= 1'b0;
            conv3_done_reg <= 1'b0;
        end else if (conv1_done) conv1_done_reg <= 1;
        else if (conv2_done) conv2_done_reg <= 1;
        else if (conv3_done) conv3_done_reg <= 1;
    end

    conv1 u_conv1 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(conv1_enable),
        .done(conv1_done),

        .scale_CONV1(scale_CONV1),

        .sram_weight_wea0  (c1_weight_wea0),
        .sram_weight_addr0 (c1_weight_addr0),
        .sram_weight_wdata0(c1_weight_wdata0),
        .sram_weight_rdata0(sram_weight_rdata0),
        .sram_weight_wea1  (c1_weight_wea1),
        .sram_weight_addr1 (c1_weight_addr1),
        .sram_weight_wdata1(c1_weight_wdata1),
        .sram_weight_rdata1(sram_weight_rdata1),

        .sram_act_wea0  (c1_act_wea0),
        .sram_act_addr0 (c1_act_addr0),
        .sram_act_wdata0(c1_act_wdata0),
        .sram_act_rdata0(sram_act_rdata0),
        .sram_act_wea1  (c1_act_wea1),
        .sram_act_addr1 (c1_act_addr1),
        .sram_act_wdata1(c1_act_wdata1),
        .sram_act_rdata1(sram_act_rdata1)
    );

    conv2 u_conv2 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(conv2_enable),
        .done(conv2_done),

        .scale_CONV2(scale_CONV2),

        .sram_weight_wea0  (c2_weight_wea0),
        .sram_weight_addr0 (c2_weight_addr0),
        .sram_weight_wdata0(c2_weight_wdata0),
        .sram_weight_rdata0(sram_weight_rdata0),
        .sram_weight_wea1  (c2_weight_wea1),
        .sram_weight_addr1 (c2_weight_addr1),
        .sram_weight_wdata1(c2_weight_wdata1),
        .sram_weight_rdata1(sram_weight_rdata1),

        .sram_act_wea0  (c2_act_wea0),
        .sram_act_addr0 (c2_act_addr0),
        .sram_act_wdata0(c2_act_wdata0),
        .sram_act_rdata0(sram_act_rdata0),
        .sram_act_wea1  (c2_act_wea1),
        .sram_act_addr1 (c2_act_addr1),
        .sram_act_wdata1(c2_act_wdata1),
        .sram_act_rdata1(sram_act_rdata1)
    );


    conv3 u_conv3 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(conv3_enable),
        .done(conv3_done),

        .scale_CONV3(scale_CONV3),

        .sram_weight_wea0  (c3_weight_wea0),
        .sram_weight_addr0 (c3_weight_addr0),
        .sram_weight_wdata0(c3_weight_wdata0),
        .sram_weight_rdata0(sram_weight_rdata0),
        .sram_weight_wea1  (c3_weight_wea1),
        .sram_weight_addr1 (c3_weight_addr1),
        .sram_weight_wdata1(c3_weight_wdata1),
        .sram_weight_rdata1(sram_weight_rdata1),

        .sram_act_wea0  (c3_act_wea0),
        .sram_act_addr0 (c3_act_addr0),
        .sram_act_wdata0(c3_act_wdata0),
        .sram_act_rdata0(sram_act_rdata0),
        .sram_act_wea1  (c3_act_wea1),
        .sram_act_addr1 (c3_act_addr1),
        .sram_act_wdata1(c3_act_wdata1),
        .sram_act_rdata1(sram_act_rdata1)
    );


    // Select the active layer's requests onto the shared physical SRAM pins.
    // Address, write-enable, and write-data for each port must come from the
    // same layer; otherwise a write could target the wrong address.
    always_comb begin : sram_layer_mux
        // Safe inactive values while no layer owns the SRAM interface.
        sram_weight_wea0   = 4'b0000;
        sram_weight_addr0  = 16'd0;
        sram_weight_wdata0 = 32'd0;
        sram_weight_wea1   = 4'b0000;
        sram_weight_addr1  = 16'd0;
        sram_weight_wdata1 = 32'd0;
        sram_act_wea0      = 4'b0000;
        sram_act_addr0     = 16'd0;
        sram_act_wdata0    = 32'd0;
        sram_act_wea1      = 4'b0000;
        sram_act_addr1     = 16'd0;
        sram_act_wdata1    = 32'd0;

        case (cs)
            CONV1: begin
                sram_weight_wea0   = c1_weight_wea0;
                sram_weight_addr0  = c1_weight_addr0;
                sram_weight_wdata0 = c1_weight_wdata0;
                sram_weight_wea1   = c1_weight_wea1;
                sram_weight_addr1  = c1_weight_addr1;
                sram_weight_wdata1 = c1_weight_wdata1;
                sram_act_wea0      = c1_act_wea0;
                sram_act_addr0     = c1_act_addr0;
                sram_act_wdata0    = c1_act_wdata0;
                sram_act_wea1      = c1_act_wea1;
                sram_act_addr1     = c1_act_addr1;
                sram_act_wdata1    = c1_act_wdata1;
            end
            CONV2: begin
                sram_weight_wea0   = c2_weight_wea0;
                sram_weight_addr0  = c2_weight_addr0;
                sram_weight_wdata0 = c2_weight_wdata0;
                sram_weight_wea1   = c2_weight_wea1;
                sram_weight_addr1  = c2_weight_addr1;
                sram_weight_wdata1 = c2_weight_wdata1;
                sram_act_wea0      = c2_act_wea0;
                sram_act_addr0     = c2_act_addr0;
                sram_act_wdata0    = c2_act_wdata0;
                sram_act_wea1      = c2_act_wea1;
                sram_act_addr1     = c2_act_addr1;
                sram_act_wdata1    = c2_act_wdata1;
            end
            CONV3: begin
                sram_weight_wea0   = c3_weight_wea0;
                sram_weight_addr0  = c3_weight_addr0;
                sram_weight_wdata0 = c3_weight_wdata0;
                sram_weight_wea1   = c3_weight_wea1;
                sram_weight_addr1  = c3_weight_addr1;
                sram_weight_wdata1 = c3_weight_wdata1;
                sram_act_wea0      = c3_act_wea0;
                sram_act_addr0     = c3_act_addr0;
                sram_act_wdata0    = c3_act_wdata0;
                sram_act_wea1      = c3_act_wea1;
                sram_act_addr1     = c3_act_addr1;
                sram_act_wdata1    = c3_act_wdata1;
            end
            default: ;  // IDLE and future states keep the interface inactive.
        endcase
    end

    // Report completion only after all currently tracked convolution layers
    // have asserted done. FC layers are not included until they are implemented.
    always_ff @(posedge clk or negedge rst_n) begin : compute_finish_ff
        if (!rst_n) compute_finish <= 1'b0;
        else if (all_layers_done) compute_finish <= 1'b1;
        else compute_finish <= 1'b0;
    end
endmodule
