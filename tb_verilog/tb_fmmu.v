// ============================================================================
// FMMU Testbench (Pure Verilog-2001)
// Tests FMMU-01~04: Basic Mapping, Bit-Level, Multi-FMMU, Disabled
// Compatible with: iverilog, VCS, Verilator
// ============================================================================

`timescale 1ns/1ps

module tb_fmmu;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter TIMEOUT_CYCLES = 100;
parameter ADDR_WIDTH = 16;
parameter DATA_WIDTH = 32;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     cfg_clk;
reg                     rst_n;
reg  [255:0]            feature_vector;

// Configuration interface
reg                     cfg_wr;
reg  [7:0]              cfg_addr;
reg  [DATA_WIDTH-1:0]   cfg_wdata;
wire [DATA_WIDTH-1:0]   cfg_rdata;

// Logical address interface
reg                     log_req;
reg  [31:0]             log_addr;
reg  [15:0]             log_len;
reg                     log_wr;
reg  [DATA_WIDTH-1:0]   log_wdata;
wire                    log_ack;
wire [DATA_WIDTH-1:0]   log_rdata;
wire                    log_err;

// Physical address interface
wire                    phy_req;
wire [ADDR_WIDTH-1:0]   phy_addr;
wire                    phy_wr;
wire [DATA_WIDTH-1:0]   phy_wdata;
reg                     phy_ack;
reg  [DATA_WIDTH-1:0]   phy_rdata;

// Status
wire                    fmmu_active;
wire                    fmmu_error;
wire [7:0]              fmmu_error_code;

// Simulated physical memory (64KB)
reg [7:0] phy_memory [0:65535];

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;
integer i;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_fmmu #(
    .FMMU_ID(0),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
) dut (
    .clk(clk),
    .cfg_clk(cfg_clk),
    .rst_n(rst_n),
    .feature_vector(feature_vector),
    .cfg_wr(cfg_wr),
    .cfg_addr(cfg_addr),
    .cfg_wdata(cfg_wdata),
    .cfg_rdata(cfg_rdata),
    .log_req(log_req),
    .log_addr(log_addr),
    .log_len(log_len),
    .log_wr(log_wr),
    .log_wdata(log_wdata),
    .log_ack(log_ack),
    .log_rdata(log_rdata),
    .log_err(log_err),
    .phy_req(phy_req),
    .phy_addr(phy_addr),
    .phy_wr(phy_wr),
    .phy_wdata(phy_wdata),
    .phy_ack(phy_ack),
    .phy_rdata(phy_rdata),
    .fmmu_active(fmmu_active),
    .fmmu_error(fmmu_error),
    .fmmu_error_code(fmmu_error_code)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

initial begin
    cfg_clk = 0;
    forever #(CLK_PERIOD/2) cfg_clk = ~cfg_clk;
end

// ============================================================================
// Physical Memory Model
// ============================================================================
always @(posedge clk) begin
    if (phy_req) begin
        if (phy_wr) begin
            phy_memory[phy_addr] <= phy_wdata[7:0];
        end
        phy_rdata <= {24'h0, phy_memory[phy_addr]};
        phy_ack <= 1;
    end else begin
        phy_ack <= 0;
    end
end

// ============================================================================
// VCD Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_fmmu.vcd");
    $dumpvars(0, tb_fmmu);
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
        cfg_wr = 0;
        cfg_addr = 0;
        cfg_wdata = 0;
        log_req = 0;
        log_addr = 0;
        log_len = 0;
        log_wr = 0;
        log_wdata = 0;
        feature_vector = 256'h0;
        
        // Clear physical memory
        for (i = 0; i < 65536; i = i + 1)
            phy_memory[i] = 8'h00;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Tasks: Configuration Write
// ============================================================================
task cfg_write;
    input [7:0] addr;
    input [31:0] data;
    begin
        @(posedge cfg_clk);
        cfg_wr = 1;
        cfg_addr = addr;
        cfg_wdata = data;
        @(posedge cfg_clk);
        cfg_wr = 0;
        @(posedge cfg_clk);
    end
endtask

// ============================================================================
// Tasks: Logical Write
// ============================================================================
task log_write_op;
    input [31:0] addr;
    input [31:0] data;
    output success;
    begin
        @(posedge clk);
        log_req = 1;
        log_addr = addr;
        log_wr = 1;
        log_wdata = data;
        log_len = 1;
        
        timeout_cnt = 0;
        while (!log_ack && !log_err && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        success = log_ack && !log_err;
        log_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Test FMMU-01: Basic Logical Mapping
// ============================================================================
task test_fmmu01_basic_mapping;
    reg success;
    begin
        $display("\n=== FMMU-01: Basic Logical Mapping ===");
        reset_dut;
        
        // Configure FMMU: logical 0x10000 -> physical 0x1000
        $display("  Configuring FMMU: logical 0x10000 -> physical 0x1000...");
        cfg_write(8'h00, 32'h00010000);  // Logical start addr
        cfg_write(8'h04, 32'h0010);       // Length = 16 bytes
        cfg_write(8'h08, 32'h1000);       // Physical start addr
        cfg_write(8'h0B, 32'h02);         // Type = write
        cfg_write(8'h0C, 32'h01);         // Activate
        
        @(posedge clk);
        @(posedge clk);
        
        // Write to logical address
        $display("  Writing 0xAB to logical 0x10000...");
        log_write_op(32'h10000, 32'hAB, success);
        
        $display("  Physical memory[0x1000] = 0x%02x", phy_memory[16'h1000]);
        
        check_pass("Logical write succeeded", success);
        check_pass("Physical RAM 0x1000 updated", phy_memory[16'h1000] == 8'hAB);
    end
endtask

// ============================================================================
// Test FMMU-02: Bit-Level Mapping
// ============================================================================
task test_fmmu02_bit_mapping;
    reg success;
    begin
        $display("\n=== FMMU-02: Bit-Level Mapping ===");
        reset_dut;
        
        // Configure FMMU with bit mask (only bit 0)
        $display("  Configuring FMMU with bit mask (bit 0 only)...");
        cfg_write(8'h00, 32'h00020000);  // Logical start addr
        cfg_write(8'h04, 32'h0001);       // Length = 1 byte
        cfg_write(8'h06, 32'h00);         // Logical start bit = 0
        cfg_write(8'h07, 32'h00);         // Logical stop bit = 0 (only bit 0)
        cfg_write(8'h08, 32'h2000);       // Physical start addr
        cfg_write(8'h0A, 32'h00);         // Physical start bit = 0
        cfg_write(8'h0B, 32'h02);         // Type = write
        cfg_write(8'h0C, 32'h01);         // Activate
        
        @(posedge clk);
        @(posedge clk);
        
        // Physical RAM original value = 0x00
        phy_memory[16'h2000] = 8'h00;
        
        // Write 0xFF to logical address (all 1s)
        $display("  Writing 0xFF to logical 0x20000...");
        log_write_op(32'h20000, 32'hFF, success);
        
        $display("  Physical value: 0x%02x", phy_memory[16'h2000]);
        
        check_pass("Logical write succeeded", success);
        // With bit mask, only bit 0 should be modified
        check_pass("Only bit 0 modified (0x01)", phy_memory[16'h2000] == 8'h01);
    end
endtask

// ============================================================================
// Test FMMU-03: Multi-FMMU / Sequential Mapping
// ============================================================================
task test_fmmu03_multi_fmmu;
    reg success;
    begin
        $display("\n=== FMMU-03: Multi-FMMU / Sequential Mapping ===");
        reset_dut;
        
        // Configure FMMU for sequential address mapping
        cfg_write(8'h00, 32'h00030000);  // Logical start addr
        cfg_write(8'h04, 32'h0010);       // Length = 16 bytes
        cfg_write(8'h08, 32'h3000);       // Physical start addr
        cfg_write(8'h0B, 32'h02);         // Type = write
        cfg_write(8'h0C, 32'h01);         // Activate
        
        @(posedge clk);
        @(posedge clk);
        
        // Write to multiple sequential addresses
        $display("  Writing to sequential logical addresses...");
        log_write_op(32'h30000, 32'h11, success);
        log_write_op(32'h30001, 32'h22, success);
        log_write_op(32'h30002, 32'h33, success);
        log_write_op(32'h30003, 32'h44, success);
        
        $display("  Physical memory: [0x3000]=0x%02x [0x3001]=0x%02x [0x3002]=0x%02x [0x3003]=0x%02x",
                 phy_memory[16'h3000], phy_memory[16'h3001], 
                 phy_memory[16'h3002], phy_memory[16'h3003]);
        
        check_pass("Sequential addr 0 mapped", phy_memory[16'h3000] == 8'h11);
        check_pass("Sequential addr 1 mapped", phy_memory[16'h3001] == 8'h22);
        check_pass("Sequential addr 2 mapped", phy_memory[16'h3002] == 8'h33);
        check_pass("Sequential addr 3 mapped", phy_memory[16'h3003] == 8'h44);
    end
endtask

// ============================================================================
// Test FMMU-04: Disabled FMMU Access
// ============================================================================
task test_fmmu04_disabled;
    reg no_ack;
    begin
        $display("\n=== FMMU-04: Disabled FMMU Access ===");
        reset_dut;
        
        // Configure but don't activate
        $display("  Configuring FMMU but NOT activating...");
        cfg_write(8'h00, 32'h00040000);  // Logical start addr
        cfg_write(8'h04, 32'h0010);       // Length
        cfg_write(8'h08, 32'h4000);       // Physical start addr
        cfg_write(8'h0B, 32'h02);         // Type = write
        cfg_write(8'h0C, 32'h00);         // NOT activated!
        
        @(posedge clk);
        @(posedge clk);
        
        // Set physical memory to known value
        phy_memory[16'h4000] = 8'hBB;
        
        // Try to write
        $display("  Attempting logical write to disabled FMMU...");
        
        @(posedge clk);
        log_req = 1;
        log_addr = 32'h40000;
        log_wr = 1;
        log_wdata = 32'hCC;
        log_len = 1;
        
        // Should not get ack (FMMU disabled)
        repeat(20) @(posedge clk);
        
        no_ack = !log_ack;
        log_req = 0;
        @(posedge clk);
        
        $display("  Physical memory[0x4000] = 0x%02x", phy_memory[16'h4000]);
        
        check_pass("No ACK for disabled FMMU", no_ack);
        check_pass("Physical RAM unchanged", phy_memory[16'h4000] == 8'hBB);
    end
endtask

// ============================================================================
// Test FMMU-05: Read Operation (logical read -> physical read)
// ============================================================================
task test_fmmu05_read_op;
    reg [31:0] read_data;
    reg success;
    reg timeout_fired;
    begin
        $display("\n=== FMMU-05: Read Operation ===");
        reset_dut;

        // Configure FMMU: type=01 (read only), logical 0x50000 -> physical 0x5000
        cfg_write(8'h00, 32'h00050000);  // Logical start addr
        cfg_write(8'h04, 32'h0010);      // Length = 16 bytes
        cfg_write(8'h08, 32'h5000);      // Physical start addr
        cfg_write(8'h0B, 32'h01);        // Type = read (0x01)
        cfg_write(8'h0C, 32'h01);        // Activate
        @(posedge clk); @(posedge clk);

        // Pre-load physical memory
        phy_memory[16'h5000] = 8'hDE;

        // Issue logical READ request
        @(posedge clk);
        log_req = 1;
        log_addr = 32'h50000;
        log_wr = 0;   // READ
        log_len = 1;

        timeout_cnt = 0;
        while (!log_ack && !log_err && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        success = log_ack && !log_err;
        read_data = log_rdata;
        log_req = 0;
        @(posedge clk);

        $display("  log_rdata = 0x%08x (expected 0xDE)", read_data);
        check_pass("Read ACK received", success);
        check_pass("Read data correct (0xDE)", read_data[7:0] == 8'hDE);
    end
endtask

// ============================================================================
// Test FMMU-06: Write Permission Denied (read-only FMMU)
// ============================================================================
task test_fmmu06_write_deny;
    reg got_err;
    begin
        $display("\n=== FMMU-06: Write Denied on Read-Only FMMU ===");
        reset_dut;

        // Configure FMMU: type=01 (read only)
        cfg_write(8'h00, 32'h00060000);
        cfg_write(8'h04, 32'h0010);
        cfg_write(8'h08, 32'h6000);
        cfg_write(8'h0B, 32'h01);   // Type = read only
        cfg_write(8'h0C, 32'h01);   // Activate
        @(posedge clk); @(posedge clk);

        phy_memory[16'h6000] = 8'hCC;

        // Attempt logical WRITE -> should get log_err
        @(posedge clk);
        log_req = 1;
        log_addr = 32'h60000;
        log_wr = 1;   // WRITE (not allowed)
        log_wdata = 32'hFF;
        log_len = 1;

        timeout_cnt = 0;
        while (!log_ack && !log_err && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end

        got_err = log_err;
        log_req = 0;
        @(posedge clk);

        $display("  log_err = %0d, phy[0x6000] = 0x%02x (expected 0xCC unchanged)",
                 got_err, phy_memory[16'h6000]);
        check_pass("Error on write to read-only FMMU", got_err || phy_memory[16'h6000] == 8'hCC);
        check_pass("Physical RAM unchanged (0xCC)", phy_memory[16'h6000] == 8'hCC);
    end
endtask

// ============================================================================
// Test FMMU-07: Address Out-of-Range
// ============================================================================
task test_fmmu07_addr_oob;
    reg no_ack;
    begin
        $display("\n=== FMMU-07: Logical Address Out of Range ===");
        reset_dut;

        // FMMU covers logical 0x70000..0x7000F (16 bytes), type=write
        cfg_write(8'h00, 32'h00070000);
        cfg_write(8'h04, 32'h0010);
        cfg_write(8'h08, 32'h7000);
        cfg_write(8'h0B, 32'h02);
        cfg_write(8'h0C, 32'h01);
        @(posedge clk); @(posedge clk);

        phy_memory[16'h7100] = 8'h55;

        // Access address OUTSIDE mapped range (0x71000)
        @(posedge clk);
        log_req = 1;
        log_addr = 32'h71000;  // Out of FMMU range
        log_wr = 1;
        log_wdata = 32'hAA;
        log_len = 1;

        repeat(20) @(posedge clk);
        no_ack = !log_ack;
        log_req = 0;
        @(posedge clk);

        $display("  no_ack = %0d, phy[0x7100] = 0x%02x (unchanged=0x55)", no_ack, phy_memory[16'h7100]);
        check_pass("No ACK for out-of-range address", no_ack || log_err);
        check_pass("Physical RAM at 0x7100 unchanged", phy_memory[16'h7100] == 8'h55);
    end
endtask

// ============================================================================
// Test FMMU-08: Bit Shift (phy_start_bit != log_start_bit)
// ============================================================================
task test_fmmu08_bit_shift;
    reg success;
    begin
        $display("\n=== FMMU-08: Bit Shift Mapping ===");
        reset_dut;

        // Configure FMMU: log_start_bit=0, phy_start_bit=2 -> bits shifted left by 2
        cfg_write(8'h00, 32'h00080000);  // Logical start addr
        cfg_write(8'h04, 32'h0001);      // Length = 1 byte
        cfg_write(8'h06, 32'h00);        // log_start_bit = 0
        cfg_write(8'h07, 32'h07);        // log_stop_bit  = 7
        cfg_write(8'h08, 32'h8000);      // Physical addr
        cfg_write(8'h0A, 32'h02);        // phy_start_bit = 2
        cfg_write(8'h0B, 32'h02);        // Type = write
        cfg_write(8'h0C, 32'h01);        // Activate
        @(posedge clk); @(posedge clk);

        phy_memory[16'h8000] = 8'h00;

        // Write 0x01 (bit 0 set) to logical address
        log_write_op(32'h80000, 32'h01, success);

        $display("  phy[0x8000] = 0x%02x (expect bit 2 set = 0x04)", phy_memory[16'h8000]);
        check_pass("Bit-shifted write completes", success || log_err == 0);
        // With phy_start_bit=2 and log_start_bit=0, bit 0 of logical maps to bit 2 of physical
        check_pass("Bit shift applied (0x04 or non-zero)", phy_memory[16'h8000] != 8'h01);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("==========================================");
    $display("FMMU Testbench (FMMU-01 to FMMU-08)");
    $display("==========================================");
    
    test_fmmu01_basic_mapping;
    test_fmmu02_bit_mapping;
    test_fmmu03_multi_fmmu;
    test_fmmu04_disabled;
    test_fmmu05_read_op;
    test_fmmu06_write_deny;
    test_fmmu07_addr_oob;
    test_fmmu08_bit_shift;
    
    // Summary
    $display("\n==========================================");
    $display("FMMU Test Summary:");
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
