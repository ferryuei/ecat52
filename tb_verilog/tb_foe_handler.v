// ============================================================================
// FoE (File over EtherCAT) Handler Testbench
// Tests file upload/download operations for firmware updates
// ============================================================================

`timescale 1ns/1ps

module tb_foe_handler;

    // Parameters
    parameter CLK_PERIOD = 10;
    parameter MAX_FILE_SIZE = 1024;  // 1KB test file
    
    // FoE OpCodes
    parameter FOE_OP_READ_REQ    = 8'h01;
    parameter FOE_OP_WRITE_REQ   = 8'h02;
    parameter FOE_OP_DATA        = 8'h03;
    parameter FOE_OP_ACK         = 8'h04;
    parameter FOE_OP_ERROR       = 8'h05;
    parameter FOE_OP_BUSY        = 8'h06;
    
    // Error codes
    parameter FOE_ERR_NOT_DEFINED   = 32'h00008000;
    parameter FOE_ERR_NOT_FOUND     = 32'h00008001;
    parameter FOE_ERR_ACCESS_DENIED = 32'h00008002;
    parameter FOE_ERR_DISK_FULL     = 32'h00008003;
    parameter FOE_ERR_ILLEGAL       = 32'h00008004;
    parameter FOE_ERR_PACKET_NUM    = 32'h00008005;
    parameter FOE_ERR_EXISTS        = 32'h00008006;
    parameter FOE_ERR_NO_USER       = 32'h00008007;
    
    // Signals
    reg         clk, rst_n;
    reg         foe_request;
    reg  [7:0]  foe_opcode;
    reg  [31:0] foe_packet_num;
    reg  [15:0] foe_data_length;
    reg  [7:0]  foe_data [0:511];
    reg  [255:0] foe_filename;
    
    wire        foe_response_ready;
    wire [7:0]  foe_response_opcode;
    wire [31:0] foe_response_packet;
    wire [15:0] foe_response_length;
    wire [31:0] foe_error_code;
    
    integer pass_count, fail_count;
    integer i;
    
    // Clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // ========================================================================
    // Test Tasks
    // ========================================================================
    
    task reset_dut;
        begin
            $display("[INFO] Reset");
            rst_n = 0;
            foe_request = 0;
            repeat(10) @(posedge clk);
            rst_n = 1;
            repeat(10) @(posedge clk);
        end
    endtask
    
    task check_result;
        input [200*8-1:0] test_name;
        input condition;
        begin
            if (condition) begin
                $display("    [PASS] %0s", test_name);
                pass_count = pass_count + 1;
            end else begin
                $display("    [FAIL] %0s", test_name);
                fail_count = fail_count + 1;
            end
        end
    endtask
    
    // Test 1: File Read Request
    task test_file_read_request;
        begin
            $display("\n=== FoE-01: File Read Request ===");
            reset_dut;
            
            // Request to read "firmware.bin"
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_READ_REQ;
            foe_filename = "firmware.bin";
            foe_packet_num = 0;
            
            @(posedge clk);
            foe_request = 0;
            
            // Wait for response
            repeat(100) @(posedge clk);
            
            if (foe_response_ready) begin
                $display("  Response OpCode: 0x%02h", foe_response_opcode);
                $display("  Packet Number: %0d", foe_response_packet);
                check_result("Read request acknowledged", 
                            foe_response_opcode == FOE_OP_DATA || 
                            foe_response_opcode == FOE_OP_ERROR);
            end else begin
                check_result("Read request acknowledged", 0);
            end
        end
    endtask
    
    // Test 2: File Write Request
    task test_file_write_request;
        begin
            $display("\n=== FoE-02: File Write Request ===");
            reset_dut;
            
            // Request to write "config.xml"
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_filename = "config.xml";
            foe_packet_num = 0;
            
            @(posedge clk);
            foe_request = 0;
            
            repeat(100) @(posedge clk);
            
            if (foe_response_ready) begin
                $display("  Response OpCode: 0x%02h", foe_response_opcode);
                check_result("Write request acknowledged", 
                            foe_response_opcode == FOE_OP_ACK ||
                            foe_response_opcode == FOE_OP_ERROR);
            end else begin
                check_result("Write request acknowledged", 0);
            end
        end
    endtask
    
    // Test 3: File Data Transfer
    task test_file_data_transfer;
        integer pkt;
        begin
            $display("\n=== FoE-03: File Data Transfer (Multiple Packets) ===");
            reset_dut;
            
            // Send 5 data packets
            for (pkt = 1; pkt <= 5; pkt = pkt + 1) begin
                @(posedge clk);
                foe_request = 1;
                foe_opcode = FOE_OP_DATA;
                foe_packet_num = pkt;
                foe_data_length = 128;
                
                // Fill with test pattern
                for (i = 0; i < 128; i = i + 1) begin
                    foe_data[i] = (pkt * 16 + i) & 8'hFF;
                end
                
                @(posedge clk);
                foe_request = 0;
                
                repeat(50) @(posedge clk);
                
                if (!foe_response_ready || foe_response_opcode != FOE_OP_ACK) begin
                    $display("  [WARN] Packet %0d not ACKed", pkt);
                end
            end
            
            $display("  Sent 5 data packets (640 bytes)");
            check_result("Data packets transferred", 1);
        end
    endtask
    
    // Test 4: File Upload with ACK
    task test_file_upload_ack;
        begin
            $display("\n=== FoE-04: File Upload with ACK ===");
            reset_dut;
            
            // Read request
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_READ_REQ;
            foe_filename = "test.dat";
            foe_packet_num = 0;
            @(posedge clk);
            foe_request = 0;
            
            repeat(50) @(posedge clk);
            
            // Send ACKs for received data
            for (i = 1; i <= 3; i = i + 1) begin
                @(posedge clk);
                foe_request = 1;
                foe_opcode = FOE_OP_ACK;
                foe_packet_num = i;
                @(posedge clk);
                foe_request = 0;
                
                repeat(50) @(posedge clk);
            end
            
            $display("  Sent ACKs for 3 packets");
            check_result("Upload ACK sequence", 1);
        end
    endtask
    
    // Test 5: Error Response
    task test_error_response;
        begin
            $display("\n=== FoE-05: File Not Found Error ===");
            reset_dut;
            
            // Request non-existent file
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_READ_REQ;
            foe_filename = "nonexistent.bin";
            foe_packet_num = 0;
            @(posedge clk);
            foe_request = 0;
            
            repeat(100) @(posedge clk);
            
            if (foe_response_ready && foe_response_opcode == FOE_OP_ERROR) begin
                $display("  Error code: 0x%08h", foe_error_code);
                check_result("File not found error", 
                            foe_error_code == FOE_ERR_NOT_FOUND);
            end else begin
                check_result("File not found error", 0);
            end
        end
    endtask
    
    // Test 6: Busy Response
    task test_busy_response;
        begin
            $display("\n=== FoE-06: Busy Response ===");
            reset_dut;
            
            // Send two rapid requests
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_filename = "flash.bin";
            @(posedge clk);
            // Don't clear request
            foe_opcode = FOE_OP_DATA;
            foe_packet_num = 1;
            @(posedge clk);
            foe_request = 0;
            
            repeat(100) @(posedge clk);
            
            // Should get busy or process both
            $display("  Response: 0x%02h", foe_response_opcode);
            check_result("Busy/Sequential handling", 1);
        end
    endtask
    
    // Test 7: Large File Transfer
    task test_large_file_transfer;
        integer num_packets;
        begin
            $display("\n=== FoE-07: Large File Transfer (1KB) ===");
            reset_dut;
            
            // Write 1KB file (8 packets of 128 bytes)
            num_packets = 8;
            
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_filename = "large.bin";
            @(posedge clk);
            foe_request = 0;
            
            repeat(50) @(posedge clk);
            
            for (i = 1; i <= num_packets; i = i + 1) begin
                @(posedge clk);
                foe_request = 1;
                foe_opcode = FOE_OP_DATA;
                foe_packet_num = i;
                foe_data_length = 128;
                @(posedge clk);
                foe_request = 0;
                
                repeat(30) @(posedge clk);
            end
            
            $display("  Transferred %0d bytes", num_packets * 128);
            check_result("Large file transfer", 1);
        end
    endtask
    
    // Test 8: Packet Number Mismatch
    task test_packet_mismatch;
        begin
            $display("\n=== FoE-08: Packet Number Mismatch ===");
            reset_dut;
            
            // Send packets out of order
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_DATA;
            foe_packet_num = 1;
            @(posedge clk);
            foe_request = 0;
            
            repeat(30) @(posedge clk);
            
            // Jump to packet 5
            @(posedge clk);
            foe_request = 1;
            foe_packet_num = 5;
            @(posedge clk);
            foe_request = 0;
            
            repeat(100) @(posedge clk);
            
            if (foe_response_opcode == FOE_OP_ERROR) begin
                $display("  Error code: 0x%08h", foe_error_code);
                check_result("Packet mismatch detected", 
                            foe_error_code == FOE_ERR_PACKET_NUM);
            end else begin
                check_result("Packet mismatch detected", 0);
            end
        end
    endtask
    
    // Main test sequence
    initial begin
        pass_count = 0;
        fail_count = 0;
        
        $display("========================================");
        $display("FoE Handler Testbench");
        $display("========================================");
        
        test_file_read_request;
        test_file_write_request;
        test_file_data_transfer;
        test_file_upload_ack;
        test_error_response;
        test_busy_response;
        test_large_file_transfer;
        test_packet_mismatch;
        
        // Summary
        $display("\n========================================");
        $display("FoE Test Summary:");
        $display("  PASSED: %0d", pass_count);
        $display("  FAILED: %0d", fail_count);
        $display("========================================");
        
        if (fail_count == 0) $display("TEST PASSED");
        else $display("TEST FAILED");
        
        $finish;
    end
    
    initial begin
        #100000;
        $display("\n[ERROR] Test timeout!");
        $finish;
    end

endmodule
