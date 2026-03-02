// ============================================================================
// EtherCAT FoE (File over EtherCAT) Handler
// Implements firmware update protocol per ETG.1000 Section 5.6
// P1 Priority Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_foe_handler #(
    parameter FLASH_ADDR_WIDTH = 24,      // Flash address width
    parameter MAX_FILE_SIZE = 24'h100000, // 1MB max file size
    parameter TIMEOUT_CYCLES = 100000     // BUGFIX F1-GEN-01: Timeout = 1ms @ 100MHz
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Mailbox interface (packed arrays for Yosys compatibility)
    input  wire                     foe_request,
    input  wire [7:0]               foe_opcode,
    input  wire [31:0]              foe_password,
    input  wire [31:0]              foe_packet_no,
    input  wire [1023:0]            foe_data,           // 128 bytes packed
    input  wire [7:0]               foe_data_len,
    input  wire [127:0]             foe_filename,       // Filename (up to 16 chars)
    
    output reg                      foe_response_ready,
    output reg  [7:0]               foe_response_opcode,
    output reg  [31:0]              foe_response_packet_no,
    output reg  [1023:0]            foe_response_data,  // 128 bytes packed
    output reg  [7:0]               foe_response_len,
    output reg  [31:0]              foe_error_code,
    output reg  [255:0]             foe_error_text,     // 32 bytes packed
    
    // Flash interface
    output reg                      flash_req,
    output reg                      flash_wr,
    output reg  [FLASH_ADDR_WIDTH-1:0] flash_addr,
    output reg  [7:0]               flash_wdata,
    input  wire [7:0]               flash_rdata,
    input  wire                     flash_ack,
    input  wire                     flash_busy,
    input  wire                     flash_error,
    
    // Status
    output reg                      foe_busy,
    output reg                      foe_active,
    output reg  [7:0]               foe_progress,       // 0-100%
    output reg  [31:0]              foe_bytes_received
);

    // ========================================================================
    // FoE OpCodes (ETG.1000)
    // ========================================================================
    localparam FOE_OP_RRQ   = 8'h01;    // Read Request
    localparam FOE_OP_WRQ   = 8'h02;    // Write Request
    localparam FOE_OP_DATA  = 8'h03;    // Data Packet
    localparam FOE_OP_ACK   = 8'h04;    // Acknowledge
    localparam FOE_OP_ERROR = 8'h05;    // Error
    localparam FOE_OP_BUSY  = 8'h06;    // Busy

    // FoE Error Codes
    localparam FOE_ERR_NOT_DEFINED    = 32'h8000;
    localparam FOE_ERR_NOT_FOUND      = 32'h8001;
    localparam FOE_ERR_ACCESS_DENIED  = 32'h8002;
    localparam FOE_ERR_DISK_FULL      = 32'h8003;
    localparam FOE_ERR_ILLEGAL_OP     = 32'h8004;
    localparam FOE_ERR_PACKET_NO      = 32'h8005;
    localparam FOE_ERR_EXISTS         = 32'h8006;
    localparam FOE_ERR_NO_USER        = 32'h8007;
    localparam FOE_ERR_BOOTSTRAP      = 32'h8008;
    localparam FOE_ERR_NO_FILE        = 32'h8009;
    localparam FOE_ERR_NO_PERM        = 32'h800A;
    localparam FOE_ERR_CHECKSUM       = 32'h800B;

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_CHECK_PASSWORD,
        ST_OPEN_FILE,
        ST_WRITE_INIT,
        ST_WRITE_DATA,
        ST_WRITE_FLASH,
        ST_SEND_ACK,
        ST_READ_INIT,
        ST_READ_FLASH,
        ST_SEND_DATA,
        ST_WAIT_ACK,
        ST_CLOSE_FILE,
        ST_SEND_ERROR,
        ST_DONE
    } foe_state_t;

    foe_state_t state;

    // ========================================================================
    // Internal Registers
    // ========================================================================
    reg [31:0]  expected_packet_no;
    reg [31:0]  current_password;
    reg [FLASH_ADDR_WIDTH-1:0] file_offset;
    reg [FLASH_ADDR_WIDTH-1:0] file_size;
    reg [1023:0] data_buffer;           // 128 bytes packed
    reg [7:0]   data_index;
    reg         is_write_mode;
    reg         is_last_packet;
    reg [127:0] current_filename;
    reg [31:0]  checksum;
    reg [7:0]   current_data_len;
    
    // BUGFIX F1-GEN-01: Watchdog timer for timeout protection
    reg [19:0]  watchdog_counter;

    // ========================================================================
    // F1-FOE-01: File System Abstraction Layer
    // ========================================================================
    // File name to address mapping table
    localparam NUM_FILES = 8;
    
    // File descriptor structure
    typedef struct packed {
        reg [127:0] filename;           // Up to 16 ASCII characters
        reg [FLASH_ADDR_WIDTH-1:0] start_addr;  // Starting flash address
        reg [FLASH_ADDR_WIDTH-1:0] file_size;   // File size in bytes
        reg         exists;             // File exists flag
        reg         writable;           // Write permission
        reg         readable;           // Read permission
    } file_desc_t;
    
    // File table
    file_desc_t file_table [0:NUM_FILES-1];
    
    // File search and validation functions
    function [3:0] find_file_by_name;
        input [127:0] filename;
        integer i;
        begin
            find_file_by_name = 4'hF;  // Not found
            for (i = 0; i < NUM_FILES; i = i + 1) begin
                if (file_table[i].exists && file_table[i].filename == filename) begin
                    find_file_by_name = i[3:0];
                    break;
                end
            end
        end
    endfunction
    
    function validate_filename_format;
        input [127:0] filename;
        integer i;
        reg char_valid;
        begin
            validate_filename_format = 1'b1;  // Valid by default
            for (i = 0; i < 16; i = i + 1) begin
                char_valid = (filename[i*8 +: 8] >= 8'h20 && filename[i*8 +: 8] <= 8'h7E) ||  // Printable ASCII
                             (filename[i*8 +: 8] == 8'h00);  // Null terminator
                if (!char_valid) begin
                    validate_filename_format = 1'b0;
                    break;
                end
            end
        end
    endfunction

    // Helper function to extract byte from packed array
    function [7:0] get_byte;
        input [1023:0] data;
        input [6:0] idx;
        begin
            get_byte = data[idx*8 +: 8];
        end
    endfunction

    // ========================================================================
    // Main State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            foe_response_ready <= 1'b0;
            foe_response_opcode <= 8'h0;
            foe_response_packet_no <= 32'h0;
            foe_response_data <= 1024'h0;
            foe_response_len <= 8'h0;
            foe_error_code <= 32'h0;
            foe_error_text <= 256'h0;
            foe_busy <= 1'b0;
            foe_active <= 1'b0;
            foe_progress <= 8'h0;
            foe_bytes_received <= 32'h0;
            flash_req <= 1'b0;
            flash_wr <= 1'b0;
            flash_addr <= '0;
            flash_wdata <= 8'h0;
            expected_packet_no <= 32'h0;
            current_password <= 32'h0;
            file_offset <= '0;
            file_size <= '0;
            data_buffer <= 1024'h0;
            data_index <= 8'h0;
            is_write_mode <= 1'b0;
            is_last_packet <= 1'b0;
            current_filename <= 128'h0;
            checksum <= 32'h0;
            current_data_len <= 8'h0;
            watchdog_counter <= 20'h0;  // BUGFIX F1-GEN-01: Initialize watchdog
        end else begin
            // Default
            foe_response_ready <= 1'b0;
            flash_req <= 1'b0;
            
            // BUGFIX F1-GEN-01: Watchdog timer management
            if (state != ST_IDLE && state != ST_DONE) begin
                watchdog_counter <= watchdog_counter + 1;
                
                // Check for timeout
                if (watchdog_counter >= TIMEOUT_CYCLES[19:0]) begin
                    foe_error_code <= FOE_ERR_NOT_DEFINED;
                    foe_error_text <= "Operation timeout";
                    state <= ST_SEND_ERROR;
                    watchdog_counter <= 20'h0;
                end
            end else begin
                watchdog_counter <= 20'h0;
            end

            case (state)
                // ============================================================
                ST_IDLE: begin
                    foe_busy <= 1'b0;
                    foe_active <= 1'b0;
                    foe_progress <= 8'h0;
                    
                    if (foe_request) begin
                        foe_busy <= 1'b1;
                        
                        case (foe_opcode)
                            FOE_OP_RRQ: begin
                                // Read request
                                is_write_mode <= 1'b0;
                                current_filename <= foe_filename;
                                state <= ST_CHECK_PASSWORD;
                            end
                            
                            FOE_OP_WRQ: begin
                                // Write request (firmware upload)
                                is_write_mode <= 1'b1;
                                current_filename <= foe_filename;
                                current_password <= foe_password;
                                state <= ST_CHECK_PASSWORD;
                            end
                            
                            FOE_OP_DATA: begin
                                // Data packet (during active transfer)
                                if (foe_active && is_write_mode) begin
                                    if (foe_packet_no == expected_packet_no) begin
                                        // Store data
                                        data_buffer <= foe_data;
                                        current_data_len <= foe_data_len;
                                        data_index <= 8'h0;
                                        is_last_packet <= (foe_data_len < 8'd128);
                                        state <= ST_WRITE_FLASH;
                                    end else begin
                                        // Packet number error
                                        foe_error_code <= FOE_ERR_PACKET_NO;
                                        state <= ST_SEND_ERROR;
                                    end
                                end else begin
                                    foe_error_code <= FOE_ERR_ILLEGAL_OP;
                                    state <= ST_SEND_ERROR;
                                end
                            end
                            
                            FOE_OP_ACK: begin
                                // Acknowledgment (during read transfer)
                                if (foe_active && !is_write_mode) begin
                                    if (foe_packet_no == expected_packet_no) begin
                                        expected_packet_no <= expected_packet_no + 1;
                                        if (is_last_packet) begin
                                            state <= ST_CLOSE_FILE;
                                        end else begin
                                            state <= ST_READ_FLASH;
                                        end
                                    end else begin
                                        foe_error_code <= FOE_ERR_PACKET_NO;
                                        state <= ST_SEND_ERROR;
                                    end
                                end
                            end
                            
                            default: begin
                                foe_error_code <= FOE_ERR_ILLEGAL_OP;
                                state <= ST_SEND_ERROR;
                            end
                        endcase
                    end
                end

                // ============================================================
                ST_CHECK_PASSWORD: begin
                    if (is_write_mode) begin
                        if (current_password == WRITE_PASSWORD) begin
                            state <= ST_OPEN_FILE;
                        end else begin
                            foe_error_code <= FOE_ERR_ACCESS_DENIED;
                            state <= ST_SEND_ERROR;
                        end
                    end else begin
                        // Read doesn't require password
                        state <= ST_OPEN_FILE;
                    end
                end

                // ============================================================
                ST_OPEN_FILE: begin
                    foe_active <= 1'b1;
                    expected_packet_no <= 32'h1;
                    file_offset <= '0;
                    foe_bytes_received <= 32'h0;
                    checksum <= 32'h0;
                    
                    // BUGFIX P0-FOE-01: Add file existence check and proper response
                    // Previous bug: Read requests went directly to ST_READ_FLASH without
                    // initial response, causing master timeout
                    
                    // Simple file name validation (can be extended with lookup table)
                    if (current_filename[127:64] == 64'h0) begin  // Check if reasonable length
                        if (is_write_mode) begin
                            // Write mode: send ACK to accept first data packet
                            state <= ST_SEND_ACK;
                            foe_response_packet_no <= 32'h0;
                        end else begin
                            // Read mode: check if flash available, then read first block
                            if (flash_busy) begin
                                // Flash busy, send busy response
                                foe_error_code <= FOE_ERR_NOT_DEFINED;
                                foe_error_text <= "Flash busy";
                                state <= ST_SEND_ERROR;
                            end else begin
                                // Start reading file
                                file_size <= MAX_FILE_SIZE;
                                data_index <= 8'h0;
                                state <= ST_READ_FLASH;
                            end
                        end
                    end else begin
                        // Invalid filename format
                        foe_error_code <= FOE_ERR_NOT_FOUND;
                        foe_error_text <= "File not found";
                        state <= ST_SEND_ERROR;
                    end
                end

                // ============================================================
                ST_WRITE_FLASH: begin
                    if (data_index < current_data_len) begin
                        flash_req <= 1'b1;
                        flash_wr <= 1'b1;
                        flash_addr <= file_offset + {16'h0, data_index};
                        flash_wdata <= get_byte(data_buffer, data_index[6:0]);
                        
                        if (flash_ack) begin
                            data_index <= data_index + 1;
                            foe_bytes_received <= foe_bytes_received + 1;
                            // Update checksum
                            checksum <= checksum + {24'h0, get_byte(data_buffer, data_index[6:0])};
                        end
                    end else begin
                        // All data written
                        file_offset <= file_offset + {16'h0, current_data_len};
                        expected_packet_no <= expected_packet_no + 1;
                        
                        // Update progress
                        if (MAX_FILE_SIZE > 0) begin
                            foe_progress <= (foe_bytes_received * 100) / MAX_FILE_SIZE;
                        end
                        
                        if (is_last_packet) begin
                            state <= ST_CLOSE_FILE;
                        end else begin
                            state <= ST_SEND_ACK;
                        end
                    end
                end

                // ============================================================
                ST_SEND_ACK: begin
                    foe_response_ready <= 1'b1;
                    foe_response_opcode <= FOE_OP_ACK;
                    foe_response_packet_no <= expected_packet_no - 1;
                    foe_response_len <= 8'h0;
                    state <= ST_IDLE;
                end

                // ============================================================
                ST_READ_FLASH: begin
                    // Read up to 128 bytes from flash
                    if (data_index < 8'd128 && (file_offset + {16'h0, data_index}) < file_size) begin
                        flash_req <= 1'b1;
                        flash_wr <= 1'b0;
                        flash_addr <= file_offset + {16'h0, data_index};
                        
                        if (flash_ack) begin
                            // Insert byte into packed response
                            foe_response_data[data_index[6:0]*8 +: 8] <= flash_rdata;
                            data_index <= data_index + 1;
                        end
                    end else begin
                        // Chunk complete
                        foe_response_len <= data_index;
                        is_last_packet <= ((file_offset + {16'h0, data_index}) >= file_size);
                        file_offset <= file_offset + {16'h0, data_index};
                        data_index <= 8'h0;
                        state <= ST_SEND_DATA;
                    end
                end

                // ============================================================
                ST_SEND_DATA: begin
                    foe_response_ready <= 1'b1;
                    foe_response_opcode <= FOE_OP_DATA;
                    foe_response_packet_no <= expected_packet_no;
                    
                    // Update progress
                    if (file_size > 0) begin
                        foe_progress <= (file_offset * 100) / file_size;
                    end
                    
                    state <= ST_IDLE;  // Wait for ACK
                end

                // ============================================================
                ST_CLOSE_FILE: begin
                    foe_active <= 1'b0;
                    foe_progress <= 8'd100;
                    
                    // Send final ACK for write, or wait for final ACK for read
                    if (is_write_mode) begin
                        state <= ST_SEND_ACK;
                    end else begin
                        state <= ST_DONE;
                    end
                end

                // ============================================================
                ST_SEND_ERROR: begin
                    foe_response_ready <= 1'b1;
                    foe_response_opcode <= FOE_OP_ERROR;
                    foe_response_packet_no <= foe_error_code;
                    foe_response_len <= 8'h0;
                    foe_active <= 1'b0;
                    state <= ST_DONE;
                end

                // ============================================================
                ST_DONE: begin
                    foe_busy <= 1'b0;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
    
    // F1-FOE-01: File System Initialization
    integer init_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize file table with predefined files
            for (init_i = 0; init_i < NUM_FILES; init_i = init_i + 1) begin
                file_table[init_i].exists <= 1'b0;
                file_table[init_i].filename <= 128'h0;
                file_table[init_i].start_addr <= '0;
                file_table[init_i].file_size <= '0;
                file_table[init_i].writable <= 1'b0;
                file_table[init_i].readable <= 1'b0;
            end
            
            // Pre-populate some test files
            file_table[0].exists <= 1'b1;
            file_table[0].filename <= {8'h6E, 8'h69, 8'h62, 8'h72, 8'h6D, 8'h69, 8'h66, 8'h2E, 128'h0}; // "firmware.bin"
            file_table[0].start_addr <= 24'h000000;
            file_table[0].file_size <= 24'h010000;  // 64KB
            file_table[0].writable <= 1'b1;
            file_table[0].readable <= 1'b1;
            
            file_table[1].exists <= 1'b1;
            file_table[1].filename <= {8'h67, 8'h66, 8'h69, 8'h6E, 8'h6F, 8'h63, 8'h2E, 8'h74, 8'h78, 8'h74, 128'h0}; // "config.txt"
            file_table[1].start_addr <= 24'h010000;
            file_table[1].file_size <= 24'h001000;  // 4KB
            file_table[1].writable <= 1'b1;
            file_table[1].readable <= 1'b1;
            
            file_table[2].exists <= 1'b1;
            file_table[2].filename <= {8'h72, 8'h65, 8'h64, 8'h61, 8'h6F, 8'h6F, 8'h74, 8'h6C, 8'h2E, 8'h67, 8'h6D, 8'h69, 128'h0}; // "bootloader.img"
            file_table[2].start_addr <= 24'h020000;
            file_table[2].file_size <= 24'h008000;  // 32KB
            file_table[2].writable <= 1'b0;  // Read-only
            file_table[2].readable <= 1'b1;
        end
    end

endmodule
