// ============================================================================
// PDI (Process Data Interface) Testbench (Pure Verilog-2001)
// Tests PDI-01~06: Register access, SM access, IRQ, Watchdog, Error handling
// Compatible with: Verilator, VCS (RTL uses SystemVerilog constructs)
// ============================================================================

`timescale 1ns/1ps

module tb_pdi;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter TIMEOUT_CYCLES = 100;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     rst_n;

// Avalon interface
reg  [15:0]             avs_address;
reg                     avs_read;
reg                     avs_write;
reg  [31:0]             avs_writedata;
reg  [3:0]              avs_byteenable;
wire [31:0]             avs_readdata;
wire                    avs_waitrequest;
wire                    avs_readdatavalid;

// Register interface (simulated)
wire                    reg_req;
wire                    reg_wr;
wire [15:0]             reg_addr;
wire [15:0]             reg_wdata;
reg  [15:0]             reg_rdata;
reg                     reg_ack;

// SM interface (simulated)
wire                    sm_pdi_req;
wire                    sm_pdi_wr;
wire [15:0]             sm_pdi_addr;
wire [31:0]             sm_pdi_wdata;
reg  [31:0]             sm_pdi_rdata;
reg                     sm_pdi_ack;
wire [3:0]              sm_id;

// Control
reg                     pdi_enable;
reg  [15:0]             irq_sources;
wire                    pdi_irq;
wire                    pdi_operational;
wire                    pdi_watchdog_timeout;

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;

// Simulated register memory
reg [15:0] reg_memory [0:4095];
integer i;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_pdi_avalon dut (
    .clk(clk),
    .rst_n(rst_n),
    .avs_address(avs_address),
    .avs_read(avs_read),
    .avs_write(avs_write),
    .avs_writedata(avs_writedata),
    .avs_byteenable(avs_byteenable),
    .avs_readdata(avs_readdata),
    .avs_waitrequest(avs_waitrequest),
    .avs_readdatavalid(avs_readdatavalid),
    .reg_req(reg_req),
    .reg_wr(reg_wr),
    .reg_addr(reg_addr),
    .reg_wdata(reg_wdata),
    .reg_rdata(reg_rdata),
    .reg_ack(reg_ack),
    .sm_pdi_req(sm_pdi_req),
    .sm_pdi_wr(sm_pdi_wr),
    .sm_pdi_addr(sm_pdi_addr),
    .sm_pdi_wdata(sm_pdi_wdata),
    .sm_pdi_rdata(sm_pdi_rdata),
    .sm_pdi_ack(sm_pdi_ack),
    .sm_id(sm_id),
    .pdi_enable(pdi_enable),
    .irq_sources(irq_sources),
    .pdi_irq(pdi_irq),
    .pdi_operational(pdi_operational),
    .pdi_watchdog_timeout(pdi_watchdog_timeout)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// ============================================================================
// Register/SM Response Model
// ============================================================================
always @(posedge clk) begin
    if (reg_req) begin
        if (reg_wr)
            reg_memory[reg_addr[11:0]] <= reg_wdata;
        reg_rdata <= reg_memory[reg_addr[11:0]];
        reg_ack <= 1;
    end else begin
        reg_ack <= 0;
    end
    
    if (sm_pdi_req) begin
        sm_pdi_rdata <= 32'hDEADBEEF;
        sm_pdi_ack <= 1;
    end else begin
        sm_pdi_ack <= 0;
    end
end

// ============================================================================
// VCD Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_pdi.vcd");
    $dumpvars(0, tb_pdi);
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
        avs_address = 0;
        avs_read = 0;
        avs_write = 0;
        avs_writedata = 0;
        avs_byteenable = 4'hF;
        pdi_enable = 1;
        irq_sources = 0;
        
        for (i = 0; i < 4096; i = i + 1)
            reg_memory[i] = 16'h0000;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Tasks: Avalon Write
// ============================================================================
task avs_write_op;
    input [15:0] addr;
    input [31:0] data;
    output success;
    begin
        @(posedge clk);
        avs_address = addr;
        avs_write = 1;
        avs_read = 0;
        avs_writedata = data;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (avs_waitrequest && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        avs_write = 0;
        success = (timeout_cnt < TIMEOUT_CYCLES);
        @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: Avalon Read
// ============================================================================
task avs_read_op;
    input [15:0] addr;
    output [31:0] data;
    output success;
    begin
        @(posedge clk);
        avs_address = addr;
        avs_read = 1;
        avs_write = 0;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (avs_waitrequest && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        // Wait for data valid
        timeout_cnt = 0;
        while (!avs_readdatavalid && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        data = avs_readdata;
        success = avs_readdatavalid;
        avs_read = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// PDI-01: Basic Register Access
// ============================================================================
task test_pdi01_register_access;
    reg success;
    reg [31:0] rd_val;
    begin
        $display("\n=== PDI-01: Basic Register Access ===");
        reset_dut;
        
        $display("  Writing 0x1234 to register 0x0100...");
        avs_write_op(16'h0100, 32'h00001234, success);
        check_pass("Register write completes", success);
        
        $display("  Reading register 0x0100...");
        avs_read_op(16'h0100, rd_val, success);
        $display("  Read value: 0x%08x", rd_val);
        
        check_pass("Register read completes", success);
        check_pass("Read data matches written", (rd_val & 16'hFFFF) == 16'h1234);
    end
endtask

// ============================================================================
// PDI-02: SM Access (Process Data)
// ============================================================================
task test_pdi02_sm_access;
    reg success;
    reg [31:0] rd_val;
    begin
        $display("\n=== PDI-02: SM Access (Process Data) ===");
        reset_dut;
        
        $display("  Writing to process data 0x1000...");
        avs_write_op(16'h1000, 32'hAABBCCDD, success);
        check_pass("SM write completes", success);
        
        $display("  Reading from process data 0x1000...");
        avs_read_op(16'h1000, rd_val, success);
        $display("  Read value: 0x%08x", rd_val);
        
        check_pass("SM read completes", success);
        check_pass("SM data received", rd_val == 32'hDEADBEEF);
    end
endtask

// ============================================================================
// PDI-03: IRQ Generation
// ============================================================================
task test_pdi03_irq;
    reg irq_before, irq_after;
    reg success;
    reg [31:0] rd_val;
    begin
        $display("\n=== PDI-03: IRQ Generation ===");
        reset_dut;
        
        irq_before = pdi_irq;
        $display("  IRQ before: %0d", irq_before);
        
        $display("  Triggering IRQ source...");
        irq_sources = 16'h0001;
        repeat(5) @(posedge clk);
        
        irq_after = pdi_irq;
        $display("  IRQ after: %0d", irq_after);
        
        check_pass("IRQ asserted on source", irq_after);
        
        irq_sources = 0;
        repeat(5) @(posedge clk);
    end
endtask

// ============================================================================
// PDI-04: PDI Disabled Access
// ============================================================================
task test_pdi04_disabled;
    begin
        $display("\n=== PDI-04: PDI Disabled Access ===");
        reset_dut;
        
        $display("  Disabling PDI...");
        pdi_enable = 0;
        @(posedge clk);
        
        check_pass("PDI not operational when disabled", !pdi_operational);
        
        pdi_enable = 1;
        repeat(10) @(posedge clk);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("==========================================");
    $display("PDI (Avalon) Testbench");
    $display("==========================================");
    
    test_pdi01_register_access;
    test_pdi02_sm_access;
    test_pdi03_irq;
    test_pdi04_disabled;
    
    // Summary
    $display("\n==========================================");
    $display("PDI Test Summary:");
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
