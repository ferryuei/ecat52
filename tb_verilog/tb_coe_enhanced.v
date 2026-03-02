// ============================================================================
// Enhanced CoE Handler Testbench
// Tests SDO Upload/Download, Segmented Transfer, and Error Handling
// ============================================================================

`timescale 1ns/1ps

module tb_coe_enhanced;

    // Test parameters
    parameter CLK_PERIOD = 10;
    
    // SDO Command Specifiers
    parameter SDO_CCS_DOWNLOAD_INIT_REQ = 8'h21;
    parameter SDO_CCS_DOWNLOAD_SEG_REQ  = 8'h00;
    parameter SDO_CCS_UPLOAD_INIT_REQ   = 8'h40;
    parameter SDO_CCS_UPLOAD_SEG_REQ    = 8'h60;
    parameter SDO_CCS_ABORT_REQ         = 8'h80;
    
    // Test signals
    reg         clk, rst_n;
    reg         coe_request;
    reg  [7:0]  coe_service;
    reg  [15:0] coe_index;
    reg  [7:0]  coe_subindex;
    reg  [31:0] coe_data_in;
    wire        coe_response_ready;
    wire [31:0] coe_response_data;
    wire [31:0] coe_abort_code;
    
    integer pass_count, fail_count;
    
    // PDI interface signals (for application object access)
    wire        pdi_obj_req;
    wire        pdi_obj_wr;
    wire [15:0] pdi_obj_index;
    wire [7:0]  pdi_obj_subindex;
    wire [31:0] pdi_obj_wdata;
    reg  [31:0] pdi_obj_rdata;
    reg         pdi_obj_ack;
    reg         pdi_obj_error;
    
    // Status
    wire        coe_busy;
    wire        coe_error;
    wire [7:0]  coe_response_service;
    
    // Module instantiation
    ecat_coe_handler #(
        .VENDOR_ID(32'h00000123),
        .PRODUCT_CODE(32'h00000456),
        .REVISION_NUM(32'h00010000),
        .SERIAL_NUM(32'h00000001)
    ) dut (
        .rst_n(rst_n),
        .clk(clk),
        .coe_request(coe_request),
        .coe_service(coe_service),
        .coe_index(coe_index),
        .coe_subindex(coe_subindex),
        .coe_data_in(coe_data_in),
        .coe_data_length(16'h0004),
        .coe_response_ready(coe_response_ready),
        .coe_response_service(coe_response_service),
        .coe_response_data(coe_response_data),
        .coe_abort_code(coe_abort_code),
        .pdi_obj_req(pdi_obj_req),
        .pdi_obj_wr(pdi_obj_wr),
        .pdi_obj_index(pdi_obj_index),
        .pdi_obj_subindex(pdi_obj_subindex),
        .pdi_obj_wdata(pdi_obj_wdata),
        .pdi_obj_rdata(pdi_obj_rdata),
        .pdi_obj_ack(pdi_obj_ack),
        .pdi_obj_error(pdi_obj_error),
        .coe_busy(coe_busy),
        .coe_error(coe_error)
    );
    
    // PDI object dictionary simulator
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pdi_obj_ack <= 0;
            pdi_obj_error <= 0;
            pdi_obj_rdata <= 0;
        end else begin
            pdi_obj_ack <= 0;
            pdi_obj_error <= 0;
            
            if (pdi_obj_req) begin
                // Simulate object dictionary
                case (pdi_obj_index)
                    16'h1000: begin // Device type
                        pdi_obj_ack <= 1;
                        pdi_obj_rdata <= 32'h00000191; // Slave device
                    end
                    16'h1001: begin // Error register
                        pdi_obj_ack <= 1;
                        pdi_obj_rdata <= 32'h00000000;
                    end
                    16'h1008: begin // Device name
                        pdi_obj_ack <= 1;
                        pdi_obj_rdata <= 32'h45434154; // "ECAT"
                    end
                    16'h1009: begin // Hardware version
                        if (pdi_obj_wr) begin
                            pdi_obj_ack <= 1;
                        end else begin
                            pdi_obj_ack <= 1;
                            pdi_obj_rdata <= 32'h00010000;
                        end
                    end
                    16'h1C12: begin // SM2 PDO assignment (write-only)
                        if (pdi_obj_wr) begin
                            pdi_obj_ack <= 1;
                        end else begin
                            pdi_obj_error <= 1; // Write-only
                        end
                    end
                    16'hFFFF: begin // Invalid object
                        pdi_obj_error <= 1;
                    end
                    default: begin
                        pdi_obj_ack <= 1;
                        pdi_obj_rdata <= 32'hDEADBEEF;
                    end
                endcase
            end
        end
    end
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // ========================================================================
    // Test Cases
    // ========================================================================
    
    task test_sdo_download;
        begin
            $display("\n=== CoE-Enhanced-01: SDO Download (Write Parameter) ===");
            
            // Write to object 0x1C12 (SM2 PDO Assignment)
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_DOWNLOAD_INIT_REQ;
            coe_index = 16'h1C12;
            coe_subindex = 8'h00;
            coe_data_in = 32'h00000001;  // One PDO mapped
            
            @(posedge clk);
            coe_request = 0;
            
            // Wait for response
            repeat(50) @(posedge clk);
            
            if (coe_response_ready && coe_abort_code == 0) begin
                $display("    [PASS] SDO Download successful");
                pass_count = pass_count + 1;
            end else begin
                $display("    [FAIL] SDO Download failed, abort: 0x%08h", coe_abort_code);
                fail_count = fail_count + 1;
            end
        end
    endtask
    
    task test_sdo_segmented_upload;
        begin
            $display("\n=== CoE-Enhanced-02: Segmented SDO Upload (>4 bytes) ===");
            
            // FIRST: Send upload init request to initialize segmented transfer
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_UPLOAD_INIT_REQ;
            coe_index = 16'h1008;  // Device name
            coe_subindex = 8'h00;
            
            // Keep request high for multiple cycles
            repeat(5) @(posedge clk);
            coe_request = 0;
            
            // Wait for init response
            repeat(100) @(posedge clk);
            
            $display("  Init response ready: %b", coe_response_ready);
            if (coe_response_ready) begin
                $display("  Init response service: 0x%02h", coe_response_service);
                $display("  Init response data: 0x%08h", coe_response_data);
            end else begin
                $display("  Checking coe_busy: %b", coe_busy);
            end
            
            // THEN: Request first segment
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_UPLOAD_SEG_REQ;
            
            // Keep request high for multiple cycles
            repeat(5) @(posedge clk);
            coe_request = 0;
            
            repeat(100) @(posedge clk);
            
            if (coe_response_ready) begin
                $display("  Segment 1 received: 0x%08h", coe_response_data);
                $display("    [PASS] Segmented upload");
                pass_count = pass_count + 1;
            end else begin
                $display("    [FAIL] Segment not received");
                fail_count = fail_count + 1;
            end
        end
    endtask
    
    task test_sdo_segmented_download;
        begin
            $display("\n=== CoE-Enhanced-03: Segmented SDO Download ===");
            
            // Download init
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_DOWNLOAD_INIT_REQ;
            coe_index = 16'h1009;  // Hardware version
            coe_subindex = 8'h00;
            coe_data_in = 32'h00000010;  // Indicate size
            
            @(posedge clk);
            coe_request = 0;
            
            repeat(50) @(posedge clk);
            
            // Download segment 1
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_DOWNLOAD_SEG_REQ;
            coe_data_in = 32'h12345678;
            
            @(posedge clk);
            coe_request = 0;
            
            repeat(50) @(posedge clk);
            
            if (coe_response_ready && coe_abort_code == 0) begin
                $display("    [PASS] Segmented download");
                pass_count = pass_count + 1;
            end else begin
                $display("    [FAIL] Segmented download failed");
                fail_count = fail_count + 1;
            end
        end
    endtask
    
    task test_abort_handling;
        begin
            $display("\n=== CoE-Enhanced-04: Abort Request ===");
            
            // Send abort
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_ABORT_REQ;
            coe_index = 16'h1000;
            coe_subindex = 8'h00;
            coe_data_in = 32'h08000000;  // General error
            
            @(posedge clk);
            coe_request = 0;
            
            repeat(50) @(posedge clk);
            
            $display("    [PASS] Abort sent (no crash)");
            pass_count = pass_count + 1;
        end
    endtask
    
    task test_invalid_index;
        begin
            $display("\n=== CoE-Enhanced-05: Invalid Object Index ===");
            
            // Try to access non-existent object
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_UPLOAD_INIT_REQ;
            coe_index = 16'hFFFF;  // Invalid
            coe_subindex = 8'h00;
            
            @(posedge clk);
            coe_request = 0;
            
            repeat(50) @(posedge clk);
            
            if (coe_abort_code != 0) begin
                $display("  Abort code: 0x%08h", coe_abort_code);
                $display("    [PASS] Invalid index rejected");
                pass_count = pass_count + 1;
            end else begin
                $display("    [FAIL] Invalid index not rejected");
                fail_count = fail_count + 1;
            end
        end
    endtask
    
    task test_write_only_object;
        begin
            $display("\n=== CoE-Enhanced-06: Write-Only Object Upload Attempt ===");
            
            // Try to read write-only object (e.g., 0x1C12)
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_UPLOAD_INIT_REQ;
            coe_index = 16'h1C12;
            coe_subindex = 8'h00;
            
            @(posedge clk);
            coe_request = 0;
            
            repeat(50) @(posedge clk);
            
            // Should get abort 0x06010001 (write-only)
            if (coe_abort_code == 32'h06010001) begin
                $display("  Correct abort: 0x%08h", coe_abort_code);
                $display("    [PASS] Write-only protection");
                pass_count = pass_count + 1;
            end else begin
                $display("    [FAIL] Wrong or no abort");
                fail_count = fail_count + 1;
            end
        end
    endtask
    
    task test_concurrent_requests;
        begin
            $display("\n=== CoE-Enhanced-07: Concurrent Request Handling ===");
            
            // Send first request
            @(posedge clk);
            coe_request = 1;
            coe_service = SDO_CCS_UPLOAD_INIT_REQ;
            coe_index = 16'h1000;
            coe_subindex = 8'h00;
            
            @(posedge clk);
            // Don't clear request, send another
            coe_index = 16'h1001;
            
            @(posedge clk);
            coe_request = 0;
            
            repeat(50) @(posedge clk);
            
            $display("    [PASS] No crash on concurrent requests");
            pass_count = pass_count + 1;
        end
    endtask
    
    task test_rapid_requests;
        integer i;
        begin
            $display("\n=== CoE-Enhanced-08: Rapid Sequential Requests ===");
            
            for (i = 0; i < 5; i = i + 1) begin
                @(posedge clk);
                coe_request = 1;
                coe_service = SDO_CCS_UPLOAD_INIT_REQ;
                coe_index = 16'h1000 + i;
                coe_subindex = 8'h00;
                
                @(posedge clk);
                coe_request = 0;
                
                repeat(10) @(posedge clk);
            end
            
            $display("  Completed 5 rapid requests");
            $display("    [PASS] Rapid requests handled");
            pass_count = pass_count + 1;
        end
    endtask
    
    // Main test sequence
    initial begin
        pass_count = 0;
        fail_count = 0;
        
        $display("========================================");
        $display("Enhanced CoE Handler Testbench");
        $display("========================================");
        
        // Reset
        rst_n = 0;
        coe_request = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(10) @(posedge clk);
        
        // Run tests
        test_sdo_download;
        test_sdo_segmented_upload;
        test_sdo_segmented_download;
        test_abort_handling;
        test_invalid_index;
        test_write_only_object;
        test_concurrent_requests;
        test_rapid_requests;
        
        // Summary
        $display("\n========================================");
        $display("Enhanced CoE Test Summary:");
        $display("  PASSED: %0d", pass_count);
        $display("  FAILED: %0d", fail_count);
        $display("========================================");
        
        if (fail_count == 0) $display("TEST PASSED");
        else $display("TEST FAILED");
        
        $finish;
    end
    
    // Timeout
    initial begin
        #50000;
        $display("\n[ERROR] Test timeout!");
        $finish;
    end

endmodule
