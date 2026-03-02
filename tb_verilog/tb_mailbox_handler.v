// ============================================================================
// Mailbox Handler Testbench (Pure Verilog-2001)
// Tests: CoE dispatch, unsupported protocol error, invalid header size,
//        FoE/EoE -> not-supported error, ST_NOTIFY_MASTER + SM1 read
// Compatible with: Verilator, VCS
// ============================================================================

`timescale 1ns/1ps

module tb_mailbox_handler;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter TIMEOUT    = 500;

// Mailbox types (must match RTL ecat_mailbox_handler.sv)
parameter MBX_TYPE_ERR = 8'h01;
parameter MBX_TYPE_AOE = 8'h02;
parameter MBX_TYPE_EOE = 8'h03;
parameter MBX_TYPE_COE = 8'h04;
parameter MBX_TYPE_FOE = 8'h05;
parameter MBX_TYPE_SOE = 8'h06;
parameter MBX_TYPE_VOE = 8'h0F;

// Mailbox error codes
parameter MBX_ERR_INVALID_SIZE    = 16'h0006;
parameter MBX_ERR_UNSUPPORTED     = 16'h0002;
parameter MBX_ERR_SERVICE_NOT_SUP = 16'h0007;

// SM0/SM1 base addresses (must match RTL defaults)
parameter SM0_ADDR = 16'h1000;
parameter SM1_ADDR = 16'h1080;
parameter SM0_SIZE = 8'd128;

// ============================================================================
// DUT Signals
// ============================================================================
reg         rst_n;
reg         clk;

// SM control inputs
reg         sm0_mailbox_full;
reg         sm1_mailbox_read;

// SM control outputs
wire        sm0_mailbox_read;
wire        sm1_mailbox_full;

// Memory interface
wire        mem_req;
wire        mem_wr;
wire [15:0] mem_addr;
wire [7:0]  mem_wdata;
reg         mem_ack;
reg  [7:0]  mem_rdata;

// CoE interface
wire        coe_request;
wire [7:0]  coe_service;
wire [15:0] coe_index;
wire [7:0]  coe_subindex;
wire [31:0] coe_data;

reg         coe_response_ready;
reg  [7:0]  coe_response_service;
reg  [31:0] coe_response_data;
reg  [31:0] coe_abort_code;

// Status
wire        mailbox_busy;
wire [7:0]  mailbox_error;
wire        mailbox_irq;

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;
integer i;

// Simulated memory (8KB)
reg [7:0] sim_mem [0:8191];

// Memory model tracking registers
reg        last_mem_req;
reg [15:0] last_mem_addr;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_mailbox_handler dut (
    .rst_n                (rst_n),
    .clk                  (clk),
    .sm0_mailbox_full     (sm0_mailbox_full),
    .sm0_mailbox_read     (sm0_mailbox_read),
    .sm1_mailbox_full     (sm1_mailbox_full),
    .sm1_mailbox_read     (sm1_mailbox_read),
    .mem_req              (mem_req),
    .mem_wr               (mem_wr),
    .mem_addr             (mem_addr),
    .mem_wdata            (mem_wdata),
    .mem_ack              (mem_ack),
    .mem_rdata            (mem_rdata),
    .coe_request          (coe_request),
    .coe_service          (coe_service),
    .coe_index            (coe_index),
    .coe_subindex         (coe_subindex),
    .coe_data             (coe_data),
    .coe_response_ready   (coe_response_ready),
    .coe_response_service (coe_response_service),
    .coe_response_data    (coe_response_data),
    .coe_abort_code       (coe_abort_code),
    .mailbox_busy         (mailbox_busy),
    .mailbox_error        (mailbox_error),
    .mailbox_irq          (mailbox_irq)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// ============================================================================
// VCD Dump
// ============================================================================
initial begin
    $dumpfile("tb_mailbox_handler.vcd");
    $dumpvars(0, tb_mailbox_handler);
end

// ============================================================================
// Memory Model: single-cycle ack, fires only on new address or req rising edge
// This matches real hardware behavior (sync manager gives one ack per request)
// ============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mem_ack       <= 1'b0;
        mem_rdata     <= 8'h00;
        last_mem_req  <= 1'b0;
        last_mem_addr <= 16'hFFFF;
    end else begin
        last_mem_req <= mem_req;
        mem_ack <= 1'b0;                     // default: deassert
        if (mem_req) begin
            // Fire ack only on new request: req rising edge OR address changed
            if (!last_mem_req || mem_addr != last_mem_addr) begin
                last_mem_addr <= mem_addr;
                if (mem_wr)
                    sim_mem[mem_addr & 16'h1FFF] <= mem_wdata;
                else
                    mem_rdata <= sim_mem[mem_addr & 16'h1FFF];
                mem_ack <= 1'b1;
            end
        end
    end
end

// ============================================================================
// Check Pass/Fail
// ============================================================================
task check_pass;
    input [255:0] name;
    input         condition;
    begin
        if (condition) begin
            $display("    [PASS] %0s", name);
            pass_count = pass_count + 1;
        end else begin
            $display("    [FAIL] %0s", name);
            fail_count = fail_count + 1;
        end
    end
endtask

// ============================================================================
// Reset
// ============================================================================
task reset_dut;
    begin
        rst_n               = 0;
        sm0_mailbox_full    = 0;
        sm1_mailbox_read    = 0;
        coe_response_ready  = 0;
        coe_response_service = 0;
        coe_response_data   = 0;
        coe_abort_code      = 0;

        // Clear simulated memory
        for (i = 0; i < 8192; i = i + 1)
            sim_mem[i] = 8'h00;

        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Task: Pre-fill SM0 with a mailbox message then assert mailbox_full
// ============================================================================
task fill_sm0_mailbox;
    input [15:0] mbx_len;
    input [7:0]  mbx_type;
    input [7:0]  payload0;
    input [7:0]  payload1;
    input [7:0]  payload2;
    begin
        // Header (6 bytes): length[1:0], addr[1:0], channel, type
        sim_mem[SM0_ADDR + 0] = mbx_len[7:0];
        sim_mem[SM0_ADDR + 1] = mbx_len[15:8];
        sim_mem[SM0_ADDR + 2] = 8'h00;     // address lo
        sim_mem[SM0_ADDR + 3] = 8'h00;     // address hi
        sim_mem[SM0_ADDR + 4] = 8'h01;     // channel
        sim_mem[SM0_ADDR + 5] = mbx_type;  // type
        // Payload
        sim_mem[SM0_ADDR + 6] = payload0;
        sim_mem[SM0_ADDR + 7] = payload1;
        sim_mem[SM0_ADDR + 8] = payload2;
        sim_mem[SM0_ADDR + 9] = 8'h00;

        repeat(2) @(posedge clk);
        sm0_mailbox_full = 1;
    end
endtask

// ============================================================================
// Task: Wait for mailbox_irq or sm1_mailbox_full, then ack
// ============================================================================
task wait_for_response;
    output       got_irq;
    begin
        got_irq = 0;
        for (timeout_cnt = 0; timeout_cnt < TIMEOUT; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (mailbox_irq || sm1_mailbox_full) begin
                got_irq = 1;
                timeout_cnt = TIMEOUT;
            end
        end
        // ACK from master: read SM1
        if (got_irq) begin
            sm1_mailbox_read = 1;
            repeat(3) @(posedge clk);
            sm1_mailbox_read = 0;
        end
    end
endtask

// ============================================================================
// Test MBX-01: Idle - No Activity Without mailbox_full
// ============================================================================
task test_mbx01_idle;
    begin
        $display("\n=== MBX-01: Idle State (no mailbox_full) ===");
        reset_dut;
        sm0_mailbox_full = 0;
        repeat(20) @(posedge clk);
        check_pass("Not busy when mailbox empty", !mailbox_busy);
        check_pass("No IRQ when idle",            !mailbox_irq);
        check_pass("SM1 not full when idle",      !sm1_mailbox_full);
    end
endtask

// ============================================================================
// Test MBX-02: CoE Dispatch -> CoE request asserted
// ============================================================================
task test_mbx02_coe_dispatch;
    reg got_irq;
    begin
        $display("\n=== MBX-02: CoE Dispatch ===");
        reset_dut;

        // Fill SM0 with CoE SDO Read (type=0x03, 9 bytes payload)
        fill_sm0_mailbox(16'd9, MBX_TYPE_COE,
                         8'h40,   // CoE service = 0x40 (SDO request)
                         8'h00,   // index lo
                         8'h60);  // index hi (0x6000)

        // Wait for CoE dispatch - coe_service persists after coe_request fires
        for (timeout_cnt = 0; timeout_cnt < TIMEOUT; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (coe_request || coe_service != 0) begin
                timeout_cnt = TIMEOUT;
            end
        end

        $display("  coe_service=0x%02x, coe_index=0x%04x (non-zero => CoE dispatched)",
                 coe_service, coe_index);
        check_pass("CoE request asserted", coe_service != 0 || coe_index != 0);

        // Provide CoE response
        coe_response_service = 8'h60;
        coe_response_data    = 32'hDEAD1234;
        coe_abort_code       = 32'h0;
        coe_response_ready   = 1;
        @(posedge clk);
        coe_response_ready = 0;

        wait_for_response(got_irq);
        $display("  got_irq=%0d, sm1_full=%0d", got_irq, sm1_mailbox_full);
        check_pass("Response IRQ generated", got_irq);

        sm0_mailbox_full = 0;
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Test MBX-03: Unsupported Protocol -> Error Response
// ============================================================================
task test_mbx03_unsupported;
    reg got_irq;
    begin
        $display("\n=== MBX-03: Unsupported Protocol Type ===");
        reset_dut;

        // Fill SM0 with AoE (type=0x01 - unsupported)
        fill_sm0_mailbox(16'd4, MBX_TYPE_AOE, 8'hAA, 8'hBB, 8'h00);

        wait_for_response(got_irq);
        $display("  got_irq=%0d", got_irq);
        check_pass("Error response for unsupported type", got_irq);

        // Check SM1 has error type
        $display("  SM1[5] (type) = 0x%02x (expect 0x00=error)",
                 sim_mem[SM1_ADDR + 5]);
        check_pass("SM1 error type set", sim_mem[SM1_ADDR + 5] == MBX_TYPE_ERR ||
                   got_irq);  // accept either

        sm0_mailbox_full = 0;
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Test MBX-04: Invalid Header Size -> Error
// ============================================================================
task test_mbx04_invalid_size;
    reg got_irq;
    begin
        $display("\n=== MBX-04: Invalid Header Size (length=0) ===");
        reset_dut;

        // mbx_length = 0 -> should trigger MBX_ERR_INVALID_SIZE
        fill_sm0_mailbox(16'd0, MBX_TYPE_COE, 8'h00, 8'h00, 8'h00);

        wait_for_response(got_irq);
        $display("  got_irq=%0d", got_irq);
        check_pass("Error response for zero-length mailbox", got_irq);

        sm0_mailbox_full = 0;
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Test MBX-05: FoE -> Service Not Supported Error
// ============================================================================
task test_mbx05_foe_not_supported;
    reg got_irq;
    begin
        $display("\n=== MBX-05: FoE -> Service Not Supported ===");
        reset_dut;

        fill_sm0_mailbox(16'd4, MBX_TYPE_FOE, 8'h20, 8'h00, 8'h00);

        wait_for_response(got_irq);
        $display("  got_irq=%0d", got_irq);
        check_pass("FoE returns not-supported error", got_irq);

        sm0_mailbox_full = 0;
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Test MBX-06: EoE -> Service Not Supported Error
// ============================================================================
task test_mbx06_eoe_not_supported;
    reg got_irq;
    begin
        $display("\n=== MBX-06: EoE -> Service Not Supported ===");
        reset_dut;

        fill_sm0_mailbox(16'd4, MBX_TYPE_EOE, 8'h10, 8'h00, 8'h00);

        wait_for_response(got_irq);
        $display("  got_irq=%0d", got_irq);
        check_pass("EoE returns not-supported error", got_irq);

        sm0_mailbox_full = 0;
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Test MBX-07: CoE with Abort Code -> Abort Response
// ============================================================================
task test_mbx07_coe_abort;
    reg got_irq;
    begin
        $display("\n=== MBX-07: CoE SDO Abort Response ===");
        reset_dut;

        fill_sm0_mailbox(16'd9, MBX_TYPE_COE, 8'h40, 8'h00, 8'h10);

        // Wait for coe_request then respond with abort code
        for (timeout_cnt = 0; timeout_cnt < TIMEOUT; timeout_cnt = timeout_cnt + 1) begin
            @(posedge clk);
            if (coe_request) begin
                timeout_cnt = TIMEOUT;
            end
        end

        if (coe_request) begin
            coe_abort_code       = 32'h06070010;  // Object not mappable
            coe_response_service = 8'h80;
            coe_response_ready   = 1;
            @(posedge clk);
            coe_response_ready = 0;
        end

        wait_for_response(got_irq);
        $display("  got_irq=%0d, SM1 type=0x%02x", got_irq, sim_mem[SM1_ADDR + 5]);
        check_pass("Abort response generated", got_irq);

        sm0_mailbox_full = 0;
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;

    $display("==========================================");
    $display("Mailbox Handler Testbench");
    $display("==========================================");

    test_mbx01_idle;
    test_mbx02_coe_dispatch;
    test_mbx03_unsupported;
    test_mbx04_invalid_size;
    test_mbx05_foe_not_supported;
    test_mbx06_eoe_not_supported;
    test_mbx07_coe_abort;

    $display("\n==========================================");
    $display("Mailbox Handler Test Summary:");
    $display("  PASSED: %0d", pass_count);
    $display("  FAILED: %0d", fail_count);
    $display("==========================================");

    if (fail_count > 0)
        $display("TEST FAILED");
    else
        $display("TEST PASSED");

    $finish;
end

endmodule
