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
    // ------------------------------------------------------------------------
    // Network controller
    // ------------------------------------------------------------------------
    // The controller advances through the layers in network order.
    state_t cs, ns;

    // External control and controller state.
    logic compute_start_buf;
    logic all_layers_done;

    // Per-layer start and completion handshakes.
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

    // Latched completion status prevents a completed layer from restarting.
    logic conv1_done_reg;
    logic conv2_done_reg;
    logic conv3_done_reg;
    logic fc1_done_reg;
    logic reload_done_reg;
    logic fc2_done_reg;

    // ------------------------------------------------------------------------
    // Per-layer SRAM request signals
    // ------------------------------------------------------------------------
    // Each layer has private request signals that are selected by the
    // shared SRAM multiplexer below.
    // CONV1
    logic [3:0] c1_weight_wea0, c1_weight_wea1;
    logic [15:0] c1_weight_addr0, c1_weight_addr1;
    logic [31:0] c1_weight_wdata0, c1_weight_wdata1;
    logic [3:0] c1_act_wea0, c1_act_wea1;
    logic [15:0] c1_act_addr0, c1_act_addr1;
    logic [31:0] c1_act_wdata0, c1_act_wdata1;

    // CONV2
    logic [3:0] c2_weight_wea0, c2_weight_wea1;
    logic [15:0] c2_weight_addr0, c2_weight_addr1;
    logic [31:0] c2_weight_wdata0, c2_weight_wdata1;
    logic [3:0] c2_act_wea0, c2_act_wea1;
    logic [15:0] c2_act_addr0, c2_act_addr1;
    logic [31:0] c2_act_wdata0, c2_act_wdata1;

    // CONV3
    logic [3:0] c3_weight_wea0, c3_weight_wea1;
    logic [15:0] c3_weight_addr0, c3_weight_addr1;
    logic [31:0] c3_weight_wdata0, c3_weight_wdata1;
    logic [3:0] c3_act_wea0, c3_act_wea1;
    logic [15:0] c3_act_addr0, c3_act_addr1;
    logic [31:0] c3_act_wdata0, c3_act_wdata1;

    // FC1
    logic [3:0] fc1_weight_wea0, fc1_weight_wea1;
    logic [15:0] fc1_weight_addr0, fc1_weight_addr1;
    logic [31:0] fc1_weight_wdata0, fc1_weight_wdata1;
    logic [3:0] fc1_act_wea0, fc1_act_wea1;
    logic [15:0] fc1_act_addr0, fc1_act_addr1;
    logic [31:0] fc1_act_wdata0, fc1_act_wdata1;

    // FC2
    logic [3:0] fc2_weight_wea0, fc2_weight_wea1;
    logic [15:0] fc2_weight_addr0, fc2_weight_addr1;
    logic [31:0] fc2_weight_wdata0, fc2_weight_wdata1;
    logic [3:0] fc2_act_wea0, fc2_act_wea1;
    logic [15:0] fc2_act_addr0, fc2_act_addr1;
    logic [31:0] fc2_act_wdata0, fc2_act_wdata1;

    // ------------------------------------------------------------------------
    // FC buffer and reload interfaces
    // ------------------------------------------------------------------------
    // Shared FC buffer interface.
    logic        fc_buf_we;
    logic [ 6:0] fc_buf_waddr;
    logic [ 7:0] fc_buf_wdata;
    logic        fc_buf_re;
    logic [ 6:0] fc_buf_raddr;
    logic [63:0] fc_buf_rdata;

    // CONV3 writes convolution results into the FC buffer.
    logic        conv3_fc_we;
    logic [ 6:0] conv3_fc_waddr;
    logic [ 7:0] conv3_fc_wdata;

    // Reload controller writes reloaded values into the FC buffer.
    logic        reload_fc_we;
    logic [ 6:0] reload_fc_waddr;
    logic [63:0] reload_fc_wdata;
    logic [ 7:0] reload_fc_wstrb;
    logic        reload_enable;
    logic        reload_done;

    // Reload controller activation SRAM requests.
    logic [3:0] reload_act_wea0, reload_act_wea1;
    logic [15:0] reload_act_addr0, reload_act_addr1;

    // FC layer read requests.
    logic fc1_buf_re;
    logic [6:0] fc1_buf_raddr;
    logic fc2_buf_re;
    logic [6:0] fc2_buf_raddr;

    // ------------------------------------------------------------------------
    // Line buffer requests
    // ------------------------------------------------------------------------
    // CONV1 and CONV2 use the shared 5x5 line-buffer window.
    logic c1_lb_load_valid, c2_lb_load_valid;
    logic c1_lb_init_load, c2_lb_init_load;
    logic c1_lb_shift_rows, c2_lb_shift_rows;

    logic [2:0] c1_lb_row_pair, c2_lb_row_pair;
    logic [3:0] c1_lb_col_blk, c2_lb_col_blk;

    logic [31:0] c1_lb_wdata0, c1_lb_wdata1;
    logic [31:0] c2_lb_wdata0, c2_lb_wdata1;

    logic c1_lb_row_sel, c2_lb_row_sel;
    logic [4:0] c1_lb_col, c2_lb_col;

    // Requests selected onto the shared line-buffer instance.
    logic       lb_load_valid;
    logic       lb_init_load;
    logic       lb_shift_rows;
    logic       lb_mode_conv1;
    logic [2:0] lb_row_pair;
    logic [3:0] lb_col_blk;
    logic [31:0] lb_wdata0, lb_wdata1;
    logic             lb_row_sel;
    logic [ 4:0]      lb_col;

    // Only one physical 5x5 window is implemented and shared by CONV1/CONV2.
    logic [ 4:0][7:0] shared_pe_window   [0:4];

    // CONV3 uses vector mode to provide data for the FC buffer.
    logic             c3_lb_load_valid;
    logic [31:0]      c3_lb_wdata0;
    logic [31:0]      c3_lb_wdata1;

    // Shared line-buffer vector interface.
    logic             lb_vector_mode;
    logic [63:0]      shared_vector_data;

    // ------------------------------------------------------------------------
    // Shared weight buffer interface
    logic             wb_load_valid;
    logic             wb_vector_mode;
    logic [ 3:0]      wb_kernel_idx;
    logic [31:0] wb_wdata0, wb_wdata1;
    logic signed [4:0][7:0] shared_weight[0:4];

    // OPT-04B: one physical PE array shared by CONV1 and CONV2.
    logic c1_pe_req, c2_pe_req;
    logic shared_pe_valid;
    logic signed [19:0] shared_pe_result[0:4];


    // CONV1 CONV2 CONV 3 weight interface
    logic c1_wb_load_valid, c2_wb_load_valid, c3_wb_load_valid;
    logic [3:0] c1_wb_kernel_idx, c2_wb_kernel_idx, c3_wb_kernel_idx;
    logic [31:0] c1_wb_wdata0, c2_wb_wdata0, c3_wb_wdata0;
    logic [31:0] c3_wb_wdata1;

    // FC1/FC2 share the same 8-weight vector register bank as CONV3.
    logic fc1_wb_load_valid, fc2_wb_load_valid;
    logic [31:0] fc1_wb_wdata0, fc1_wb_wdata1;
    logic [31:0] fc2_wb_wdata0, fc2_wb_wdata1;



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


    assign conv1_enable = ((cs == CONV1) && !conv1_done_reg) ? 1'b1 : 1'b0;
    assign conv2_enable = ((cs == CONV2) && conv1_done_reg && !conv2_done_reg) ? 1'b1 : 1'b0;
    assign conv3_enable = ((cs == CONV3) && conv2_done_reg && !conv3_done_reg) ? 1'b1 : 1'b0;
    assign fc1_enable = ((cs == FC1) && conv3_done_reg && !fc1_done_reg) ? 1'b1 : 1'b0;
    assign reload_enable = ((cs == RELOAD84) && fc1_done_reg && !reload_done_reg) ? 1'b1 : 1'b0;
    assign fc2_enable = ((cs == FC2) && reload_done_reg && !fc2_done_reg) ? 1'b1 : 1'b0;

    assign shared_pe_valid = c1_pe_req | c2_pe_req;



    always_ff @(posedge clk or negedge rst_n) begin : layer_done_ff
        if (!rst_n) begin
            conv1_done_reg  <= 1'b0;
            conv2_done_reg  <= 1'b0;
            conv3_done_reg  <= 1'b0;
            fc1_done_reg    <= 1'b0;
            reload_done_reg <= 1'b0;
            fc2_done_reg    <= 1'b0;
        end else begin

            if (conv1_done) conv1_done_reg <= 1'b1;

            if (conv2_done) conv2_done_reg <= 1'b1;

            if (conv3_done) conv3_done_reg <= 1'b1;

            if (fc1_done) fc1_done_reg <= 1'b1;

            if (reload_done) reload_done_reg <= 1'b1;

            if (fc2_done) fc2_done_reg <= 1'b1;
        end
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
        .sram_act_rdata1(sram_act_rdata1),

        .lb_load_valid(c1_lb_load_valid),
        .lb_init_load (c1_lb_init_load),
        .lb_shift_rows(c1_lb_shift_rows),
        .lb_row_pair  (c1_lb_row_pair),
        .lb_col_blk   (c1_lb_col_blk),
        .lb_wdata0    (c1_lb_wdata0),
        .lb_wdata1    (c1_lb_wdata1),
        .lb_row_sel   (c1_lb_row_sel),
        .lb_col       (c1_lb_col),
        .pe_window    (shared_pe_window),

        .wb_load_valid   (c1_wb_load_valid),
        .wb_kernel_idx   (c1_wb_kernel_idx),
        .wb_wdata0       (c1_wb_wdata0),
        .shared_weight   (shared_weight),
        .pe_req          (c1_pe_req),
        .shared_pe_result(shared_pe_result)
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
        .sram_act_rdata1(sram_act_rdata1),

        .lb_load_valid(c2_lb_load_valid),
        .lb_init_load (c2_lb_init_load),
        .lb_shift_rows(c2_lb_shift_rows),
        .lb_row_pair  (c2_lb_row_pair),
        .lb_col_blk   (c2_lb_col_blk),
        .lb_wdata0    (c2_lb_wdata0),
        .lb_wdata1    (c2_lb_wdata1),
        .lb_row_sel   (c2_lb_row_sel),
        .lb_col       (c2_lb_col),
        .pe_window    (shared_pe_window),

        .wb_load_valid   (c2_wb_load_valid),
        .wb_kernel_idx   (c2_wb_kernel_idx),
        .wb_wdata0       (c2_wb_wdata0),
        .shared_weight   (shared_weight),
        .pe_req          (c2_pe_req),
        .shared_pe_result(shared_pe_result)

    );

    
    // Exactly one shared array. No local PE instances inside CONV1/CONV2.
    shared_pe_array #(
        .INPUT_WIDTH (8),
        .OUTPUT_WIDTH(20)
    ) u_shared_pe_array (
        .weight    (shared_weight),
        .activation(shared_pe_window),
        .valid     (shared_pe_valid),
        .result    (shared_pe_result)
    );

    shared_line_buffer u_shared_line_buffer (
        .clk  (clk),
        .rst_n(rst_n),

        .mode_conv1 (lb_mode_conv1),
        .vector_mode(lb_vector_mode),

        .load_valid(lb_load_valid),
        .init_load (lb_init_load),
        .shift_rows(lb_shift_rows),

        .row_pair(lb_row_pair),
        .col_blk (lb_col_blk),

        .wdata0(lb_wdata0),
        .wdata1(lb_wdata1),

        .row_sel(lb_row_sel),
        .col(lb_col),

        .pe_window  (shared_pe_window),
        .vector_data(shared_vector_data)

    );

    shared_weight_buffer u_shared_weight_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .load_valid(wb_load_valid),
        .vector_mode(wb_vector_mode),
        .kernel_idx(wb_kernel_idx),
        .wdata0(wb_wdata0),
        .wdata1(wb_wdata1),
        .weight_reg(shared_weight)
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
        .fc_buf_wdata(conv3_fc_wdata),

        .lb_load_valid (c3_lb_load_valid),
        .lb_wdata0     (c3_lb_wdata0),
        .lb_wdata1     (c3_lb_wdata1),
        .lb_vector_data(shared_vector_data),

        .wb_load_valid(c3_wb_load_valid),
        .wb_wdata0    (c3_wb_wdata0),
        .wb_wdata1    (c3_wb_wdata1),
        .shared_weight(shared_weight)
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
        .fc_buf_rdata(fc_buf_rdata),

        .wb_load_valid(fc1_wb_load_valid),
        .wb_wdata0    (fc1_wb_wdata0),
        .wb_wdata1    (fc1_wb_wdata1),
        .shared_weight(shared_weight)
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
        .fc_buf_rdata(fc_buf_rdata),

        .wb_load_valid(fc2_wb_load_valid),
        .wb_wdata0    (fc2_wb_wdata0),
        .wb_wdata1    (fc2_wb_wdata1),
        .shared_weight(shared_weight)
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


    always_comb begin : line_buffer_mux
        lb_mode_conv1  = 1'b0;
        lb_load_valid  = 1'b0;
        lb_init_load   = 1'b0;
        lb_shift_rows  = 1'b0;

        lb_row_pair    = '0;
        lb_col_blk     = '0;
        lb_wdata0      = '0;
        lb_wdata1      = '0;

        lb_row_sel     = 1'b0;
        lb_col         = '0;
        lb_vector_mode = 1'b0;

        case (cs)
            CONV1: begin
                lb_mode_conv1 = 1'b1;
                lb_load_valid = c1_lb_load_valid;
                lb_init_load  = c1_lb_init_load;
                lb_shift_rows = c1_lb_shift_rows;

                lb_row_pair   = c1_lb_row_pair;
                lb_col_blk    = c1_lb_col_blk;
                lb_wdata0     = c1_lb_wdata0;
                lb_wdata1     = c1_lb_wdata1;

                lb_row_sel    = c1_lb_row_sel;
                lb_col        = c1_lb_col;
            end

            CONV2: begin
                lb_mode_conv1 = 1'b0;
                lb_load_valid = c2_lb_load_valid;
                lb_init_load  = c2_lb_init_load;
                lb_shift_rows = c2_lb_shift_rows;

                lb_row_pair   = c2_lb_row_pair;
                lb_col_blk    = c2_lb_col_blk;
                lb_wdata0     = c2_lb_wdata0;
                lb_wdata1     = c2_lb_wdata1;

                lb_row_sel    = c2_lb_row_sel;
                lb_col        = c2_lb_col;
            end
            CONV3: begin
                lb_vector_mode = 1'b1;
                lb_load_valid = c3_lb_load_valid;

                lb_wdata0 = c3_lb_wdata0;
                lb_wdata1 = c3_lb_wdata1;
            end

            default: ;
        endcase
    end





    always_comb begin : weight_buffer_mux
        wb_load_valid  = 1'b0;
        wb_vector_mode = 1'b0;
        wb_kernel_idx  = '0;
        wb_wdata0      = '0;
        wb_wdata1      = '0;

        case (cs)
            CONV1: begin
                wb_load_valid = c1_wb_load_valid;
                wb_kernel_idx = c1_wb_kernel_idx;
                wb_wdata0     = c1_wb_wdata0;
            end

            CONV2: begin
                wb_load_valid = c2_wb_load_valid;
                wb_kernel_idx = c2_wb_kernel_idx;
                wb_wdata0     = c2_wb_wdata0;
            end

            CONV3: begin
                wb_vector_mode = 1'b1;
                wb_load_valid  = c3_wb_load_valid;
                wb_wdata0      = c3_wb_wdata0;
                wb_wdata1      = c3_wb_wdata1;
            end

            FC1: begin
                wb_vector_mode = 1'b1;
                wb_load_valid  = fc1_wb_load_valid;
                wb_wdata0      = fc1_wb_wdata0;
                wb_wdata1      = fc1_wb_wdata1;
            end

            FC2: begin
                wb_vector_mode = 1'b1;
                wb_load_valid  = fc2_wb_load_valid;
                wb_wdata0      = fc2_wb_wdata0;
                wb_wdata1      = fc2_wb_wdata1;
            end

            default: ;
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
    // Report completion only after every network stage, including reload,
    // has asserted done.
    always_ff @(posedge clk or negedge rst_n) begin : compute_finish_ff
        if (!rst_n) compute_finish <= 1'b0;
        else if (all_layers_done) compute_finish <= 1'b1;
        else compute_finish <= 1'b0;
    end
endmodule
