module test (
    lenet_if.test vif
);

    timeunit 1ns; timeprecision 1ps;

    localparam int MAX_CYCLES = 50000;

    logic [31:0] golden[0:752];

    // ------------------------------------
    // Golden Checker
    // ------------------------------------
    task automatic check_layer(input string layer_name, input int first_addr, input int last_addr,
                               inout int total_errors);
        int errors = 0;

        $display("");
        $display("  +---------------- CHECK %-6s ----------------+", layer_name);
        $display("  | Address range : %0d - %0d", first_addr, last_addr);

        for (int i = first_addr; i <= last_addr; i++) begin
            if (tb_top.act_sram.RAM[i] !== golden[i]) begin

                if (errors < 5)
                    $display(
                        "  | [ERROR] %-6s addr=%0d expected=%08h actual=%08h",
                        layer_name,
                        i,
                        golden[i],
                        tb_top.act_sram.RAM[i]
                    );

                errors++;
            end
        end

        total_errors += errors;

        if (errors == 0)
            $display("  + %-6s : PASS", layer_name);
        else
            $display("  + %-6s : FAIL (%0d mismatches)", layer_name, errors);

        $display("  +------------------------------------------------+");
    endtask

    // ------------------------------------
    // Test Sequence
    // ------------------------------------
    initial begin : test_sequence

        int cycles;
        int total_errors;

        // Initialize controls
        vif.rst_n = 1'b0;

        // Must match the selected Golden pattern
        vif.scale_CONV1 = 32'd114;
        vif.scale_CONV2 = 32'd83;
        vif.scale_CONV3 = 32'd347;
        vif.scale_FC1 = 32'd403;
        vif.scale_FC2 = 32'd208;

        // Load SRAM and Golden
        tb_top.weight_sram.load_data("../pattern/weights/weights.csv");

        tb_top.act_sram.load_data("../pattern/patterns/image.csv");

        $readmemh("../pattern/patterns/golden.csv", golden);

        // Initialize clocking output
        @(vif.cb);
        vif.cb.compute_start <= 1'b0;

        // Reset
        repeat (3) @(negedge vif.clk);
        vif.rst_n = 1'b1;

        // Start inference
        @(vif.cb);
        vif.cb.compute_start <= 1'b1;

        @(vif.cb);
        vif.cb.compute_start <= 1'b0;

        // Wait for completion
        cycles = 0;

        do begin
            @(vif.cb);
            cycles++;

            if (cycles >= MAX_CYCLES) $fatal(1, "Simulation timeout");

        end while (vif.cb.compute_finish !== 1'b1);

        $display("");
        $display("====================================================");
        $display("                 INFERENCE COMPLETE");
        $display("====================================================");
        $display("  Observed cycles : %0d", cycles);

        // Allow final delayed SRAM writes to settle
        @(negedge vif.clk);
        #1ps;

        // Check all layers
        total_errors = 0;

        check_layer("IMAGE", 0, 255, total_errors);
        check_layer("CONV1", 256, 591, total_errors);
        check_layer("CONV2", 592, 691, total_errors);
        check_layer("CONV3", 692, 721, total_errors);
        check_layer("FC1", 722, 742, total_errors);
        check_layer("FC2", 743, 752, total_errors);

        $display("");
        $display("====================================================");
        $display("                   TEST SUMMARY");
        $display("====================================================");

        if (total_errors == 0) begin
            $display("  Result : ALL TESTS PASS");
            $display("====================================================");
            $finish;
        end else begin
            $display("  Result : TEST FAILED");
            $display("  Errors : %0d", total_errors);
            $display("====================================================");
            $fatal(1, "TEST FAILED: %0d errors", total_errors);
        end
    end

endmodule
