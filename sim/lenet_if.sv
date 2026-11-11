interface lenet_if (
    input logic clk
);

    timeunit 1ns; timeprecision 1ps;

    // ====================================
    // Control
    // ====================================
    logic rst_n;
    logic compute_start;
    logic compute_finish;

    // ====================================
    // Quantization Scale
    // ====================================
    logic [31:0] scale_CONV1;
    logic [31:0] scale_CONV2;
    logic [31:0] scale_CONV3;
    logic [31:0] scale_FC1;
    logic [31:0] scale_FC2;

    // ====================================
    // Weight SRAM
    // ====================================
    logic [3:0] sram_weight_wea0;
    logic [15:0] sram_weight_addr0;
    logic [31:0] sram_weight_wdata0;
    logic [31:0] sram_weight_rdata0;

    logic [3:0] sram_weight_wea1;
    logic [15:0] sram_weight_addr1;
    logic [31:0] sram_weight_wdata1;
    logic [31:0] sram_weight_rdata1;

    // ====================================
    // Activation SRAM
    // ====================================
    logic [3:0] sram_act_wea0;
    logic [15:0] sram_act_addr0;
    logic [31:0] sram_act_wdata0;
    logic [31:0] sram_act_rdata0;

    logic [3:0] sram_act_wea1;
    logic [15:0] sram_act_addr1;
    logic [31:0] sram_act_wdata1;
    logic [31:0] sram_act_rdata1;

    // ====================================
    // Testbench Clocking Block
    // ====================================
    clocking cb @(posedge clk);
        default input #1step output #1ns;

        output compute_start;
        input compute_finish;
    endclocking

    // ====================================
    // Test Modport
    // ====================================
    modport test(
        input clk,
        output rst_n,
        output scale_CONV1,
        output scale_CONV2,
        output scale_CONV3,
        output scale_FC1,
        output scale_FC2, 
        clocking cb);

    // ====================================
    // DUT Modport
    // ====================================
    modport dut(
        input clk,
        input rst_n,
        input compute_start,

        input scale_CONV1,
        input scale_CONV2,
        input scale_CONV3,
        input scale_FC1,
        input scale_FC2,

        output compute_finish,

        output sram_weight_wea0,
        output sram_weight_addr0,
        output sram_weight_wdata0,
        input sram_weight_rdata0,

        output sram_weight_wea1,
        output sram_weight_addr1,
        output sram_weight_wdata1,
        input sram_weight_rdata1,

        output sram_act_wea0,
        output sram_act_addr0,
        output sram_act_wdata0,
        input sram_act_rdata0,

        output sram_act_wea1,
        output sram_act_addr1,
        output sram_act_wdata1,
        input sram_act_rdata1
    );

endinterface
