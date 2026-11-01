import pkg::*;

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
    pkg::state_t cs, ns;

    logic compute_start_buf;  // Delayed start request used by the FSM.

    logic conv1_enable;
    logic conv1_done;

    logic conv2_enable;
    logic conv2_done;

    logic conv3_enable;
    logic conv3_done;

    logic fc1_enable;
    logic fc1_done;

    logic fc2_enable;
    logic fc2_done;

    logic conv1_done_reg;
    logic conv2_done_reg;
    logic conv3_done_reg;
    logic fc1_done_reg;
    logic reload_done_reg;
    logic fc2_done_reg;

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
    // FC1's private SRAM request signals.
    logic [3:0] fc1_weight_wea0, fc1_weight_wea1;
    logic [15:0] fc1_weight_addr0, fc1_weight_addr1;
    logic [31:0] fc1_weight_wdata0, fc1_weight_wdata1;
    logic [3:0] fc1_act_wea0, fc1_act_wea1;
    logic [15:0] fc1_act_addr0, fc1_act_addr1;
    logic [31:0] fc1_act_wdata0, fc1_act_wdata1;
    // FC2's private SRAM request signals.
    logic [3:0] fc2_weight_wea0, fc2_weight_wea1;
    logic [15:0] fc2_weight_addr0, fc2_weight_addr1;
    logic [31:0] fc2_weight_wdata0, fc2_weight_wdata1;
    logic [3:0] fc2_act_wea0, fc2_act_wea1;
    logic [15:0] fc2_act_addr0, fc2_act_addr1;
    logic [31:0] fc2_act_wdata0, fc2_act_wdata1;


    // FC buffer interface signals.
    logic        fc_buf_we;
    logic [ 6:0] fc_buf_waddr;
    logic [ 7:0] fc_buf_wdata;
    logic        fc_buf_re;
    logic [ 6:0] fc_buf_raddr;
    logic [63:0] fc_buf_rdata;
    // CONV3's interface to the FC buffer.
    logic        conv3_fc_we;
    logic [ 6:0] conv3_fc_waddr;
    logic [ 7:0] conv3_fc_wdata;
    // Reload controller private write interface
    logic        reload_fc_we;
    logic [ 6:0] reload_fc_waddr;
    logic [63:0] reload_fc_wdata;
    logic [ 7:0] reload_fc_wstrb;
    logic        reload_enable;
    logic        reload_done;
    logic [3:0] reload_act_wea0, reload_act_wea1;
    logic [15:0] reload_act_addr0, reload_act_addr1;

    logic fc1_buf_re;
    logic [6:0] fc1_buf_raddr;
    
    logic fc2_buf_re;
    logic [6:0] fc2_buf_raddr;


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
            CONV1: begin
                if (conv1_done) ns = CONV2;
                else ns = CONV1;
            end
            CONV2: begin
                if (conv2_done) ns = CONV3;
                else ns = CONV2;
            end
            CONV3: begin
                if (conv3_done) ns = FC1;
                else ns = CONV3;
            end
            FC1: begin
                if (fc1_done) ns = RELOAD84;
                else ns = FC1;
            end
            RELOAD84: begin
                if (reload_done) ns = FC2;
                else ns = RELOAD84;
            end
            FC2: begin
                if (fc2_done) ns = IDLE;
                else ns = FC2;
            end
            default: ns = IDLE;
        endcase
    end

    // Layer enables stay high while their state is active and the layer is
    // incomplete. The done registers prevent a completed layer from restarting.
    assign all_layers_done = conv1_done_reg & conv2_done_reg & conv3_done_reg & fc1_done_reg & reload_done_reg & fc2_done_reg;



    assign conv1_enable = (cs == CONV1) && !conv1_done_reg;
    assign conv2_enable = (cs == CONV2) && conv1_done_reg && !conv2_done_reg;
    assign conv3_enable = (cs == CONV3) && conv2_done_reg && !conv3_done_reg;
    assign fc1_enable = (cs == FC1) && conv3_done_reg && !fc1_done_reg;
    assign reload_enable = (cs == RELOAD84) && fc1_done_reg && !reload_done_reg;
    assign fc2_enable = (cs == FC2) && reload_done_reg && !fc2_done_reg;


    always_ff @(posedge clk or negedge rst_n) begin : layer_done_ff
        if (!rst_n) begin
            conv1_done_reg <= 1'b0;
            conv2_done_reg <= 1'b0;
            conv3_done_reg <= 1'b0;
            fc1_done_reg <= 1'b0;
            reload_done_reg <= 1'b0;
            fc2_done_reg <= 1'b0;
        end else if (conv1_done) conv1_done_reg <= 1;
        else if (conv2_done) conv2_done_reg <= 1;
        else if (conv3_done) conv3_done_reg <= 1;
        else if (fc1_done) fc1_done_reg <= 1;
        else if (reload_done) reload_done_reg <= 1;
        else if (fc2_done) fc2_done_reg <= 1;
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
        .sram_act_rdata1(sram_act_rdata1),

        .fc_buf_we(conv3_fc_we),
        .fc_buf_waddr(conv3_fc_waddr),
        .fc_buf_wdata(conv3_fc_wdata)
    );

    fc_buffer u_fc_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .fc_buf_we(fc_buf_we),
        .fc_buf_waddr(fc_buf_waddr),
        .fc_buf_wdata(fc_buf_wdata),

        .fc_buf_re(fc_buf_re),
        .fc_buf_raddr(fc_buf_raddr),
        .fc_buf_rdata(fc_buf_rdata),

        .reload_we(reload_fc_we),
        .reload_waddr(reload_fc_waddr),
        .reload_wdata(reload_fc_wdata),
        .reload_wstrb(reload_fc_wstrb)

    );

    fc1 u_fc1 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(fc1_enable),
        .done(fc1_done),

        .scale_FC1(scale_FC1),

        .sram_weight_wea0  (fc1_weight_wea0),
        .sram_weight_addr0 (fc1_weight_addr0),
        .sram_weight_wdata0(fc1_weight_wdata0),
        .sram_weight_rdata0(sram_weight_rdata0),
        .sram_weight_wea1  (fc1_weight_wea1),
        .sram_weight_addr1 (fc1_weight_addr1),
        .sram_weight_wdata1(fc1_weight_wdata1),
        .sram_weight_rdata1(sram_weight_rdata1),

        .sram_act_wea0  (fc1_act_wea0),
        .sram_act_addr0 (fc1_act_addr0),
        .sram_act_wdata0(fc1_act_wdata0),
        .sram_act_rdata0(sram_act_rdata0),
        .sram_act_wea1  (fc1_act_wea1),
        .sram_act_addr1 (fc1_act_addr1),
        .sram_act_wdata1(fc1_act_wdata1),
        .sram_act_rdata1(sram_act_rdata1),

        .fc_buf_re   (fc1_buf_re),
        .fc_buf_raddr(fc1_buf_raddr),
        .fc_buf_rdata(fc_buf_rdata)
    );



    reload_controller u_reload_controller (
        .clk  (clk),
        .rst_n(rst_n),

        .reload_en  (reload_enable),
        .reload_done(reload_done),

        .sram_act_wea0  (reload_act_wea0),
        .sram_act_addr0 (reload_act_addr0),
        .sram_act_rdata0(sram_act_rdata0),

        .sram_act_wea1  (reload_act_wea1),
        .sram_act_addr1 (reload_act_addr1),
        .sram_act_rdata1(sram_act_rdata1),

        .reload_we   (reload_fc_we),
        .reload_waddr(reload_fc_waddr),
        .reload_wdata(reload_fc_wdata),
        .reload_wstrb(reload_fc_wstrb)
    );

    fc2 u_fc2 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(fc2_enable),
        .done(fc2_done),

        .scale_FC2(scale_FC2),

        .sram_weight_wea0  (fc2_weight_wea0),
        .sram_weight_addr0 (fc2_weight_addr0),
        .sram_weight_wdata0(fc2_weight_wdata0),
        .sram_weight_rdata0(sram_weight_rdata0),
        .sram_weight_wea1  (fc2_weight_wea1),
        .sram_weight_addr1 (fc2_weight_addr1),
        .sram_weight_wdata1(fc2_weight_wdata1),
        .sram_weight_rdata1(sram_weight_rdata1),

        .sram_act_wea0  (fc2_act_wea0),
        .sram_act_addr0 (fc2_act_addr0),
        .sram_act_wdata0(fc2_act_wdata0),
        .sram_act_rdata0(sram_act_rdata0),
        .sram_act_wea1  (fc2_act_wea1),
        .sram_act_addr1 (fc2_act_addr1),
        .sram_act_wdata1(fc2_act_wdata1),
        .sram_act_rdata1(sram_act_rdata1),

        .fc_buf_re   (fc2_buf_re),
        .fc_buf_raddr(fc2_buf_raddr),
        .fc_buf_rdata(fc_buf_rdata)
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
            FC1: begin
                sram_weight_wea0   = fc1_weight_wea0;
                sram_weight_addr0  = fc1_weight_addr0;
                sram_weight_wdata0 = fc1_weight_wdata0;
                sram_weight_wea1   = fc1_weight_wea1;
                sram_weight_addr1  = fc1_weight_addr1;
                sram_weight_wdata1 = fc1_weight_wdata1;
                sram_act_wea0      = fc1_act_wea0;
                sram_act_addr0     = fc1_act_addr0;
                sram_act_wdata0    = fc1_act_wdata0;
                sram_act_wea1      = fc1_act_wea1;
                sram_act_addr1     = fc1_act_addr1;
                sram_act_wdata1    = fc1_act_wdata1;
            end
            RELOAD84: begin
                // Activation SRAM Read Only
                sram_act_wea0   = reload_act_wea0;
                sram_act_addr0  = reload_act_addr0;
                sram_act_wdata0 = 32'd0;

                sram_act_wea1   = reload_act_wea1;
                sram_act_addr1  = reload_act_addr1;
                sram_act_wdata1 = 32'd0;
            end
            FC2: begin
                sram_weight_wea0   = fc2_weight_wea0;
                sram_weight_addr0  = fc2_weight_addr0;
                sram_weight_wdata0 = fc2_weight_wdata0;
                sram_weight_wea1   = fc2_weight_wea1;
                sram_weight_addr1  = fc2_weight_addr1;
                sram_weight_wdata1 = fc2_weight_wdata1;
                sram_act_wea0      = fc2_act_wea0;
                sram_act_addr0     = fc2_act_addr0;
                sram_act_wdata0    = fc2_act_wdata0;
                sram_act_wea1      = fc2_act_wea1;
                sram_act_addr1     = fc2_act_addr1;
                sram_act_wdata1    = fc2_act_wdata1;
            end
        endcase
    end

    always_comb begin : fc_buf_write_mux
        fc_buf_we    = 1'b0;
        fc_buf_waddr = '0;
        fc_buf_wdata = '0;

        case (cs)
            CONV3: begin
                fc_buf_we    = conv3_fc_we;
                fc_buf_waddr = conv3_fc_waddr;
                fc_buf_wdata = conv3_fc_wdata;
            end

            default: ;
        endcase
    end

    always_comb begin : fc_buf_read_mux
        fc_buf_re    = 1'b0;
        fc_buf_raddr = '0;

        case (cs)
            FC1: begin
                fc_buf_re    = fc1_buf_re;
                fc_buf_raddr = fc1_buf_raddr;
            end

            FC2: begin
                fc_buf_re    = fc2_buf_re;
                fc_buf_raddr = fc2_buf_raddr;
            end

            default: ;
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
