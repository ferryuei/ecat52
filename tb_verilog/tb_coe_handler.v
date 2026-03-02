// ============================================================================
// CoE (CANopen over EtherCAT) Handler Testbench (Pure Verilog-2001)
// Tests SDO Upload/Download operations per ETG.1000
// Compatible with: Verilator, VCS (RTL uses SystemVerilog constructs)
// ============================================================================

`timescale 1ns/1ps

module tb_coe_handler;

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

// CoE interface
reg                     coe_request;
reg  [7:0]              coe_service;
reg  [15:0]             coe_index;
reg  [7:0]              coe_subindex;
reg  [31:0]             coe_data_in;
reg  [7:0]              coe_data_length;

wire                    coe_response_ready;
wire [31:0]             coe_response_data;
wire [31:0]             coe_abort_code;

// PDI object dictionary interface
wire                    pdi_obj_req;
wire                    pdi_obj_wr;
wire [15:0]             pdi_obj_index;
wire [7:0]              pdi_obj_subindex;
wire [31:0]             pdi_obj_wdata;
reg  [31:0]             pdi_obj_rdata;
reg                     pdi_obj_ack;
reg                     pdi_obj_error;

// Test counters
integer pass_count;
integer fail_count;
integer timeout_cnt;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_coe_handler dut (
    .clk(clk),
    .rst_n(rst_n),
    .coe_request(coe_request),
    .coe_service(coe_service),
    .coe_index(coe_index),
    .coe_subindex(coe_subindex),
    .coe_data_in(coe_data_in),
    .coe_data_length(coe_data_length),
    .coe_response_ready(coe_response_ready),
    .coe_response_data(coe_response_data),
    .coe_abort_code(coe_abort_code),
    .pdi_obj_req(pdi_obj_req),
    .pdi_obj_wr(pdi_obj_wr),
    .pdi_obj_index(pdi_obj_index),
    .pdi_obj_subindex(pdi_obj_subindex),
    .pdi_obj_wdata(pdi_obj_wdata),
    .pdi_obj_rdata(pdi_obj_rdata),
    .pdi_obj_ack(pdi_obj_ack),
    .pdi_obj_error(pdi_obj_error)
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
    $dumpfile("tb_coe_handler.vcd");
    $dumpvars(0, tb_coe_handler);
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
        coe_request = 0;
        coe_service = 0;
        coe_index = 0;
        coe_subindex = 0;
        coe_data_in = 0;
        coe_data_length = 0;
        pdi_obj_rdata = 0;
        pdi_obj_ack = 0;
        pdi_obj_error = 0;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete");
    end
endtask

// ============================================================================
// Tasks: SDO Upload (Read Object)
// ============================================================================
task sdo_upload;
    input [15:0] index;
    input [7:0] subindex;
    begin
        @(posedge clk);
        coe_request = 1;
        coe_service = 8'h40;  // Upload init request
        coe_index = index;
        coe_subindex = subindex;
        @(posedge clk);
        coe_request = 0;
        
        // Wait for response
        timeout_cnt = 0;
        while (!coe_response_ready && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            // Provide PDI ack if requested
            if (pdi_obj_req && !pdi_obj_ack) begin
                pdi_obj_ack = 1;
                pdi_obj_rdata = 32'h12345678;  // Test data
            end else begin
                pdi_obj_ack = 0;
            end
            timeout_cnt = timeout_cnt + 1;
        end
    end
endtask

// ============================================================================
// Tasks: SDO Download (Write Object)
// ============================================================================
task sdo_download;
    input [15:0] index;
    input [7:0] subindex;
    input [31:0] data;
    input [7:0] length;
    begin
        @(posedge clk);
        coe_request = 1;
        case (length)
            1: coe_service = 8'h2F;
            2: coe_service = 8'h2B;
            3: coe_service = 8'h27;
            default: coe_service = 8'h23;
        endcase
        coe_index = index;
        coe_subindex = subindex;
        coe_data_in = data;
        coe_data_length = length;
        @(posedge clk);
        coe_request = 0;
        
        // Wait for response
        timeout_cnt = 0;
        while (!coe_response_ready && timeout_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            if (pdi_obj_req && !pdi_obj_ack) begin
                pdi_obj_ack = 1;
            end else begin
                pdi_obj_ack = 0;
            end
            timeout_cnt = timeout_cnt + 1;
        end
    end
endtask

// ============================================================================
// Test: Device Type Read (0x1000)
// ============================================================================
task test_device_type_read;
    begin
        $display("\n=== Test: Read Device Type (0x1000) ===");
        reset_dut;
        
        sdo_upload(16'h1000, 8'h00);
        
        check_pass("Response ready", coe_response_ready == 1);
        check_pass("No abort", coe_abort_code == 0);
        $display("  Device Type: 0x%08x", coe_response_data);
    end
endtask

// ============================================================================
// Test: Identity Object Read (0x1018)
// ============================================================================
task test_identity_object;
    begin
        $display("\n=== Test: Read Identity Object (0x1018) ===");
        reset_dut;
        
        // Read Vendor ID (subindex 1)
        sdo_upload(16'h1018, 8'h01);
        check_pass("Vendor ID response", coe_response_ready == 1);
        $display("  Vendor ID: 0x%08x", coe_response_data);
        
        // Read Product Code (subindex 2)
        sdo_upload(16'h1018, 8'h02);
        check_pass("Product Code response", coe_response_ready == 1);
        $display("  Product Code: 0x%08x", coe_response_data);
    end
endtask

// ============================================================================
// Test: Invalid Object Abort
// ============================================================================
task test_invalid_object_abort;
    begin
        $display("\n=== Test: Invalid Object Abort ===");
        reset_dut;
        
        // Configure PDI to return error for unknown object
        pdi_obj_error = 1;
        
        sdo_upload(16'h9999, 8'h00);
        
        check_pass("Response ready", coe_response_ready == 1);
        check_pass("Abort code set", coe_abort_code != 0);
        $display("  Abort Code: 0x%08x", coe_abort_code);
        
        pdi_obj_error = 0;
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("========================================");
    $display("CoE Handler Testbench");
    $display("========================================");
    
    test_device_type_read;
    test_identity_object;
    test_invalid_object_abort;
    
    // Summary
    $display("\n========================================");
    $display("CoE Handler Test Summary:");
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
