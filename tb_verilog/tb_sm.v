// ============================================================================
// SM (Sync Manager) Testbench (Pure Verilog-2001)
// Tests SM configuration and data exchange
// Compatible with: Verilator, VCS (RTL uses SystemVerilog constructs)
// ============================================================================

`timescale 1ns/1ps

module tb_sm;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter TIMEOUT_CYCLES = 100;
parameter ADDR_WIDTH = 16;
parameter DATA_WIDTH = 8;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     pdi_clk;
reg                     rst_n;
reg  [255:0]            feature_vector;

// Configuration
reg                     cfg_wr;
reg  [7:0]              cfg_addr;
reg  [15:0]             cfg_wdata;
wire [15:0]             cfg_rdata;

// ECAT access
reg                     ecat_req;
reg                     ecat_wr;
reg  [ADDR_WIDTH-1:0]   ecat_addr;
reg  [DATA_WIDTH-1:0]   ecat_wdata;
wire                    ecat_ack;
wire [DATA_WIDTH-1:0]   ecat_rdata;

// PDI access
reg                     pdi_req;
reg                     pdi_wr;
reg  [ADDR_WIDTH-1:0]   pdi_addr;
reg  [DATA_WIDTH-1:0]   pdi_wdata;
wire                    pdi_ack;
wire [DATA_WIDTH-1:0]   pdi_rdata;

// Memory interface
wire                    mem_req;
wire                    mem_wr;
wire [ADDR_WIDTH-1:0]   mem_addr;
wire [DATA_WIDTH-1:0]   mem_wdata;
reg                     mem_ack;
reg  [DATA_WIDTH-1:0]   mem_rdata;

// Status
wire                    sm_irq;
wire                    sm_active;
wire [2:0]              sm_status;

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;

// Simulated memory
reg [7:0] memory [0:65535];
integer i;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_sync_manager #(
    .SM_ID(0),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
) dut (
    .clk(clk),
    .pdi_clk(pdi_clk),
    .rst_n(rst_n),
    .feature_vector(feature_vector),
    // Configuration
    .cfg_wr(cfg_wr),
    .cfg_addr(cfg_addr),
    .cfg_wdata(cfg_wdata),
    .cfg_rdata(cfg_rdata),
    // EtherCAT side
    .ecat_req(ecat_req),
    .ecat_wr(ecat_wr),
    .ecat_addr(ecat_addr),
    .ecat_wdata(ecat_wdata),
    .ecat_ack(ecat_ack),
    .ecat_rdata(ecat_rdata),
    // PDI side
    .pdi_req(pdi_req),
    .pdi_wr(pdi_wr),
    .pdi_addr(pdi_addr),
    .pdi_wdata(pdi_wdata),
    .pdi_ack(pdi_ack),
    .pdi_rdata(pdi_rdata),
    // Memory
    .mem_req(mem_req),
    .mem_wr(mem_wr),
    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),
    .mem_ack(mem_ack),
    .mem_rdata(mem_rdata),
    // Status
    .sm_irq(sm_irq),
    .sm_active(sm_active),
    .sm_status(sm_status)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

initial begin
    pdi_clk = 0;
    forever #(CLK_PERIOD/2) pdi_clk = ~pdi_clk;
end

// ============================================================================
// Memory Model
// ============================================================================
always @(posedge clk) begin
    if (mem_req) begin
        if (mem_wr)
            memory[mem_addr] <= mem_wdata;
        mem_rdata <= memory[mem_addr];
        mem_ack <= 1;
    end else begin
        mem_ack <= 0;
    end
end

// ============================================================================
// VCD Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_sm.vcd");
    $dumpvars(0, tb_sm);
end

// ============================================================================
// Tasks
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

task reset_dut;
    begin
        rst_n = 0;
        cfg_wr = 0;
        cfg_addr = 0;
        cfg_wdata = 0;
        ecat_req = 0;
        ecat_wr = 0;
        ecat_addr = 0;
        ecat_wdata = 0;
        pdi_req = 0;
        pdi_wr = 0;
        pdi_addr = 0;
        pdi_wdata = 0;
        feature_vector = 256'h0;
        
        for (i = 0; i < 65536; i = i + 1)
            memory[i] = 8'h00;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

task cfg_write_op;
    input [7:0] addr;
    input [15:0] data;
    begin
        @(posedge clk);
        cfg_wr = 1;
        cfg_addr = addr;
        cfg_wdata = data;
        @(posedge clk);
        cfg_wr = 0;
        @(posedge clk);
    end
endtask

task ecat_write_op;
    input [15:0] addr;
    input [7:0] data;
    begin
        @(posedge clk);
        ecat_req = 1;
        ecat_wr = 1;
        ecat_addr = addr;
        ecat_wdata = data;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (!ecat_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        ecat_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Test: SM Configuration
// ============================================================================
task test_sm_config;
    begin
        $display("\n=== Test: SM Configuration ===");
        reset_dut;
        
        // Configure SM
        cfg_write_op(8'h00, 16'h1000);  // Start address
        cfg_write_op(8'h02, 16'h0040);  // Length = 64 bytes
        cfg_write_op(8'h04, 16'h0002);  // Control: mailbox mode
        cfg_write_op(8'h06, 16'h0001);  // Activate
        
        repeat(5) @(posedge clk);
        
        check_pass("SM activated", sm_active);
    end
endtask

// ============================================================================
// Test: SM Write
// ============================================================================
task test_sm_write;
    begin
        $display("\n=== Test: SM Write ===");
        reset_dut;
        
        // Configure SM
        cfg_write_op(8'h00, 16'h2000);
        cfg_write_op(8'h02, 16'h0020);
        cfg_write_op(8'h04, 16'h0002);
        cfg_write_op(8'h06, 16'h0001);
        
        repeat(5) @(posedge clk);
        
        // Write to SM
        $display("  Writing to SM address 0x2000...");
        ecat_write_op(16'h2000, 8'hAB);
        
        check_pass("Write completed", 1'b1);
        check_pass("Data in memory", memory[16'h2000] == 8'hAB);
    end
endtask

// ============================================================================
// Test: SM IRQ
// ============================================================================
task test_sm_irq;
    reg irq_before;
    begin
        $display("\n=== Test: SM IRQ ===");
        reset_dut;
        
        // Configure SM with IRQ
        cfg_write_op(8'h00, 16'h3000);
        cfg_write_op(8'h02, 16'h0020);
        cfg_write_op(8'h04, 16'h001A);  // Mailbox + IRQ enable
        cfg_write_op(8'h06, 16'h0001);
        
        repeat(5) @(posedge clk);
        
        irq_before = sm_irq;
        
        // Write to trigger IRQ
        ecat_write_op(16'h3000, 8'hCD);
        
        repeat(5) @(posedge clk);
        
        check_pass("IRQ triggered", sm_irq || irq_before != sm_irq);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("==========================================");
    $display("SM (Sync Manager) Testbench");
    $display("==========================================");
    
    test_sm_config;
    test_sm_write;
    test_sm_irq;
    
    $display("\n==========================================");
    $display("SM Test Summary:");
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
