// ============================================================================
// Frame Transmitter Testbench (Pure Verilog-2001)
// Tests: state machine flow, no-link handling, multi-port, data injection
// Compatible with: Verilator, VCS
// ============================================================================

`timescale 1ns/1ps

module tb_frame_transmitter;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter TIMEOUT    = 500;

// ============================================================================
// DUT Signals
// ============================================================================
reg         rst_n;
reg         clk;

// Forward input (frame source)
reg         fwd_valid;
reg  [7:0]  fwd_data;
reg         fwd_sof;
reg         fwd_eof;
reg         fwd_modified;
reg  [3:0]  fwd_from_port;

// Data injection
reg         inject_enable;
reg  [10:0] inject_offset;
reg  [7:0]  inject_data;

// Port control
reg  [3:0]  port_enable;
reg  [3:0]  port_link_status;

// PHY TX interface
wire        tx_valid;
wire [7:0]  tx_data;
wire        tx_sof;
wire        tx_eof;
wire [3:0]  port_id;
reg         tx_ready;

// Statistics
wire [15:0] tx_frame_count;
wire [15:0] tx_error_count;

// Test counters
integer pass_count;
integer fail_count;
integer i;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_frame_transmitter dut (
    .rst_n            (rst_n),
    .clk              (clk),
    .fwd_valid        (fwd_valid),
    .fwd_data         (fwd_data),
    .fwd_sof          (fwd_sof),
    .fwd_eof          (fwd_eof),
    .fwd_modified     (fwd_modified),
    .fwd_from_port    (fwd_from_port),
    .inject_enable    (inject_enable),
    .inject_offset    (inject_offset),
    .inject_data      (inject_data),
    .port_enable      (port_enable),
    .port_link_status (port_link_status),
    .port_id          (port_id),
    .tx_valid         (tx_valid),
    .tx_data          (tx_data),
    .tx_sof           (tx_sof),
    .tx_eof           (tx_eof),
    .tx_ready         (tx_ready),
    .tx_frame_count   (tx_frame_count),
    .tx_error_count   (tx_error_count)
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
    $dumpfile("tb_frame_transmitter.vcd");
    $dumpvars(0, tb_frame_transmitter);
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
        rst_n         = 0;
        fwd_valid     = 0;
        fwd_data      = 0;
        fwd_sof       = 0;
        fwd_eof       = 0;
        fwd_modified  = 0;
        fwd_from_port = 4'h0;
        inject_enable = 0;
        inject_offset = 0;
        inject_data   = 0;
        port_enable   = 4'hF;
        port_link_status = 4'hF;
        tx_ready      = 1;

        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete, tx_frame_count=%0d", tx_frame_count);
    end
endtask

// ============================================================================
// Task: Trigger a 1-byte frame via fwd interface and wait for completion
// Returns: whether tx_sof was seen and tx_frame_count incremented
// ============================================================================
task send_fwd_frame;
    input [7:0]  byte0;
    input [3:0]  from_port;
    output       saw_sof;
    output       saw_eof;
    reg [15:0]   cnt_before;
    begin
        cnt_before = tx_frame_count;
        saw_sof    = 0;
        saw_eof    = 0;

        // SOF byte
        @(posedge clk);
        fwd_valid     = 1;
        fwd_sof       = 1;
        fwd_eof       = 1;   // single-byte frame
        fwd_data      = byte0;
        fwd_from_port = from_port;
        @(posedge clk);
        fwd_valid = 0;
        fwd_sof   = 0;
        fwd_eof   = 0;

        // Wait for tx_sof (up to TIMEOUT cycles)
        for (i = 0; i < TIMEOUT; i = i + 1) begin
            @(posedge clk);
            if (tx_sof && tx_valid) saw_sof = 1;
            if (tx_eof && tx_valid) saw_eof = 1;
        end
    end
endtask

// ============================================================================
// Test TX-01: Basic State Machine Flow (IDLE->WAIT_READY->TRANSMIT->FCS->DONE)
// ============================================================================
task test_tx01_basic_flow;
    reg saw_sof, saw_eof;
    reg [15:0] cnt_before;
    begin
        $display("\n=== TX-01: Basic Frame Transmission ===");
        reset_dut;
        cnt_before = tx_frame_count;

        // Single port enabled (port 1 only, coming from port 0)
        port_enable      = 4'b0010;
        port_link_status = 4'b1111;
        tx_ready         = 1;

        send_fwd_frame(8'hAB, 4'h0, saw_sof, saw_eof);

        $display("  saw_sof=%0d, saw_eof=%0d, tx_frame_count=%0d",
                 saw_sof, saw_eof, tx_frame_count);
        check_pass("TX SOF asserted", saw_sof);
        check_pass("TX EOF asserted", saw_eof);
        check_pass("Frame count incremented", tx_frame_count > cnt_before);
    end
endtask

// ============================================================================
// Test TX-02: No Valid Port -> Frame Dropped (WAIT_READY -> IDLE)
// ============================================================================
task test_tx02_no_port;
    reg saw_sof, saw_eof;
    reg [15:0] cnt_before;
    begin
        $display("\n=== TX-02: No Valid Output Port ===");
        reset_dut;
        cnt_before = tx_frame_count;

        // Source from port 0, only port 0 enabled -> excluded (same port)
        port_enable      = 4'b0001;
        port_link_status = 4'b1111;
        tx_ready         = 1;

        send_fwd_frame(8'hCD, 4'h0, saw_sof, saw_eof);

        $display("  saw_sof=%0d (should be 0), tx_frame_count=%0d", saw_sof, tx_frame_count);
        check_pass("No TX when all ports excluded", !saw_sof);
        check_pass("Frame count not incremented", tx_frame_count == cnt_before);
    end
endtask

// ============================================================================
// Test TX-03: TX Not Ready (tx_ready=0 delays transmission)
// ============================================================================
task test_tx03_tx_not_ready;
    reg saw_sof, saw_eof;
    reg [15:0] cnt_before;
    begin
        $display("\n=== TX-03: TX Ready Gating ===");
        reset_dut;
        cnt_before = tx_frame_count;

        port_enable      = 4'b1110;
        port_link_status = 4'b1111;
        tx_ready         = 0;  // Not ready initially

        // Trigger frame
        @(posedge clk);
        fwd_valid     = 1;
        fwd_sof       = 1;
        fwd_eof       = 1;
        fwd_data      = 8'hEF;
        fwd_from_port = 4'h0;
        @(posedge clk);
        fwd_valid = 0; fwd_sof = 0; fwd_eof = 0;

        // Hold not-ready for 20 cycles - no TX should happen
        repeat(20) @(posedge clk);
        check_pass("No TX while not ready", !tx_valid);

        // Now assert ready
        tx_ready = 1;
        saw_sof = 0; saw_eof = 0;
        for (i = 0; i < TIMEOUT; i = i + 1) begin
            @(posedge clk);
            if (tx_sof && tx_valid) saw_sof = 1;
            if (tx_eof && tx_valid) saw_eof = 1;
        end

        $display("  After ready: saw_sof=%0d, tx_frame_count=%0d", saw_sof, tx_frame_count);
        check_pass("TX starts after ready asserted", saw_sof);
    end
endtask

// ============================================================================
// Test TX-04: Data Injection
// ============================================================================
task test_tx04_injection;
    reg saw_sof, saw_eof;
    begin
        $display("\n=== TX-04: Data Injection ===");
        reset_dut;

        port_enable      = 4'b0010;
        port_link_status = 4'b1111;
        tx_ready         = 1;
        inject_enable    = 1;
        inject_offset    = 11'd0;
        inject_data      = 8'h42;   // injected byte

        send_fwd_frame(8'hFF, 4'h0, saw_sof, saw_eof);

        $display("  saw_sof=%0d (injection active)", saw_sof);
        check_pass("Injection test: TX SOF seen", saw_sof);
        inject_enable = 0;
    end
endtask

// ============================================================================
// Test TX-05: Frame Count Increments Per Frame
// ============================================================================
task test_tx05_frame_count;
    reg saw_sof, saw_eof;
    reg [15:0] cnt_start;
    integer k;
    begin
        $display("\n=== TX-05: Frame Count Per Transmission ===");
        reset_dut;
        cnt_start = tx_frame_count;
        port_enable = 4'b0010; port_link_status = 4'b1111; tx_ready = 1;

        for (k = 0; k < 3; k = k + 1)
            send_fwd_frame(8'h10 + k, 4'h0, saw_sof, saw_eof);

        $display("  Frame count: %0d -> %0d (expected +3)", cnt_start, tx_frame_count);
        check_pass("Frame count incremented 3 times", tx_frame_count >= cnt_start + 3);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;

    $display("==========================================");
    $display("Frame Transmitter Testbench");
    $display("==========================================");

    test_tx01_basic_flow;
    test_tx02_no_port;
    test_tx03_tx_not_ready;
    test_tx04_injection;
    test_tx05_frame_count;

    $display("\n==========================================");
    $display("Frame Transmitter Test Summary:");
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
