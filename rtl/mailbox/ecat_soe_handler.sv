// ============================================================================
// EtherCAT SoE (Servo over EtherCAT) Handler
// Implements SERCOS profile per ETG.1000 Section 5.8
// P1 Priority Function - Framework Stub
// ============================================================================

`include "ecat_pkg.vh"

module ecat_soe_handler (
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Mailbox interface (packed arrays for Yosys)
    input  wire                     soe_request,
    input  wire [7:0]               soe_opcode,
    input  wire [15:0]              soe_idn,            // IDN (Identification Number)
    input  wire [7:0]               soe_elements,       // Element flags
    input  wire [1023:0]            soe_data,           // 128 bytes packed
    input  wire [7:0]               soe_data_len,
    
    output reg                      soe_response_ready,
    output reg  [7:0]               soe_response_opcode,
    output reg  [15:0]              soe_response_idn,
    output reg  [1023:0]            soe_response_data,  // 128 bytes packed
    output reg  [7:0]               soe_response_len,
    output reg  [15:0]              soe_error_code,
    
    // Status
    output reg                      soe_busy,
    output reg                      soe_supported
);

    // ========================================================================
    // SoE OpCodes (ETG.1000)
    // ========================================================================
    localparam SOE_OP_READ_REQ      = 8'h01;  // Read IDN Request
    localparam SOE_OP_READ_RSP      = 8'h02;  // Read IDN Response
    localparam SOE_OP_WRITE_REQ     = 8'h03;  // Write IDN Request
    localparam SOE_OP_WRITE_RSP     = 8'h04;  // Write IDN Response
    localparam SOE_OP_NOTIFY        = 8'h05;  // Notification
    localparam SOE_OP_EMERGENCY     = 8'h06;  // Emergency

    // SoE Error Codes
    localparam SOE_ERR_NO_IDN       = 16'h1001;
    localparam SOE_ERR_NO_NAME      = 16'h1002;
    localparam SOE_ERR_NO_ATTR      = 16'h1003;
    localparam SOE_ERR_NO_UNIT      = 16'h1004;
    localparam SOE_ERR_NO_MIN       = 16'h1005;
    localparam SOE_ERR_NO_MAX       = 16'h1006;
    localparam SOE_ERR_NO_DATA      = 16'h1007;
    localparam SOE_ERR_NO_ELEMENT   = 16'h1008;
    localparam SOE_ERR_WRITE_PROT   = 16'h1009;
    localparam SOE_ERR_NOT_SUP      = 16'h100A;

    // ========================================================================
    // State Machine - Framework only (returns not supported)
    // ========================================================================
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_PROCESS,
        ST_RESPOND,
        ST_DONE
    } soe_state_t;

    soe_state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            soe_response_ready <= 1'b0;
            soe_response_opcode <= 8'h0;
            soe_response_idn <= 16'h0;
            soe_response_data <= 1024'h0;
            soe_response_len <= 8'h0;
            soe_error_code <= 16'h0;
            soe_busy <= 1'b0;
            soe_supported <= 1'b0;  // Not implemented
        end else begin
            soe_response_ready <= 1'b0;
            
            case (state)
                ST_IDLE: begin
                    soe_busy <= 1'b0;
                    if (soe_request) begin
                        soe_busy <= 1'b1;
                        state <= ST_PROCESS;
                    end
                end
                
                ST_PROCESS: begin
                    // Framework: All operations return "not supported"
                    soe_error_code <= SOE_ERR_NOT_SUP;
                    soe_response_idn <= soe_idn;
                    
                    case (soe_opcode)
                        SOE_OP_READ_REQ: soe_response_opcode <= SOE_OP_READ_RSP;
                        SOE_OP_WRITE_REQ: soe_response_opcode <= SOE_OP_WRITE_RSP;
                        default: soe_response_opcode <= 8'h00;
                    endcase
                    
                    // Build error response (bytes 0-1 = error code)
                    soe_response_data[7:0] <= soe_error_code[7:0];
                    soe_response_data[15:8] <= soe_error_code[15:8];
                    soe_response_len <= 8'd2;
                    
                    state <= ST_RESPOND;
                end
                
                ST_RESPOND: begin
                    soe_response_ready <= 1'b1;
                    state <= ST_DONE;
                end
                
                ST_DONE: begin
                    soe_busy <= 1'b0;
                    state <= ST_IDLE;
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
