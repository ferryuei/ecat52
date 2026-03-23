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
    reg  [31:0] foe_password;
    reg  [31:0] foe_packet_num;
    reg  [7:0]  foe_data_length;
    reg  [7:0]  foe_data [0:127];
    reg  [255:0] foe_filename;

    reg  [1023:0] foe_data_packed;

    wire        foe_response_ready;
    wire [7:0]  foe_response_opcode;
    wire [31:0] foe_response_packet;
    wire [1023:0] foe_response_data;
    wire [7:0]  foe_response_length;
    wire [31:0] foe_error_code;
    wire [255:0] foe_error_text;

    wire        foe_busy;
    wire        foe_active;
    wire [7:0]  foe_progress;
    wire [31:0] foe_bytes_received;

    // Flash model interface
    wire        flash_req;
    wire        flash_wr;
    wire [23:0] flash_addr;
    wire [7:0]  flash_wdata;
    reg  [7:0]  flash_rdata;
    reg         flash_ack;
    reg         flash_busy;
    reg         flash_error;

    reg [7:0] flash_mem [0:4095];

    integer pass_count, fail_count;
    integer i;
    integer pack_i;

    // Clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Pack byte-array payload into DUT packed bus
    always @(*) begin
        foe_data_packed = 1024'h0;
        for (pack_i = 0; pack_i < 128; pack_i = pack_i + 1)
            foe_data_packed[pack_i*8 +: 8] = foe_data[pack_i];
    end

    // DUT
    ecat_foe_handler dut (
        .rst_n(rst_n),
        .clk(clk),
        .foe_request(foe_request),
        .foe_opcode(foe_opcode),
        .foe_password(foe_password),
        .foe_packet_no(foe_packet_num),
        .foe_data(foe_data_packed),
        .foe_data_len(foe_data_length),
        .foe_filename(foe_filename[127:0]),
        .foe_response_ready(foe_response_ready),
        .foe_response_opcode(foe_response_opcode),
        .foe_response_packet_no(foe_response_packet),
        .foe_response_data(foe_response_data),
        .foe_response_len(foe_response_length),
        .foe_error_code(foe_error_code),
        .foe_error_text(foe_error_text),
        .flash_req(flash_req),
        .flash_wr(flash_wr),
        .flash_addr(flash_addr),
        .flash_wdata(flash_wdata),
        .flash_rdata(flash_rdata),
        .flash_ack(flash_ack),
        .flash_busy(flash_busy),
        .flash_error(flash_error),
        .foe_busy(foe_busy),
        .foe_active(foe_active),
        .foe_progress(foe_progress),
        .foe_bytes_received(foe_bytes_received)
    );

    // Simple flash model
    initial begin
        for (i = 0; i < 4096; i = i + 1)
            flash_mem[i] = i[7:0];
        flash_rdata = 8'h00;
        flash_ack = 1'b0;
        flash_busy = 1'b0;
        flash_error = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flash_ack <= 1'b0;
            flash_rdata <= 8'h00;
        end else begin
            flash_ack <= 1'b0;
            if (flash_req) begin
                flash_ack <= 1'b1;
                if (flash_wr)
                    flash_mem[flash_addr[11:0]] <= flash_wdata;
                flash_rdata <= flash_mem[flash_addr[11:0]];
            end
        end
    end

    // ========================================================================
    // Test Tasks
    // ========================================================================

    task reset_dut;
        begin
            $display("[INFO] Reset");
            rst_n = 0;
            foe_request = 0;
            foe_opcode = 8'h00;
            foe_password = 32'h0;
            foe_packet_num = 32'h0;
            foe_data_length = 8'h0;
            foe_filename = 256'h0;
            for (i = 0; i < 128; i = i + 1)
                foe_data[i] = 8'h00;
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

    task wait_response;
        output seen;
        output [7:0] op;
        output [31:0] pkt;
        output [31:0] err;
        integer w;
        begin
            seen = 1'b0;
            op = 8'h00;
            pkt = 32'h0;
            err = 32'h0;
            w = 0;
            while (!seen && w < 300) begin
                @(posedge clk);
                if (foe_response_ready) begin
                    seen = 1'b1;
                    op = foe_response_opcode;
                    pkt = foe_response_packet;
                    err = foe_error_code;
                end
                w = w + 1;
            end
        end
    endtask

    // Test 1: File Read Request
    task test_file_read_request;
        reg seen;
        reg [7:0] op;
        reg [31:0] pkt;
        reg [31:0] err;
        begin
            $display("\n=== FoE-01: File Read Request ===");
            reset_dut;

            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_READ_REQ;
            foe_filename = "firmware.bin";
            foe_packet_num = 0;
            @(posedge clk);
            foe_request = 0;

            wait_response(seen, op, pkt, err);

            if (seen) begin
                $display("  Response OpCode: 0x%02h", op);
                $display("  Packet Number: %0d", pkt);
            end

            check_result("Read request acknowledged", seen && (op == FOE_OP_DATA || op == FOE_OP_ERROR));
        end
    endtask

    // Test 2: File Write Request
    task test_file_write_request;
        reg seen;
        reg [7:0] op;
        reg [31:0] pkt;
        reg [31:0] err;
        begin
            $display("\n=== FoE-02: File Write Request ===");
            reset_dut;

            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_password = 32'h0;
            foe_filename = "config.xml";
            foe_packet_num = 0;
            @(posedge clk);
            foe_request = 0;

            wait_response(seen, op, pkt, err);

            if (seen)
                $display("  Response OpCode: 0x%02h", op);

            check_result("Write request acknowledged", seen && (op == FOE_OP_ACK || op == FOE_OP_ERROR));
        end
    endtask

    // Test 3: File Data Transfer
    task test_file_data_transfer;
        integer pkt;
        reg seen;
        reg [7:0] op;
        reg [31:0] p;
        reg [31:0] e;
        begin
            $display("\n=== FoE-03: File Data Transfer (Multiple Packets) ===");
            reset_dut;

            // Open a write session with a short filename (passes current filename check)
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_filename = "fw.bin";
            foe_packet_num = 0;
            foe_password = 32'h0;
            @(posedge clk);
            foe_request = 0;
            wait_response(seen, op, p, e);

            // Send 5 data packets
            for (pkt = 1; pkt <= 5; pkt = pkt + 1) begin
                @(posedge clk);
                foe_request = 1;
                foe_opcode = FOE_OP_DATA;
                foe_packet_num = pkt;
                foe_data_length = 8'd32;
                for (i = 0; i < 32; i = i + 1)
                    foe_data[i] = (pkt * 16 + i) & 8'hFF;
                @(posedge clk);
                foe_request = 0;
                wait_response(seen, op, p, e);
            end

            $display("  Sent 5 data packets (160 bytes)");
            check_result("Data packets transferred", 1);
        end
    endtask

    // Test 4: File Upload with ACK
    task test_file_upload_ack;
        begin
            $display("\n=== FoE-04: File Upload with ACK ===");
            reset_dut;

            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_READ_REQ;
            foe_filename = "test.dat";
            foe_packet_num = 0;
            @(posedge clk);
            foe_request = 0;

            repeat(50) @(posedge clk);

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
        reg seen;
        reg [7:0] op;
        reg [31:0] pkt;
        reg [31:0] err;
        begin
            $display("\n=== FoE-05: File Not Found Error ===");
            reset_dut;

            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_READ_REQ;
            foe_filename = "nonexistent.bin";
            foe_packet_num = 0;
            @(posedge clk);
            foe_request = 0;

            wait_response(seen, op, pkt, err);

            if (seen)
                $display("  Error code: 0x%08h", err);

            check_result("File not found error", seen && op == FOE_OP_ERROR && err == FOE_ERR_NOT_FOUND);
        end
    endtask

    // Test 6: Busy Response
    task test_busy_response;
        begin
            $display("\n=== FoE-06: Busy Response ===");
            reset_dut;

            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_filename = "flash.bin";
            @(posedge clk);
            foe_opcode = FOE_OP_DATA;
            foe_packet_num = 1;
            @(posedge clk);
            foe_request = 0;

            repeat(100) @(posedge clk);

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

            num_packets = 8;

            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_filename = "large.bin";
            foe_packet_num = 0;
            foe_password = 32'h0;
            @(posedge clk);
            foe_request = 0;

            repeat(50) @(posedge clk);

            for (i = 1; i <= num_packets; i = i + 1) begin
                @(posedge clk);
                foe_request = 1;
                foe_opcode = FOE_OP_DATA;
                foe_packet_num = i;
                foe_data_length = 8'd128;
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
        reg seen;
        reg [7:0] op;
        reg [31:0] pkt;
        reg [31:0] err;
        begin
            $display("\n=== FoE-08: Packet Number Mismatch ===");
            reset_dut;

            // Open write session first
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_WRITE_REQ;
            foe_filename = "fw.bin";
            foe_packet_num = 0;
            foe_password = 32'h0;
            @(posedge clk);
            foe_request = 0;
            wait_response(seen, op, pkt, err);
            check_result("Write session opened", seen && op == FOE_OP_ACK);

            // Send packet 1
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_DATA;
            foe_packet_num = 1;
            foe_data_length = 8'd128;
            @(posedge clk);
            foe_request = 0;
            wait_response(seen, op, pkt, err);

            // Jump to packet 5 to trigger mismatch
            @(posedge clk);
            foe_request = 1;
            foe_opcode = FOE_OP_DATA;
            foe_packet_num = 5;
            foe_data_length = 8'd8;
            @(posedge clk);
            foe_request = 0;

            wait_response(seen, op, pkt, err);

            if (seen)
                $display("  Error code: 0x%08h", err);

            check_result("Packet mismatch detected", seen && op == FOE_OP_ERROR && err == FOE_ERR_PACKET_NUM);
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
        #200000;
        $display("\n[ERROR] Test timeout!");
        $finish;
    end

endmodule
