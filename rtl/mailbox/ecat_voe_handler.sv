// ============================================================================
// EtherCAT VoE (Vendor Specific over EtherCAT) Handler
// Implements vendor-specific mailbox protocol per ETG.1000
// P1 Priority Function - Framework Stub
// ============================================================================

`include "ecat_pkg.vh"

module ecat_voe_handler #(
    parameter VENDOR_ID = 32'h00000000,   // Vendor ID for identification
    parameter VENDOR_TYPE = 16'h0000      // Vendor-specific type
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Mailbox interface (packed arrays for Yosys)
    input  wire                     voe_request,
    input  wire [31:0]              voe_vendor_id,      // Vendor ID in request
    input  wire [15:0]              voe_vendor_type,    // Vendor type in request  
    input  wire [1023:0]            voe_data,           // 128 bytes packed
    input  wire [7:0]               voe_data_len,
    
    output reg                      voe_response_ready,
    output reg  [31:0]              voe_response_vendor_id,
    output reg  [15:0]              voe_response_vendor_type,
    output reg  [1023:0]            voe_response_data,  // 128 bytes packed
    output reg  [7:0]               voe_response_len,
    output reg  [15:0]              voe_error_code,
    
    // Vendor-specific interface (directly exposed, packed)
    output reg                      vendor_req_valid,
    output reg  [1023:0]            vendor_req_data,    // 128 bytes packed
    output reg  [7:0]               vendor_req_len,
    input  wire                     vendor_rsp_valid,
    input  wire [1023:0]            vendor_rsp_data,    // 128 bytes packed
    input  wire [7:0]               vendor_rsp_len,
    
    // Status
    output reg                      voe_busy,
    output reg                      voe_supported
);

    // ========================================================================
    // VoE Error Codes
    // ========================================================================
    localparam VOE_ERR_VENDOR_MISMATCH = 16'h8001;
    localparam VOE_ERR_TYPE_MISMATCH   = 16'h8002;
    localparam VOE_ERR_NOT_SUPPORTED   = 16'h8003;
    localparam VOE_ERR_INVALID_DATA    = 16'h8004;

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_CHECK_VENDOR,
        ST_FORWARD_REQ,
        ST_WAIT_RSP,
        ST_BUILD_RSP,
        ST_SEND_ERROR,
        ST_DONE
    } voe_state_t;

    voe_state_t state;
    reg [15:0] timeout_counter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            voe_response_ready <= 1'b0;
            voe_response_vendor_id <= 32'h0;
            voe_response_vendor_type <= 16'h0;
            voe_response_data <= 1024'h0;
            voe_response_len <= 8'h0;
            voe_error_code <= 16'h0;
            voe_busy <= 1'b0;
            voe_supported <= 1'b1;  // VoE is always "supported" (framework)
            vendor_req_valid <= 1'b0;
            vendor_req_data <= 1024'h0;
            vendor_req_len <= 8'h0;
            timeout_counter <= 16'h0;
        end else begin
            // Defaults
            voe_response_ready <= 1'b0;
            vendor_req_valid <= 1'b0;
            
            case (state)
                ST_IDLE: begin
                    voe_busy <= 1'b0;
                    if (voe_request) begin
                        voe_busy <= 1'b1;
                        state <= ST_CHECK_VENDOR;
                    end
                end
                
                ST_CHECK_VENDOR: begin
                    // Check if this is our vendor ID
                    if (voe_vendor_id == VENDOR_ID || VENDOR_ID == 32'h0) begin
                        // Pass to vendor-specific handler
                        state <= ST_FORWARD_REQ;
                    end else begin
                        // Wrong vendor ID
                        voe_error_code <= VOE_ERR_VENDOR_MISMATCH;
                        state <= ST_SEND_ERROR;
                    end
                end
                
                ST_FORWARD_REQ: begin
                    // Forward request to vendor interface
                    vendor_req_valid <= 1'b1;
                    vendor_req_data <= voe_data;
                    vendor_req_len <= voe_data_len;
                    timeout_counter <= 16'hFFFF;
                    state <= ST_WAIT_RSP;
                end
                
                ST_WAIT_RSP: begin
                    if (vendor_rsp_valid) begin
                        // Copy response
                        voe_response_data <= vendor_rsp_data;
                        voe_response_len <= vendor_rsp_len;
                        state <= ST_BUILD_RSP;
                    end else if (timeout_counter == 0) begin
                        // Timeout - no vendor handler responded
                        voe_error_code <= VOE_ERR_NOT_SUPPORTED;
                        state <= ST_SEND_ERROR;
                    end else begin
                        timeout_counter <= timeout_counter - 1;
                    end
                end
                
                ST_BUILD_RSP: begin
                    voe_response_ready <= 1'b1;
                    voe_response_vendor_id <= VENDOR_ID;
                    voe_response_vendor_type <= voe_vendor_type;
                    state <= ST_DONE;
                end
                
                ST_SEND_ERROR: begin
                    // Build error response
                    voe_response_ready <= 1'b1;
                    voe_response_vendor_id <= VENDOR_ID;
                    voe_response_vendor_type <= 16'hFFFF;  // Error indicator
                    voe_response_data[7:0] <= voe_error_code[7:0];
                    voe_response_data[15:8] <= voe_error_code[15:8];
                    voe_response_len <= 8'd2;
                    state <= ST_DONE;
                end
                
                ST_DONE: begin
                    voe_busy <= 1'b0;
                    state <= ST_IDLE;
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
