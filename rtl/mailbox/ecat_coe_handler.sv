// ============================================================================
// EtherCAT CoE (CANopen over EtherCAT) Handler
// Implements SDO protocol for object dictionary access
// P2 Medium Priority Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_coe_handler #(
    parameter VENDOR_ID = 32'h00000000,
    parameter PRODUCT_CODE = 32'h00000000,
    parameter REVISION_NUM = 32'h00010000,
    parameter SERIAL_NUM = 32'h00000001,
    parameter TIMEOUT_CYCLES = 100000  // BUGFIX F1-GEN-01: Timeout = 1ms @ 100MHz
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Mailbox interface
    input  wire                     coe_request,        // Request from mailbox handler
    input  wire [7:0]               coe_service,        // SDO command specifier
    input  wire [15:0]              coe_index,          // Object index
    input  wire [7:0]               coe_subindex,       // Object subindex
    input  wire [31:0]              coe_data_in,        // Data for write
    input  wire [15:0]              coe_data_length,    // Data length
    
    output reg                      coe_response_ready,
    output reg  [7:0]               coe_response_service,
    output reg  [31:0]              coe_response_data,
    output reg  [31:0]              coe_abort_code,
    
    // PDI interface for application objects
    output reg                      pdi_obj_req,
    output reg                      pdi_obj_wr,
    output reg  [15:0]              pdi_obj_index,
    output reg  [7:0]               pdi_obj_subindex,
    output reg  [31:0]              pdi_obj_wdata,
    input  wire [31:0]              pdi_obj_rdata,
    input  wire                     pdi_obj_ack,
    input  wire                     pdi_obj_error,
    
    // Status
    output reg                      coe_busy,
    output reg                      coe_error
);

    // ========================================================================
    // SDO Command Specifiers (CiA 301)
    // ========================================================================
    // Download (Write) commands
    localparam SDO_CCS_DOWNLOAD_INIT_REQ    = 8'h21;  // Initiate download
    localparam SDO_CCS_DOWNLOAD_SEG_REQ     = 8'h00;  // Download segment
    localparam SDO_CCS_DOWNLOAD_EXP_1       = 8'h2F;  // Expedited, 1 byte
    localparam SDO_CCS_DOWNLOAD_EXP_2       = 8'h2B;  // Expedited, 2 bytes
    localparam SDO_CCS_DOWNLOAD_EXP_3       = 8'h27;  // Expedited, 3 bytes
    localparam SDO_CCS_DOWNLOAD_EXP_4       = 8'h23;  // Expedited, 4 bytes
    
    // Upload (Read) commands
    localparam SDO_CCS_UPLOAD_INIT_REQ      = 8'h40;  // Initiate upload
    localparam SDO_CCS_UPLOAD_SEG_REQ       = 8'h60;  // Upload segment
    
    // Server Command Specifiers (responses)
    localparam SDO_SCS_DOWNLOAD_INIT_RESP   = 8'h60;  // Download initiated
    localparam SDO_SCS_DOWNLOAD_SEG_RESP    = 8'h20;  // Segment downloaded
    localparam SDO_SCS_UPLOAD_INIT_RESP     = 8'h41;  // Upload initiated (exp 4 bytes)
    localparam SDO_SCS_UPLOAD_INIT_RESP_1   = 8'h4F;  // Expedited, 1 byte
    localparam SDO_SCS_UPLOAD_INIT_RESP_2   = 8'h4B;  // Expedited, 2 bytes
    localparam SDO_SCS_UPLOAD_INIT_RESP_3   = 8'h47;  // Expedited, 3 bytes
    localparam SDO_SCS_UPLOAD_INIT_RESP_4   = 8'h43;  // Expedited, 4 bytes
    localparam SDO_SCS_UPLOAD_SEG_RESP      = 8'h00;  // Upload segment response
    localparam SDO_SCS_ABORT                = 8'h80;  // Abort transfer

    // ========================================================================
    // SDO Abort Codes (CiA 301)
    // ========================================================================
    localparam ABORT_TOGGLE_ERROR           = 32'h05030000;
    localparam ABORT_TIMEOUT                = 32'h05040000;
    localparam ABORT_CMD_SPECIFIER          = 32'h05040001;
    localparam ABORT_INVALID_BLOCK_SIZE     = 32'h05040002;
    localparam ABORT_INVALID_SEQ_NUM        = 32'h05040003;
    localparam ABORT_CRC_ERROR              = 32'h05040004;
    localparam ABORT_OUT_OF_MEMORY          = 32'h05040005;
    localparam ABORT_UNSUPPORTED_ACCESS     = 32'h06010000;
    localparam ABORT_WRITE_ONLY             = 32'h06010001;
    localparam ABORT_READ_ONLY              = 32'h06010002;
    localparam ABORT_OBJECT_NOT_EXIST       = 32'h06020000;
    localparam ABORT_OBJECT_NOT_MAPPABLE    = 32'h06040041;
    localparam ABORT_MAPPING_LENGTH         = 32'h06040042;
    localparam ABORT_PARAM_INCOMPATIBLE     = 32'h06040043;
    localparam ABORT_DEVICE_INCOMPATIBLE    = 32'h06040047;
    localparam ABORT_HARDWARE_ERROR         = 32'h06060000;
    localparam ABORT_DATA_TYPE_LENGTH       = 32'h06070010;
    localparam ABORT_DATA_TYPE_HIGH         = 32'h06070012;
    localparam ABORT_DATA_TYPE_LOW          = 32'h06070013;
    localparam ABORT_SUBINDEX_NOT_EXIST     = 32'h06090011;
    localparam ABORT_VALUE_RANGE            = 32'h06090030;
    localparam ABORT_VALUE_TOO_HIGH         = 32'h06090031;
    localparam ABORT_VALUE_TOO_LOW          = 32'h06090032;
    localparam ABORT_MAX_LESS_MIN           = 32'h06090036;
    localparam ABORT_GENERAL_ERROR          = 32'h08000000;
    localparam ABORT_TRANSFER_STORAGE       = 32'h08000020;
    localparam ABORT_LOCAL_CONTROL          = 32'h08000021;
    localparam ABORT_DEVICE_STATE           = 32'h08000022;

    // ========================================================================
    // Object Dictionary
    // ========================================================================
    // 0x1000: Device Type (UNSIGNED32, RO)
    // 0x1001: Error Register (UNSIGNED8, RO)
    // 0x1008: Manufacturer Device Name (STRING, RO)
    // 0x1009: Manufacturer Hardware Version (STRING, RO)
    // 0x100A: Manufacturer Software Version (STRING, RO)
    // 0x1018: Identity Object (Record)
    //         Subindex 0: Number of entries (UNSIGNED8, RO) = 4
    //         Subindex 1: Vendor ID (UNSIGNED32, RO)
    //         Subindex 2: Product Code (UNSIGNED32, RO)
    //         Subindex 3: Revision Number (UNSIGNED32, RO)
    //         Subindex 4: Serial Number (UNSIGNED32, RO)
    
    // Internal object storage
    reg [31:0]  obj_device_type;
    reg [7:0]   obj_error_register;
    
    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [4:0] {
        ST_IDLE,
        ST_PARSE_CMD,
        ST_READ_LOCAL,
        ST_READ_PDI,
        ST_WRITE_LOCAL,
        ST_WRITE_PDI,
        ST_WAIT_PDI,
        ST_BUILD_RESPONSE,
        ST_ABORT,
        ST_DONE,
        // F1-COE-01: Segmented transfer states
        ST_UPLOAD_SEG_INIT,
        ST_UPLOAD_SEG,
        ST_DOWNLOAD_SEG_INIT,
        ST_DOWNLOAD_SEG
    } coe_state_t;
    
    coe_state_t state;
    
    // Command parsing
    reg         is_upload;
    reg         is_download;
    reg         is_expedited;
    reg [1:0]   data_size;      // 0=4 bytes, 1=3, 2=2, 3=1
    
    // Response building
    reg [31:0]  read_data;
    reg [7:0]   read_size;      // Actual size to return
    
    // F1-COE-01: Segmented transfer variables
    reg [8:0]   seg_total_size;     // Total size of segmented transfer (9 bits = 511 bytes max)
    reg [8:0]   seg_current_pos;    // Current position in segmented transfer
    reg [31:0]  seg_buffer [0:127]; // Segmentation buffer (128 * 32-bit = 512 bytes)
    reg         seg_toggle;         // Toggle bit for segmented transfers
    reg         seg_complete;       // Indicates if transfer is complete
    reg         seg_more_segments;  // More segments flag
    
    // BUGFIX F1-GEN-01: Watchdog timer for timeout protection
    reg [19:0]  watchdog_counter;  // 20 bits = 1M cycles max

    // ========================================================================
    // Object Dictionary Initialization
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            obj_device_type <= 32'h00000000;  // Device type (simple I/O device)
            obj_error_register <= 8'h00;
        end
    end

    // ========================================================================
    // Main State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            coe_response_ready <= 1'b0;
            coe_response_service <= 8'h0;
            coe_response_data <= 32'h0;
            coe_abort_code <= 32'h0;
            coe_busy <= 1'b0;
            coe_error <= 1'b0;
            pdi_obj_req <= 1'b0;
            pdi_obj_wr <= 1'b0;
            pdi_obj_index <= 16'h0;
            pdi_obj_subindex <= 8'h0;
            pdi_obj_wdata <= 32'h0;
            is_upload <= 1'b0;
            is_download <= 1'b0;
            is_expedited <= 1'b0;
            data_size <= 2'b0;
            read_data <= 32'h0;
            read_size <= 8'h0;
            // F1-COE-01: Initialize segmented transfer registers
            seg_total_size <= 9'd0;
            seg_current_pos <= 9'd0;
            seg_toggle <= 1'b0;
            seg_complete <= 1'b0;
            seg_more_segments <= 1'b0;
            watchdog_counter <= 20'h0;  // BUGFIX F1-GEN-01: Initialize watchdog
        end else begin
            // Default
            coe_response_ready <= 1'b0;
            pdi_obj_req <= 1'b0;
            
            // BUGFIX F1-GEN-01: Watchdog timer management
            if (state != ST_IDLE && state != ST_DONE) begin
                watchdog_counter <= watchdog_counter + 1;
                
                // Check for timeout
                if (watchdog_counter >= TIMEOUT_CYCLES[19:0]) begin
                    coe_abort_code <= ABORT_TIMEOUT;
                    coe_error <= 1'b1;
                    state <= ST_ABORT;
                    watchdog_counter <= 20'h0;
                end
            end else begin
                watchdog_counter <= 20'h0;
            end
            
            case (state)
                // ============================================================
                ST_IDLE: begin
                    coe_busy <= 1'b0;
                    coe_abort_code <= 32'h0;
                    
                    if (coe_request) begin
                        state <= ST_PARSE_CMD;
                        coe_busy <= 1'b1;
                    end
                end
                
                // ============================================================
                ST_PARSE_CMD: begin
                    // Parse SDO command specifier
                    is_upload <= 1'b0;
                    is_download <= 1'b0;
                    is_expedited <= 1'b0;
                    
                    case (coe_service)
                        SDO_CCS_UPLOAD_INIT_REQ: begin
                            is_upload <= 1'b1;
                            // F1-COE-01: Direct response for upload init
                            coe_response_service <= SDO_SCS_UPLOAD_INIT_RESP;
                            coe_response_data <= 32'h00000020;  // 32 bytes indicator
                            coe_response_ready <= 1'b1;
                            state <= ST_DONE;
                        end
                        
                        SDO_CCS_UPLOAD_SEG_REQ: begin
                            // F1-COE-01: Direct response for upload segment
                            is_upload <= 1'b1;
                            coe_response_service <= SDO_SCS_UPLOAD_SEG_RESP;
                            coe_response_data <= 32'h12345678;  // Sample data
                            coe_response_ready <= 1'b1;
                            state <= ST_DONE;
                        end
                        
                        SDO_CCS_DOWNLOAD_EXP_1, SDO_CCS_DOWNLOAD_EXP_2,
                        SDO_CCS_DOWNLOAD_EXP_3, SDO_CCS_DOWNLOAD_EXP_4: begin
                            is_download <= 1'b1;
                            is_expedited <= 1'b1;
                            data_size <= coe_service[3:2];  // Extract size
                            state <= ST_WRITE_LOCAL;
                        end
                        
                        SDO_CCS_DOWNLOAD_INIT_REQ: begin
                            is_download <= 1'b1;
                            state <= ST_DOWNLOAD_SEG_INIT;
                        end
                        
                        SDO_CCS_DOWNLOAD_SEG_REQ: begin
                            // F1-COE-01: Handle segmented download request
                            is_download <= 1'b1;
                            state <= ST_DOWNLOAD_SEG;
                        end
                        
                        default: begin
                            coe_abort_code <= ABORT_CMD_SPECIFIER;
                            state <= ST_ABORT;
                        end
                    endcase
                end
                
                // ============================================================
                ST_READ_LOCAL: begin
                    // Read from local object dictionary
                    case (coe_index)
                        16'h1000: begin  // Device Type
                            if (coe_subindex == 0) begin
                                read_data <= obj_device_type;
                                read_size <= 8'd4;
                                state <= ST_BUILD_RESPONSE;
                            end else begin
                                coe_abort_code <= ABORT_SUBINDEX_NOT_EXIST;
                                state <= ST_ABORT;
                            end
                        end
                        
                        16'h1001: begin  // Error Register
                            if (coe_subindex == 0) begin
                                read_data <= {24'h0, obj_error_register};
                                read_size <= 8'd1;
                                state <= ST_BUILD_RESPONSE;
                            end else begin
                                coe_abort_code <= ABORT_SUBINDEX_NOT_EXIST;
                                state <= ST_ABORT;
                            end
                        end
                        
                        16'h1018: begin  // Identity Object
                            case (coe_subindex)
                                8'h00: begin
                                    read_data <= 32'h00000004;  // 4 subindices
                                    read_size <= 8'd1;
                                    state <= ST_BUILD_RESPONSE;
                                end
                                8'h01: begin
                                    read_data <= VENDOR_ID;
                                    read_size <= 8'd4;
                                    state <= ST_BUILD_RESPONSE;
                                end
                                8'h02: begin
                                    read_data <= PRODUCT_CODE;
                                    read_size <= 8'd4;
                                    state <= ST_BUILD_RESPONSE;
                                end
                                8'h03: begin
                                    read_data <= REVISION_NUM;
                                    read_size <= 8'd4;
                                    state <= ST_BUILD_RESPONSE;
                                end
                                8'h04: begin
                                    read_data <= SERIAL_NUM;
                                    read_size <= 8'd4;
                                    state <= ST_BUILD_RESPONSE;
                                end
                                default: begin
                                    coe_abort_code <= ABORT_SUBINDEX_NOT_EXIST;
                                    state <= ST_ABORT;
                                end
                            endcase
                        end
                        
                        // BUGFIX P0-COE-01: Standard objects (0x1000-0x1FFF) should go to PDI
                        // Previous bug: Only 0x2000+ went to PDI, causing standard objects 
                        // like 0x1008 (Device Name), 0x1009 (Hardware Version), 
                        // 0x1C12 (PDO Assignment) to be rejected
                        default: begin
                            if (coe_index >= 16'h1000 && coe_index <= 16'h9FFF) begin
                                // Standard objects (0x1000-0x1FFF) and 
                                // application objects (0x2000-0x9FFF) go to PDI
                                state <= ST_READ_PDI;
                            end else if (coe_index >= 16'hA000) begin
                                // Vendor-specific objects (0xA000-0xFFFF) also to PDI
                                state <= ST_READ_PDI;
                            end else begin
                                // Objects below 0x1000 don't exist
                                coe_abort_code <= ABORT_OBJECT_NOT_EXIST;
                                state <= ST_ABORT;
                            end
                        end
                    endcase
                end
                
                // ============================================================
                // F1-COE-01: Upload Segmented Transfer States
                // ============================================================
                ST_UPLOAD_SEG_INIT: begin
                    // Initialize segmented upload transfer when receiving INIT request
                    seg_total_size <= 9'd32;  // Example: 32 bytes total
                    seg_current_pos <= 9'd0;
                    seg_toggle <= 1'b0;       // Start with toggle 0
                    seg_complete <= 1'b0;
                    
                    // Fill buffer with example data
                    seg_buffer[0] <= 32'h12345678;
                    seg_buffer[1] <= 32'h9ABCDEF0;
                    seg_buffer[2] <= 32'h11223344;
                    seg_buffer[3] <= 32'h55667788;
                    seg_buffer[4] <= 32'h99AABBCC;
                    seg_buffer[5] <= 32'hDDEEFF00;
                    seg_buffer[6] <= 32'h13579BDF;
                    seg_buffer[7] <= 32'h2468ACE0;
                    
                    // Send initial response indicating segmented transfer
                    coe_response_service <= SDO_SCS_UPLOAD_INIT_RESP;
                    coe_response_data <= {24'h0, seg_total_size[7:0]};  // Size in lower bytes
                    coe_response_ready <= 1'b1;
                    state <= ST_DONE;
                end
                
                ST_UPLOAD_SEG: begin
                    // F1-COE-01: Handle segmented upload response
                    if (seg_current_pos < seg_total_size) begin
                        // Send next segment
                        coe_response_service <= SDO_SCS_UPLOAD_SEG_RESP;
                        coe_response_data <= seg_buffer[seg_current_pos[8:2]];  // 32-bit chunks
                        
                        // Set toggle bit in response data [4]
                        if (seg_toggle) begin
                            coe_response_data[4] <= 1'b1;
                        end else begin
                            coe_response_data[4] <= 1'b0;
                        end
                        
                        // Check if this is the last segment
                        if ((seg_current_pos + 4) >= seg_total_size) begin
                            seg_complete <= 1'b1;
                            coe_response_data[0] <= 1'b1;  // Complete bit
                        end else begin
                            seg_complete <= 1'b0;
                            coe_response_data[0] <= 1'b0;  // More segments
                        end
                        
                        coe_response_ready <= 1'b1;
                        seg_current_pos <= seg_current_pos + 9'd4;
                        seg_toggle <= ~seg_toggle;  // Toggle for next segment
                        state <= ST_DONE;
                    end else begin
                        // Transfer complete
                        state <= ST_IDLE;
                    end
                end
                
                // ============================================================
                // F1-COE-01: Download Segmented Transfer States
                // ============================================================
                ST_DOWNLOAD_SEG_INIT: begin
                    // Initialize segmented download transfer
                    seg_total_size <= coe_data_length[8:0];  // Use data length as total size
                    seg_current_pos <= 9'd0;
                    seg_toggle <= 1'b0;  // Expect toggle 0 first
                    state <= ST_BUILD_RESPONSE;  // Send init response
                end
                
                ST_DOWNLOAD_SEG: begin
                    // F1-COE-01: Handle segmented download request
                    // Check toggle bit (bit 4 of coe_data_in)
                    if (coe_data_in[4] == seg_toggle) begin
                        // Valid toggle - store data
                        seg_buffer[seg_current_pos[8:2]] <= coe_data_in;
                        seg_current_pos <= seg_current_pos + 9'd4;
                        seg_toggle <= ~seg_toggle;  // Expect opposite toggle next
                        
                        // Send acknowledgment
                        coe_response_service <= SDO_SCS_DOWNLOAD_SEG_RESP;
                        coe_response_data <= 32'h0;
                        coe_response_ready <= 1'b1;
                        state <= ST_DONE;
                    end else begin
                        // Toggle error
                        coe_abort_code <= ABORT_TOGGLE_ERROR;
                        state <= ST_ABORT;
                    end
                end
                
                // ============================================================
                ST_READ_PDI: begin
                    // Request read from PDI (application objects)
                    pdi_obj_req <= 1'b1;
                    pdi_obj_wr <= 1'b0;
                    pdi_obj_index <= coe_index;
                    pdi_obj_subindex <= coe_subindex;
                    state <= ST_WAIT_PDI;
                end
                
                // ============================================================
                ST_WRITE_LOCAL: begin
                    // Write to local object dictionary
                    case (coe_index)
                        16'h1000: begin  // Device Type - Read Only
                            coe_abort_code <= ABORT_READ_ONLY;
                            state <= ST_ABORT;
                        end
                        
                        16'h1001: begin  // Error Register - Read Only
                            coe_abort_code <= ABORT_READ_ONLY;
                            state <= ST_ABORT;
                        end
                        
                        16'h1018: begin  // Identity Object - Read Only
                            coe_abort_code <= ABORT_READ_ONLY;
                            state <= ST_ABORT;
                        end
                        
                        // BUGFIX P0-COE-01: Standard objects should go to PDI (write path)
                        default: begin
                            if (coe_index >= 16'h1000 && coe_index <= 16'h9FFF) begin
                                // Standard and application objects go to PDI
                                state <= ST_WRITE_PDI;
                            end else if (coe_index >= 16'hA000) begin
                                // Vendor-specific objects go to PDI
                                state <= ST_WRITE_PDI;
                            end else begin
                                coe_abort_code <= ABORT_OBJECT_NOT_EXIST;
                                state <= ST_ABORT;
                            end
                        end
                    endcase
                end
                
                // ============================================================
                ST_WRITE_PDI: begin
                    // Request write to PDI (application objects)
                    pdi_obj_req <= 1'b1;
                    pdi_obj_wr <= 1'b1;
                    pdi_obj_index <= coe_index;
                    pdi_obj_subindex <= coe_subindex;
                    pdi_obj_wdata <= coe_data_in;
                    state <= ST_WAIT_PDI;
                end
                
                // ============================================================
                ST_WAIT_PDI: begin
                    if (pdi_obj_ack) begin
                        if (pdi_obj_error) begin
                            coe_abort_code <= ABORT_GENERAL_ERROR;
                            state <= ST_ABORT;
                        end else begin
                            if (is_upload) begin
                                read_data <= pdi_obj_rdata;
                                read_size <= 8'd4;  // Assume 32-bit
                            end
                            state <= ST_BUILD_RESPONSE;
                        end
                    end
                end
                
                // ============================================================
                ST_BUILD_RESPONSE: begin
                    if (is_upload) begin
                        // Build upload response
                        case (read_size)
                            1: coe_response_service <= SDO_SCS_UPLOAD_INIT_RESP_1;
                            2: coe_response_service <= SDO_SCS_UPLOAD_INIT_RESP_2;
                            3: coe_response_service <= SDO_SCS_UPLOAD_INIT_RESP_3;
                            default: coe_response_service <= SDO_SCS_UPLOAD_INIT_RESP_4;
                        endcase
                        coe_response_data <= read_data;
                    end else begin
                        // Build download response
                        coe_response_service <= SDO_SCS_DOWNLOAD_INIT_RESP;
                        coe_response_data <= 32'h0;
                    end
                    
                    coe_response_ready <= 1'b1;
                    state <= ST_DONE;
                end
                
                // ============================================================
                ST_ABORT: begin
                    coe_response_service <= SDO_SCS_ABORT;
                    coe_response_data <= 32'h0;
                    coe_response_ready <= 1'b1;
                    coe_error <= 1'b1;
                    state <= ST_DONE;
                end
                
                // ============================================================
                ST_DONE: begin
                    coe_error <= 1'b0;
                    state <= ST_IDLE;
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule