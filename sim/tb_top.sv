module tb_top;

    timeunit 1ns;
    timeprecision 1ps;

    logic clk = 1'b0;

    always #5ns clk = ~clk;

    lenet_if inf(clk);

    test u_test (
        .vif(inf)
    );

    lenet u_dut (
        .clk            (clk),
        .rst_n          (inf.rst_n),
        .compute_start  (inf.compute_start),
        .compute_finish (inf.compute_finish),

        .scale_CONV1    (inf.scale_CONV1),
        .scale_CONV2    (inf.scale_CONV2),
        .scale_CONV3    (inf.scale_CONV3),
        .scale_FC1      (inf.scale_FC1),
        .scale_FC2(inf.scale_FC2),

        // Weight SRAM
        .sram_weight_wea0  (inf.sram_weight_wea0),
        .sram_weight_addr0 (inf.sram_weight_addr0),
        .sram_weight_wdata0(inf.sram_weight_wdata0),
        .sram_weight_rdata0(inf.sram_weight_rdata0),

        .sram_weight_wea1  (inf.sram_weight_wea1),
        .sram_weight_addr1 (inf.sram_weight_addr1),
        .sram_weight_wdata1(inf.sram_weight_wdata1),
        .sram_weight_rdata1(inf.sram_weight_rdata1),

        // Activation SRAM
        .sram_act_wea0     (inf.sram_act_wea0),
        .sram_act_addr0    (inf.sram_act_addr0),
        .sram_act_wdata0   (inf.sram_act_wdata0),
        .sram_act_rdata0   (inf.sram_act_rdata0),

        .sram_act_wea1     (inf.sram_act_wea1),
        .sram_act_addr1    (inf.sram_act_addr1),
        .sram_act_wdata1   (inf.sram_act_wdata1),
        .sram_act_rdata1   (inf.sram_act_rdata1)
        );



    // SRAM Models 也連到 inf 訊號
    SRAM_weight_16384x32b weight_sram( 
        .clk(inf.clk),
        .wea0(inf.sram_weight_wea0),
        .addr0(inf.sram_weight_addr0),
        .wdata0(inf.sram_weight_wdata0),
        .rdata0(inf.sram_weight_rdata0),
        .wea1(inf.sram_weight_wea1),
        .addr1(inf.sram_weight_addr1),
        .wdata1(inf.sram_weight_wdata1),
        .rdata1(inf.sram_weight_rdata1)
    );

    SRAM_activation_1024x32b act_sram( 
        .clk(inf.clk),
        .wea0(inf.sram_act_wea0),
        .addr0(inf.sram_act_addr0),
        .wdata0(inf.sram_act_wdata0),
        .rdata0(inf.sram_act_rdata0),
        .wea1(inf.sram_act_wea1),
        .addr1(inf.sram_act_addr1),
        .wdata1(inf.sram_act_wdata1),
        .rdata1(inf.sram_act_rdata1)
    );

    initial begin
        `ifdef GATESIM
            $fsdbDumpfile("lenet_syn.fsdb");
            $fsdbDumpvars(0, tb_top);
            $fsdbDumpMDA(0, tb_top);
            $sdf_annotate("../syn/netlist/lenet_syn.sdf", u_dut);
        `else
            $fsdbDumpfile("lenet.fsdb");
            $fsdbDumpvars(0, tb_top);
            $fsdbDumpMDA(0, tb_top);
        `endif
    end
endmodule