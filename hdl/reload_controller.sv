module reload_controller (
    input logic clk,
    input logic rst_n,
    input logic reload_en,

    output logic        reload_we,
    output logic [ 6:0] reload_waddr,
    output logic [63:0] reload_wdata,  // 兩個 SRAM Port 組成的 64-bit 資料
    output logic [ 7:0] reload_wstrb,  // 8-bit Byte Enable，最後一組只啟用低四個 Bytes
    output logic        reload_done,


    output logic [ 3:0] sram_act_wea0,
    output logic [15:0] sram_act_addr0,
    input  logic [31:0] sram_act_rdata0,

    output logic [ 3:0] sram_act_wea1,
    output logic [15:0] sram_act_addr1,
    input  logic [31:0] sram_act_rdata1

);
    logic [31:0] sram_act_rdata0_buf;
    logic [31:0] sram_act_rdata1_buf;


    logic [16:0] act_idx;
    logic [16:0] act_0_idex;
    logic [16:0] act_1_idex;

    logic reload_en_reg;
    logic vector_read_fire;

    logic load_valid_s2;
    logic load_valid_s3;
    logic load_valid_s4;

    logic [16:0] load_idx_s2;
    logic [16:0] load_idx_s3;
    logic [16:0] load_idx_s4;

    localparam shortint fc2_in_offset = 16'd722;

    assign vector_read_fire = reload_en_reg && (act_idx < 17'd11);

    always_ff @(posedge clk or negedge rst_n) begin : unused_sram_we
        if (!rst_n) begin
            sram_act_wea0 <= 4'd0;
            sram_act_wea1 <= 4'd0;
        end else begin
            sram_act_wea0 <= 4'd0;
            sram_act_wea1 <= 4'd0;
        end

    end

    always_ff @(posedge clk or negedge rst_n) begin : reload_en_ff
        if (!rst_n) reload_en_reg <= 1'b0;
        else reload_en_reg <= reload_en && !reload_done;
    end : reload_en_ff

    always_ff @(posedge clk or negedge rst_n) begin : input_buffer
        if (!rst_n) begin
            sram_act_rdata0_buf <= 32'd0;
            sram_act_rdata1_buf <= 32'd0;

        end else begin
            sram_act_rdata0_buf <= sram_act_rdata0;
            sram_act_rdata1_buf <= sram_act_rdata1;
        end
    end : input_buffer


    assign act_0_idex = {act_idx, 1'b0};
    assign act_1_idex = {act_idx, 1'b1};
    always_ff @(posedge clk or negedge rst_n) begin : act_addr_gen
        if (!rst_n) begin
            sram_act_addr0 <= '0;
            sram_act_addr1 <= '0;
        end else if (vector_read_fire) begin
            sram_act_addr0 <= fc2_in_offset + act_0_idex;
            sram_act_addr1 <= fc2_in_offset + act_1_idex;
        end else begin
            sram_act_addr0 <= sram_act_addr0;
            sram_act_addr1 <= sram_act_addr1;
        end
    end : act_addr_gen

    always_ff @(posedge clk or negedge rst_n) begin : act_read_idx_ff
        if (!rst_n) begin
            act_idx <= 17'd0;
        end else if (!reload_en_reg) begin
            act_idx <= 17'd0;
        end else if (vector_read_fire) begin
            act_idx <= act_idx + 1'b1;
        end else begin
            act_idx <= act_idx;
        end
    end : act_read_idx_ff

    always_ff @(posedge clk or negedge rst_n) begin : load_valid_pipeline
        if (!rst_n) begin
            load_valid_s2 <= 1'b0;
            load_valid_s3 <= 1'b0;
            load_valid_s4 <= 1'b0;
        end else begin
            load_valid_s2 <= vector_read_fire;
            load_valid_s3 <= load_valid_s2;
            load_valid_s4 <= load_valid_s3;
        end
    end : load_valid_pipeline

    always_ff @(posedge clk or negedge rst_n) begin : load_idx_pipeline
        if (!rst_n) begin
            load_idx_s2 <= '0;
            load_idx_s3 <= '0;
            load_idx_s4 <= '0;
        end else begin
            load_idx_s2 <= act_idx;
            load_idx_s3 <= load_idx_s2;
            load_idx_s4 <= load_idx_s3;
        end
    end : load_idx_pipeline

    always_ff @(posedge clk or negedge rst_n) begin : reload_buf
        if (!rst_n) begin
            reload_we    <= 1'b0;
            reload_waddr <= 7'd0;
            reload_wdata <= 64'd0;
            reload_wstrb <= 8'd0;
        end else if (load_valid_s4) begin
            reload_we    <= 1'b1;
            reload_waddr <= load_idx_s4 * 8;
            reload_wdata <= {sram_act_rdata1_buf, sram_act_rdata0_buf};
            reload_wstrb <= (load_idx_s4 == 'd10)? 8'h0F:8'hFF;
        end else begin
            reload_we    <= 1'b0;
            reload_waddr <= reload_waddr;
            reload_wdata <= reload_wdata;
            reload_wstrb <= 8'd0;
        end
    end : reload_buf

    always_ff @(posedge clk or negedge rst_n) begin : act_load_done_ff
        if (!rst_n) begin
            reload_done <= 1'b0;
        end else begin
            reload_done <= reload_we && (reload_waddr == 7'd80) && (reload_wstrb == 8'h0F);
        end
    end : act_load_done_ff

endmodule
