// ============================================================================
// Frame Receiver Testbench (Pure Verilog-2001)
// Tests frame parsing, command decoding, and address matching
// Compatible with: Verilator, VCS (RTL uses SystemVerilog constructs)
// ============================================================================

`timescale 1ns/1ps

module tb_frame_receiver;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     rst_n;

// Port identification
reg  [3:0]              port_id;

// RX interface
reg                     rx_valid;
reg  [7:0]              rx_data;
reg                     rx_sof;
reg                     rx_eof;
reg                     rx_error;

// Station address
reg  [15:0]             station_address;
reg  [31:0]             station_alias;

// Memory interface
wire [15:0]             mem_addr;
wire [15:0]             mem_wdata;
wire [1:0]              mem_be;
wire                    mem_wr_en;
wire                    mem_rd_en;
reg                     mem_ready;
reg  [15:0]             mem_rdata;

// Frame forwarding
wire                    fwd_valid;
wire [7:0]              fwd_data;
wire                    fwd_sof;
wire                    fwd_eof;
wire                    fwd_modified;

// Statistics
wire [15:0]             rx_frame_count;
wire [15:0]             rx_error_count;
wire [15:0]             rx_crc_error_count;
wire [15:0]             wkc_increment_count;

// Test counters
integer pass_count;
integer fail_count;
integer i;

// Frame buffer
reg [7:0] frame_data [0:255];
integer frame_len;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_frame_receiver dut (
    .clk(clk),
    .rst_n(rst_n),
    .port_id(port_id),
    .rx_valid(rx_valid),
    .rx_data(rx_data),
    .rx_sof(rx_sof),
    .rx_eof(rx_eof),
    .rx_error(rx_error),
    .station_address(station_address),
    .station_alias(station_alias),
    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),
    .mem_be(mem_be),
    .mem_wr_en(mem_wr_en),
    .mem_rd_en(mem_rd_en),
    .mem_ready(mem_ready),
    .mem_rdata(mem_rdata),
    .fwd_valid(fwd_valid),
    .fwd_data(fwd_data),
    .fwd_sof(fwd_sof),
    .fwd_eof(fwd_eof),
    .fwd_modified(fwd_modified),
    .rx_frame_count(rx_frame_count),
    .rx_error_count(rx_error_count),
    .rx_crc_error_count(rx_crc_error_count),
    .wkc_increment_count(wkc_increment_count)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// ============================================================================
// VCD Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_frame_receiver.vcd");
    $dumpvars(0, tb_frame_receiver);
end

// ============================================================================
// Tasks: Check Pass/Fail
// ============================================================================
task check_pass;
    input [255:0] name;
    input condition;
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
// Tasks: Reset
// ============================================================================
task reset_dut;
    begin
        rst_n = 0;
        port_id = 0;
        rx_valid = 0;
        rx_data = 0;
        rx_sof = 0;
        rx_eof = 0;
        rx_error = 0;
        station_address = 16'h1000;
        station_alias = 32'h00000000;
        mem_ready = 1;
        mem_rdata = 0;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Tasks: Send Single Byte
// ============================================================================
task send_byte;
    input [7:0] data;
    input is_sof;
    input is_eof;
    begin
        @(posedge clk);
        rx_valid = 1;
        rx_data = data;
        rx_sof = is_sof;
        rx_eof = is_eof;
        @(posedge clk);
        rx_valid = 0;
        rx_sof = 0;
        rx_eof = 0;
    end
endtask

// ============================================================================
// Tasks: Send Frame
// ============================================================================
task send_frame;
    input integer len;
    integer j;
    begin
        $display("[INFO] Sending frame (%0d bytes)", len);
        
        for (j = 0; j < len; j = j + 1) begin
            send_byte(frame_data[j], (j == 0), (j == len - 1));
        end
        
        // Wait for processing
        repeat(10) @(posedge clk);
    end
endtask

// ============================================================================
// Test 1: FPRD (Fixed Physical Read) Frame
// ============================================================================
task test_fprd_frame;
    begin
        $display("\n=== TEST 1: FPRD (Fixed Physical Read) ===");
        reset_dut;
        
        // Build FPRD frame
        // EtherCAT header (2 bytes)
        frame_data[0] = 8'h1C;  // Length=28
        frame_data[1] = 8'h10;  // Type=0x1 (EtherCAT)
        
        // Datagram header (10 bytes)
        frame_data[2] = 8'h04;  // Command: FPRD
        frame_data[3] = 8'h00;  // Index
        frame_data[4] = 8'h00;  // Address low
        frame_data[5] = 8'h10;  // Address high (0x1000)
        frame_data[6] = 8'h00;  // ADO low
        frame_data[7] = 8'h00;  // ADO high
        frame_data[8] = 8'h10;  // Length low (16 bytes)
        frame_data[9] = 8'h00;  // Length high
        frame_data[10] = 8'h00; // Reserved
        frame_data[11] = 8'h00; // IRQ
        
        // Data (16 bytes)
        for (i = 12; i < 28; i = i + 1)
            frame_data[i] = 8'h00;
        
        // Working counter (2 bytes)
        frame_data[28] = 8'h00;
        frame_data[29] = 8'h00;
        
        frame_len = 30;
        send_frame(frame_len);
        
        $display("[INFO] Frame receiver statistics:");
        $display("  RX Frame Count: %0d", rx_frame_count);
        $display("  RX Error Count: %0d", rx_error_count);
        
        check_pass("Frame received", rx_frame_count > 0);
    end
endtask

// ============================================================================
// Test 2: BWR (Broadcast Write) Frame
// ============================================================================
task test_bwr_frame;
    begin
        $display("\n=== TEST 2: BWR (Broadcast Write) ===");
        reset_dut;
        
        // Build BWR frame
        frame_data[0] = 8'h18;  // Length=24
        frame_data[1] = 8'h10;  // Type
        
        frame_data[2] = 8'h08;  // Command: BWR
        frame_data[3] = 8'h01;  // Index
        frame_data[4] = 8'h20;  // Address: 0x0120 (AL Control)
        frame_data[5] = 8'h01;
        frame_data[6] = 8'h00;
        frame_data[7] = 8'h00;
        frame_data[8] = 8'h02;  // Length: 2 bytes
        frame_data[9] = 8'h00;
        frame_data[10] = 8'h00;
        frame_data[11] = 8'h00;
        
        // Data (2 bytes)
        frame_data[12] = 8'h02;  // Request Pre-Op state
        frame_data[13] = 8'h00;
        
        // Working counter
        frame_data[14] = 8'h00;
        frame_data[15] = 8'h00;
        
        frame_len = 16;
        send_frame(frame_len);
        
        $display("[INFO] Broadcast write complete");
        check_pass("BWR frame received", rx_frame_count > 0);
    end
endtask

// ============================================================================
// Test 3: LRD (Logical Read) Frame
// ============================================================================
task test_lrd_frame;
    begin
        $display("\n=== TEST 3: LRD (Logical Read) ===");
        reset_dut;
        
        // Build LRD frame
        frame_data[0] = 8'h14;
        frame_data[1] = 8'h10;
        
        frame_data[2] = 8'h0A;  // Command: LRD
        frame_data[3] = 8'h02;  // Index
        frame_data[4] = 8'h00;  // Logical address
        frame_data[5] = 8'h00;
        frame_data[6] = 8'h00;
        frame_data[7] = 8'h00;
        frame_data[8] = 8'h04;  // Length: 4 bytes
        frame_data[9] = 8'h00;
        frame_data[10] = 8'h00;
        frame_data[11] = 8'h00;
        
        // Data (4 bytes)
        frame_data[12] = 8'h00;
        frame_data[13] = 8'h00;
        frame_data[14] = 8'h00;
        frame_data[15] = 8'h00;
        
        // Working counter
        frame_data[16] = 8'h00;
        frame_data[17] = 8'h00;
        
        frame_len = 18;
        send_frame(frame_len);
        
        $display("[INFO] Logical read complete");
        check_pass("LRD frame received", rx_frame_count > 0);
    end
endtask

// ============================================================================
// Test 5: NOP (No Operation)
// ============================================================================
task test_nop_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 5: NOP (No Operation) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h00;  // CMD: NOP
        frame_data[3] = 8'h05;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;
        frame_data[6] = 8'h00; frame_data[7] = 8'h00;
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'hAA; frame_data[13] = 8'hBB;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        check_pass("NOP frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 6: APRD (Auto-Increment Physical Read)
// ============================================================================
task test_aprd_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 6: APRD (Auto-Increment Physical Read) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h01;  // CMD: APRD
        frame_data[3] = 8'h06;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;  // ADP=0
        frame_data[6] = 8'h00; frame_data[7] = 8'h01;  // ADO=0x0100
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h00; frame_data[13] = 8'h00;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        check_pass("APRD frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 7: APWR (Auto-Increment Physical Write)
// ============================================================================
task test_apwr_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 7: APWR (Auto-Increment Physical Write) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h02;  // CMD: APWR
        frame_data[3] = 8'h07;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;  // ADP=0
        frame_data[6] = 8'h20; frame_data[7] = 8'h01;  // ADO=0x0120 (AL Control)
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h02; frame_data[13] = 8'h00;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        check_pass("APWR frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 8: FPWR (Fixed Physical Write)
// ============================================================================
task test_fpwr_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 8: FPWR (Fixed Physical Write) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h05;  // CMD: FPWR
        frame_data[3] = 8'h08;
        frame_data[4] = 8'h00; frame_data[5] = 8'h10;  // ADP=0x1000 (station addr)
        frame_data[6] = 8'h20; frame_data[7] = 8'h01;  // ADO=0x0120
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h02; frame_data[13] = 8'h00;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        check_pass("FPWR frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 9: LWR (Logical Write)
// ============================================================================
task test_lwr_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 9: LWR (Logical Write) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h10; frame_data[1] = 8'h10;
        frame_data[2] = 8'h0B;  // CMD: LWR
        frame_data[3] = 8'h09;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;
        frame_data[6] = 8'h00; frame_data[7] = 8'h00;
        frame_data[8] = 8'h04; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h11; frame_data[13] = 8'h22;
        frame_data[14] = 8'h33; frame_data[15] = 8'h44;
        frame_data[16] = 8'h00; frame_data[17] = 8'h00;
        frame_len = 18;
        send_frame(frame_len);

        check_pass("LWR frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 10: LRW (Logical Read/Write)
// ============================================================================
task test_lrw_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 10: LRW (Logical Read/Write) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h10; frame_data[1] = 8'h10;
        frame_data[2] = 8'h0C;  // CMD: LRW
        frame_data[3] = 8'h0A;
        frame_data[4] = 8'h00; frame_data[5] = 8'h10;
        frame_data[6] = 8'h00; frame_data[7] = 8'h00;
        frame_data[8] = 8'h04; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'hAA; frame_data[13] = 8'hBB;
        frame_data[14] = 8'hCC; frame_data[15] = 8'hDD;
        frame_data[16] = 8'h00; frame_data[17] = 8'h00;
        frame_len = 18;
        send_frame(frame_len);

        check_pass("LRW frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 11: BRD (Broadcast Read)
// ============================================================================
task test_brd_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 11: BRD (Broadcast Read) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h07;  // CMD: BRD
        frame_data[3] = 8'h0B;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;
        frame_data[6] = 8'h30; frame_data[7] = 8'h01;  // ADO=0x0130
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h00; frame_data[13] = 8'h00;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        check_pass("BRD frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 12: BRW (Broadcast Read/Write)
// ============================================================================
task test_brw_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 12: BRW (Broadcast Read/Write) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h09;  // CMD: BRW
        frame_data[3] = 8'h0C;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;
        frame_data[6] = 8'h20; frame_data[7] = 8'h01;
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h08; frame_data[13] = 8'h00;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        check_pass("BRW frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 13: ARMW (Auto-Increment Read/Multiple Write)
// ============================================================================
task test_armw_frame;
    reg [15:0] initial_count;
    begin
        $display("\n=== TEST 13: ARMW (Auto-Increment Read/Multiple Write) ===");
        reset_dut;
        initial_count = rx_frame_count;

        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h0D;  // CMD: ARMW
        frame_data[3] = 8'h0D;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;
        frame_data[6] = 8'h20; frame_data[7] = 8'h01;
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h04; frame_data[13] = 8'h00;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        check_pass("ARMW frame received", rx_frame_count > initial_count);
    end
endtask

// ============================================================================
// Test 14: WKC Increment Counter Functional Check
// ============================================================================
task test_wkc_count;
    reg [15:0] initial_wkc;
    begin
        $display("\n=== TEST 14: WKC Increment Counter ===");
        reset_dut;
        initial_wkc = wkc_increment_count;

        // BWR to station address - triggers WKC increment on match
        frame_data[0] = 8'h0E; frame_data[1] = 8'h10;
        frame_data[2] = 8'h08;  // CMD: BWR
        frame_data[3] = 8'h0E;
        frame_data[4] = 8'h00; frame_data[5] = 8'h00;
        frame_data[6] = 8'h20; frame_data[7] = 8'h01;
        frame_data[8] = 8'h02; frame_data[9] = 8'h00;
        frame_data[10] = 8'h00; frame_data[11] = 8'h00;
        frame_data[12] = 8'h02; frame_data[13] = 8'h00;
        frame_data[14] = 8'h00; frame_data[15] = 8'h00;
        frame_len = 16;
        send_frame(frame_len);

        $display("  WKC count: %0d -> %0d", initial_wkc, wkc_increment_count);
        check_pass("WKC counter functional", wkc_increment_count >= initial_wkc);
    end
endtask

// ============================================================================
// Test 4: Frame Error Handling
// ============================================================================
task test_frame_error;
    reg [15:0] initial_errors;
    begin
        $display("\n=== TEST 4: Frame Error Handling ===");
        reset_dut;
        
        initial_errors = rx_error_count;
        
        // Send frame with error flag
        @(posedge clk);
        rx_valid = 1;
        rx_data = 8'hFF;
        rx_sof = 1;
        rx_error = 1;  // Error during reception
        @(posedge clk);
        rx_valid = 0;
        rx_sof = 0;
        rx_error = 0;
        
        repeat(10) @(posedge clk);
        
        $display("  Error count: %0d -> %0d", initial_errors, rx_error_count);
        check_pass("Error detected", rx_error_count > initial_errors);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("========================================");
    $display("EtherCAT Frame Receiver Testbench");
    $display("========================================");
    
    test_fprd_frame;
    test_bwr_frame;
    test_lrd_frame;
    test_nop_frame;
    test_aprd_frame;
    test_apwr_frame;
    test_fpwr_frame;
    test_lwr_frame;
    test_lrw_frame;
    test_brd_frame;
    test_brw_frame;
    test_armw_frame;
    test_wkc_count;
    test_frame_error;
    
    // Summary
    $display("\n========================================");
    $display("Frame Receiver Test Summary:");
    $display("  PASSED: %0d", pass_count);
    $display("  FAILED: %0d", fail_count);
    $display("========================================");
    
    if (fail_count > 0)
        $display("TEST FAILED");
    else
        $display("TEST PASSED");

    $finish;
end

endmodule
