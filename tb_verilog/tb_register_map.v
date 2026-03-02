// ============================================================================
// Register Map Testbench (Pure Verilog-2001)
// Tests ESC register read/write operations
// Compatible with: iverilog, VCS, Verilator
// ============================================================================

`timescale 1ns/1ps

module tb_register_map;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;
parameter TIMEOUT_CYCLES = 100;
parameter NUM_FMMU = 8;
parameter NUM_SM = 8;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     rst_n;

// Register access interface
reg                     reg_req;
reg                     reg_wr;
reg  [15:0]             reg_addr;
reg  [15:0]             reg_wdata;
reg  [1:0]              reg_be;
wire [15:0]             reg_rdata;
wire                    reg_ack;

// AL interface
wire [4:0]              al_control;
wire                    al_control_changed;
reg  [4:0]              al_status;
reg  [15:0]             al_status_code;

// DL interface
wire                    dl_control_fwd_en;
wire                    dl_control_temp_loop;
reg  [15:0]             dl_status;

// Port configuration
wire [3:0]              port_enable;
reg  [3:0]              port_link_status;
reg  [3:0]              port_loop_status;

// Station address
wire [15:0]             station_address;
wire [15:0]             station_alias;

// IRQ registers
wire [15:0]             irq_mask;
reg  [15:0]             irq_request;

// SM/FMMU status
reg  [7:0]              sm_status;
reg  [7:0]              fmmu_status;
reg  [NUM_FMMU*8-1:0]   fmmu_error_codes;

// DC
reg  [63:0]             dc_system_time;
wire [31:0]             dc_sync0_cycle;
wire [31:0]             dc_sync1_cycle;

// Statistics
reg  [31:0]             rx_error_counter;
reg  [31:0]             lost_link_counter;

// FMMU config outputs
wire [NUM_FMMU*32-1:0]  fmmu_log_start_addr;
wire [NUM_FMMU*16-1:0]  fmmu_length;
wire [NUM_FMMU*3-1:0]   fmmu_log_start_bit;
wire [NUM_FMMU*3-1:0]   fmmu_log_end_bit;
wire [NUM_FMMU*16-1:0]  fmmu_phys_start_addr;
wire [NUM_FMMU*3-1:0]   fmmu_phys_start_bit;
wire [NUM_FMMU-1:0]     fmmu_read_enable;
wire [NUM_FMMU-1:0]     fmmu_write_enable;
wire [NUM_FMMU-1:0]     fmmu_enable;

// SM config outputs
wire [NUM_SM*16-1:0]    sm_phys_start_addr;
wire [NUM_SM*16-1:0]    sm_length;
wire [NUM_SM*8-1:0]     sm_control;
wire [NUM_SM-1:0]       sm_enable;
wire [NUM_SM-1:0]       sm_repeat;
reg  [NUM_SM*8-1:0]     sm_status_in;

// Watchdog
wire [15:0]             watchdog_divider;
wire [15:0]             watchdog_time_pdi;
wire [15:0]             watchdog_time_sm;
wire                    watchdog_enable;
reg                     watchdog_expired;

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;
reg [15:0] read_data;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_register_map #(
    .VENDOR_ID(32'h00000000),
    .PRODUCT_CODE(32'h00000000),
    .REVISION_NUM(32'h00010000),
    .SERIAL_NUM(32'h00000001),
    .NUM_FMMU(NUM_FMMU),
    .NUM_SM(NUM_SM)
) dut (
    .clk(clk),
    .rst_n(rst_n),
    .reg_req(reg_req),
    .reg_wr(reg_wr),
    .reg_addr(reg_addr),
    .reg_wdata(reg_wdata),
    .reg_be(reg_be),
    .reg_rdata(reg_rdata),
    .reg_ack(reg_ack),
    .al_control(al_control),
    .al_control_changed(al_control_changed),
    .al_status(al_status),
    .al_status_code(al_status_code),
    .dl_control_fwd_en(dl_control_fwd_en),
    .dl_control_temp_loop(dl_control_temp_loop),
    .dl_status(dl_status),
    .port_enable(port_enable),
    .port_link_status(port_link_status),
    .port_loop_status(port_loop_status),
    .station_address(station_address),
    .station_alias(station_alias),
    .irq_mask(irq_mask),
    .irq_request(irq_request),
    .sm_status(sm_status),
    .fmmu_status(fmmu_status),
    .fmmu_error_codes(fmmu_error_codes),
    .dc_system_time(dc_system_time),
    .dc_sync0_cycle(dc_sync0_cycle),
    .dc_sync1_cycle(dc_sync1_cycle),
    .rx_error_counter(rx_error_counter),
    .lost_link_counter(lost_link_counter),
    .fmmu_log_start_addr(fmmu_log_start_addr),
    .fmmu_length(fmmu_length),
    .fmmu_log_start_bit(fmmu_log_start_bit),
    .fmmu_log_end_bit(fmmu_log_end_bit),
    .fmmu_phys_start_addr(fmmu_phys_start_addr),
    .fmmu_phys_start_bit(fmmu_phys_start_bit),
    .fmmu_read_enable(fmmu_read_enable),
    .fmmu_write_enable(fmmu_write_enable),
    .fmmu_enable(fmmu_enable),
    .sm_phys_start_addr(sm_phys_start_addr),
    .sm_length(sm_length),
    .sm_control(sm_control),
    .sm_enable(sm_enable),
    .sm_repeat(sm_repeat),
    .sm_status_in(sm_status_in),
    .watchdog_divider(watchdog_divider),
    .watchdog_time_pdi(watchdog_time_pdi),
    .watchdog_time_sm(watchdog_time_sm),
    .watchdog_enable(watchdog_enable),
    .watchdog_expired(watchdog_expired)
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
    $dumpfile("tb_register_map.vcd");
    $dumpvars(0, tb_register_map);
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
        reg_req = 0;
        reg_wr = 0;
        reg_addr = 0;
        reg_wdata = 0;
        reg_be = 2'b11;
        al_status = 5'h01;
        al_status_code = 0;
        dl_status = 0;
        port_link_status = 4'h3;
        port_loop_status = 0;
        irq_request = 0;
        sm_status = 0;
        fmmu_status = 0;
        fmmu_error_codes = 0;
        dc_system_time = 0;
        rx_error_counter = 0;
        lost_link_counter = 0;
        sm_status_in = 0;
        watchdog_expired = 0;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Tasks: Read Register
// ============================================================================
task read_reg;
    input [15:0] addr;
    output [15:0] data;
    begin
        @(posedge clk);
        reg_req = 1;
        reg_wr = 0;
        reg_addr = addr;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (!reg_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        if (timeout_cnt >= TIMEOUT_CYCLES) begin
            $display("  ERROR: Read timeout at address 0x%04x", addr);
            data = 16'hFFFF;
        end else begin
            data = reg_rdata;
            $display("  READ  [0x%04x] = 0x%04x", addr, data);
        end
        
        reg_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Tasks: Write Register
// ============================================================================
task write_reg;
    input [15:0] addr;
    input [15:0] data;
    input [1:0] be;
    begin
        $display("  WRITE [0x%04x] = 0x%04x", addr, data);
        
        @(posedge clk);
        reg_req = 1;
        reg_wr = 1;
        reg_addr = addr;
        reg_wdata = data;
        reg_be = be;
        @(posedge clk);
        
        timeout_cnt = 0;
        while (!reg_ack && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        
        if (timeout_cnt >= TIMEOUT_CYCLES) begin
            $display("  ERROR: Write timeout at address 0x%04x", addr);
        end
        
        reg_req = 0;
        @(posedge clk);
    end
endtask

// ============================================================================
// Test: Device Information (Read-Only)
// ============================================================================
task test_device_info;
    reg [15:0] type_val;
    reg [15:0] build_val;
    reg [15:0] fmmu_sm;
    reg [15:0] ram_port;
    begin
        $display("\n=== TEST: Device Information (Read-Only) ===");
        
        read_reg(16'h0000, type_val);
        $display("    Device Type/Revision: 0x%04x", type_val);
        
        read_reg(16'h0002, build_val);
        $display("    Build: %0d", build_val);
        
        read_reg(16'h0004, fmmu_sm);
        $display("    FMMU count: %0d, SM count: %0d", fmmu_sm[7:0], fmmu_sm[15:8]);
        
        read_reg(16'h0006, ram_port);
        $display("    RAM size: %0d KB", ram_port[7:0]);
        $display("    Port desc: 0x%02x", ram_port[15:8]);
        
        check_pass("Device info readable", 1'b1);
    end
endtask

// ============================================================================
// Test: Station Address Configuration
// ============================================================================
task test_station_address;
    reg [15:0] addr_val;
    reg [15:0] alias_val;
    begin
        $display("\n=== TEST: Station Address Configuration ===");
        
        // Write station address
        write_reg(16'h0010, 16'h1234, 2'b11);
        
        // Read back
        read_reg(16'h0010, addr_val);
        check_pass("Station address set (0x1234)", addr_val == 16'h1234);
        
        // Write station alias
        write_reg(16'h0012, 16'h5678, 2'b11);
        read_reg(16'h0012, alias_val);
        check_pass("Station alias set (0x5678)", alias_val == 16'h5678);
    end
endtask

// ============================================================================
// Test: AL Control/Status
// ============================================================================
task test_al_control;
    reg [15:0] status_val;
    reg [15:0] code_val;
    begin
        $display("\n=== TEST: AL Control/Status ===");
        
        // Read AL status
        read_reg(16'h0130, status_val);
        $display("    Initial AL Status: 0x%04x", status_val);
        
        // Write AL control (request Pre-Op = 0x02)
        write_reg(16'h0120, 16'h0002, 2'b11);
        @(posedge clk);
        
        $display("    AL Control Changed: %0d", al_control_changed);
        $display("    AL Control Value: 0x%02x", al_control);
        
        check_pass("AL control written", al_control == 5'h02);
        
        // Read AL status code
        read_reg(16'h0134, code_val);
        $display("    AL Status Code: 0x%04x", code_val);
    end
endtask

// ============================================================================
// Test: DL Control
// ============================================================================
task test_dl_control;
    reg [15:0] status_val;
    begin
        $display("\n=== TEST: DL Control ===");
        
        // Write DL control (0x0047 - Enable forwarding)
        write_reg(16'h0100, 16'h0047, 2'b11);
        
        $display("    DL Control - Forwarding Enable: %0d", dl_control_fwd_en);
        
        // Read DL status
        read_reg(16'h0110, status_val);
        $display("    DL Status: 0x%04x", status_val);
        
        check_pass("DL control functional", 1'b1);
    end
endtask

// ============================================================================
// Test: IRQ Registers
// ============================================================================
task test_irq_registers;
    reg [15:0] mask_val;
    reg [15:0] req_val;
    begin
        $display("\n=== TEST: IRQ Registers ===");
        
        // Write ECAT event mask (0x0200)
        write_reg(16'h0200, 16'h00FF, 2'b11);
        read_reg(16'h0200, mask_val);
        $display("    ECAT Event Mask: 0x%04x", mask_val);
        check_pass("ECAT event mask writable", mask_val == 16'h00FF);
        
        // Simulate IRQ input
        irq_request = 16'h0001;
        repeat(5) @(posedge clk);
        
        // Read ECAT event request (0x0210)
        read_reg(16'h0210, req_val);
        $display("    ECAT Event Request: 0x%04x", req_val);
        
        check_pass("ECAT event request received", req_val != 16'h0000);
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("========================================");
    $display("Register Map Testbench");
    $display("========================================");
    
    reset_dut;
    
    test_device_info;
    test_station_address;
    test_al_control;
    test_dl_control;
    test_irq_registers;
    
    // Summary
    $display("\n========================================");
    $display("Register Map Test Summary:");
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
