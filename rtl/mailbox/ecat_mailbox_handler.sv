// ============================================================================
// EtherCAT Mailbox Protocol Handler
// Implements mailbox communication using SM0 (Master->Slave) and SM1 (Slave->Master)
// P1 High Priority Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_mailbox_handler #(
    parameter SM0_ADDR = 16'h1000,    // SM0 (Master->Slave) start address
    parameter SM0_SIZE = 128,         // SM0 buffer size
    parameter SM1_ADDR = 16'h1080,    // SM1 (Slave->Master) start address
    parameter SM1_SIZE = 128          // SM1 buffer size
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // SM0 Interface (Master->Slave mailbox)
    input  wire                     sm0_mailbox_full,   // Master has written data
    output reg                      sm0_mailbox_read,   // Slave has read data
    
    // SM1 Interface (Slave->Master mailbox)
    output reg                      sm1_mailbox_full,   // Slave has written response
    input  wire                     sm1_mailbox_read,   // Master has read response
    
    // Memory interface (to DPRAM via SM)
    output reg                      mem_req,
    output reg                      mem_wr,
    output reg  [15:0]              mem_addr,
    output reg  [7:0]               mem_wdata,
    input  wire [7:0]               mem_rdata,
    input  wire                     mem_ack,
    
    // Protocol interfaces - CoE
    output reg                      coe_request,
    output reg  [7:0]               coe_service,       // SDO command
    output reg  [15:0]              coe_index,         // Object index
    output reg  [7:0]               coe_subindex,      // Object subindex
    output reg  [31:0]              coe_data,          // Data for write
    input  wire                     coe_response_ready,
    input  wire [7:0]               coe_response_service,
    input  wire [31:0]              coe_response_data,
    input  wire [31:0]              coe_abort_code,
    
    // Status
    output reg                      mailbox_busy,
    output reg  [7:0]               mailbox_error,
    output reg                      mailbox_irq
);

    // ========================================================================
    // Mailbox Header Structure (ETG.1000)
    // ========================================================================
    // Byte 0-1: Length (data length after header)
    // Byte 2-3: Address (station address, usually 0)
    // Byte 4:   Channel (reserved) + Priority (bits 0-1)
    // Byte 5:   Type (protocol type)
    //           0x01 = ERR (Error)
    //           0x02 = AoE (ADS over EtherCAT)
    //           0x03 = EoE (Ethernet over EtherCAT)
    //           0x04 = CoE (CANopen over EtherCAT)
    //           0x05 = FoE (File over EtherCAT)
    //           0x06 = SoE (Servo over EtherCAT)
    //           0x0F = VoE (Vendor specific)
    
    localparam MBX_TYPE_ERR = 8'h01;
    localparam MBX_TYPE_AOE = 8'h02;
    localparam MBX_TYPE_EOE = 8'h03;
    localparam MBX_TYPE_COE = 8'h04;
    localparam MBX_TYPE_FOE = 8'h05;
    localparam MBX_TYPE_SOE = 8'h06;
    localparam MBX_TYPE_VOE = 8'h0F;
    
    // Mailbox error codes
    localparam MBX_ERR_SYNTAX          = 16'h0001;
    localparam MBX_ERR_UNSUPPORTED     = 16'h0002;
    localparam MBX_ERR_INVALID_HEADER  = 16'h0003;
    localparam MBX_ERR_SIZE_TOO_SHORT  = 16'h0004;
    localparam MBX_ERR_NO_MEMORY       = 16'h0005;
    localparam MBX_ERR_INVALID_SIZE    = 16'h0006;
    localparam MBX_ERR_SERVICE_NOT_SUP = 16'h0007;

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [4:0] {
        ST_IDLE,
        ST_READ_HEADER,
        ST_PARSE_HEADER,
        ST_READ_DATA,
        ST_DISPATCH,
        ST_PROCESS_COE,
        ST_PROCESS_FOE,
        ST_PROCESS_EOE,
        ST_WAIT_RESPONSE,
        ST_WRITE_HEADER,
        ST_WRITE_DATA,
        ST_SEND_ERROR,
        ST_NOTIFY_MASTER,
        ST_DONE,
        ST_ERROR
    } mbx_state_t;
    
    mbx_state_t state;

    // ========================================================================
    // Internal Registers
    // ========================================================================
    // Mailbox header
    reg [15:0]  mbx_length;
    reg [15:0]  mbx_address;
    reg [7:0]   mbx_channel;
    reg [7:0]   mbx_type;
    
    // Data buffer (max 128 bytes of payload)
    reg [7:0]   data_buffer [0:127];
    reg [7:0]   response_buffer [0:127];
    reg [7:0]   byte_cnt;
    reg [7:0]   data_len;
    
    // Response
    reg [15:0]  resp_length;
    reg [7:0]   resp_type;
    reg [15:0]  error_code;
    reg [15:0]  error_detail;

    // ========================================================================
    // Main State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            mem_req <= 1'b0;
            mem_wr <= 1'b0;
            mem_addr <= 16'h0;
            mem_wdata <= 8'h0;
            sm0_mailbox_read <= 1'b0;
            sm1_mailbox_full <= 1'b0;
            mailbox_busy <= 1'b0;
            mailbox_error <= 8'h0;
            mailbox_irq <= 1'b0;
            coe_request <= 1'b0;
            coe_service <= 8'h0;
            coe_index <= 16'h0;
            coe_subindex <= 8'h0;
            coe_data <= 32'h0;
            mbx_length <= 16'h0;
            mbx_address <= 16'h0;
            mbx_channel <= 8'h0;
            mbx_type <= 8'h0;
            byte_cnt <= 8'h0;
            data_len <= 8'h0;
            resp_length <= 16'h0;
            resp_type <= 8'h0;
            error_code <= 16'h0;
            error_detail <= 16'h0;
        end else begin
            // Default values
            mem_req <= 1'b0;
            coe_request <= 1'b0;
            mailbox_irq <= 1'b0;
            
            case (state)
                // ============================================================
                ST_IDLE: begin
                    mailbox_busy <= 1'b0;
                    sm0_mailbox_read <= 1'b0;
                    
                    // Check if master has sent a mailbox message
                    if (sm0_mailbox_full && !sm1_mailbox_full) begin
                        state <= ST_READ_HEADER;
                        byte_cnt <= 8'h0;
                        mailbox_busy <= 1'b1;
                    end
                end
                
                // ============================================================
                ST_READ_HEADER: begin
                    // Read 6-byte mailbox header from SM0
                    mem_req <= 1'b1;
                    mem_wr <= 1'b0;
                    mem_addr <= SM0_ADDR + {8'h0, byte_cnt};
                    
                    if (mem_ack) begin
                        case (byte_cnt)
                            0: mbx_length[7:0] <= mem_rdata;
                            1: mbx_length[15:8] <= mem_rdata;
                            2: mbx_address[7:0] <= mem_rdata;
                            3: mbx_address[15:8] <= mem_rdata;
                            4: mbx_channel <= mem_rdata;
                            5: begin
                                mbx_type <= mem_rdata;
                                state <= ST_PARSE_HEADER;
                            end
                        endcase
                        byte_cnt <= byte_cnt + 1;
                    end
                end
                
                // ============================================================
                ST_PARSE_HEADER: begin
                    // Validate header
                    if (mbx_length == 0 || mbx_length > (SM0_SIZE - 6)) begin
                        error_code <= MBX_ERR_INVALID_SIZE;
                        state <= ST_SEND_ERROR;
                    end else begin
                        data_len <= mbx_length[7:0];
                        byte_cnt <= 8'h0;
                        state <= ST_READ_DATA;
                    end
                end
                
                // ============================================================
                ST_READ_DATA: begin
                    // Read mailbox data
                    if (byte_cnt < data_len) begin
                        mem_req <= 1'b1;
                        mem_wr <= 1'b0;
                        mem_addr <= SM0_ADDR + 6 + {8'h0, byte_cnt};
                        
                        if (mem_ack) begin
                            data_buffer[byte_cnt] <= mem_rdata;
                            byte_cnt <= byte_cnt + 1;
                        end
                    end else begin
                        state <= ST_DISPATCH;
                        sm0_mailbox_read <= 1'b1;  // Signal that we've read the mailbox
                    end
                end
                
                // ============================================================
                ST_DISPATCH: begin
                    sm0_mailbox_read <= 1'b0;
                    
                    case (mbx_type)
                        MBX_TYPE_COE: state <= ST_PROCESS_COE;
                        MBX_TYPE_FOE: state <= ST_PROCESS_FOE;
                        MBX_TYPE_EOE: state <= ST_PROCESS_EOE;
                        default: begin
                            // Unsupported protocol
                            error_code <= MBX_ERR_UNSUPPORTED;
                            state <= ST_SEND_ERROR;
                        end
                    endcase
                end
                
                // ============================================================
                ST_PROCESS_COE: begin
                    // Parse CoE header and dispatch to CoE handler
                    // CoE Data: [0-1]=Number/Service, [2-3]=Index, [4]=Subindex, [5-8]=Data
                    coe_request <= 1'b1;
                    coe_service <= data_buffer[0];
                    coe_index <= {data_buffer[3], data_buffer[2]};
                    coe_subindex <= data_buffer[4];
                    coe_data <= {data_buffer[8], data_buffer[7], data_buffer[6], data_buffer[5]};
                    state <= ST_WAIT_RESPONSE;
                end
                
                // ============================================================
                ST_PROCESS_FOE: begin
                    // FoE not implemented - return error
                    error_code <= MBX_ERR_SERVICE_NOT_SUP;
                    state <= ST_SEND_ERROR;
                end
                
                // ============================================================
                ST_PROCESS_EOE: begin
                    // EoE not implemented - return error
                    error_code <= MBX_ERR_SERVICE_NOT_SUP;
                    state <= ST_SEND_ERROR;
                end
                
                // ============================================================
                ST_WAIT_RESPONSE: begin
                    // Wait for protocol handler to provide response
                    if (coe_response_ready) begin
                        // Build response
                        resp_type <= MBX_TYPE_COE;
                        
                        if (coe_abort_code != 32'h0) begin
                            // SDO Abort response
                            resp_length <= 16'h000A;  // 10 bytes
                            response_buffer[0] <= 8'h80;  // Abort transfer
                            response_buffer[1] <= 8'h00;
                            response_buffer[2] <= coe_index[7:0];
                            response_buffer[3] <= coe_index[15:8];
                            response_buffer[4] <= coe_subindex;
                            response_buffer[5] <= coe_abort_code[7:0];
                            response_buffer[6] <= coe_abort_code[15:8];
                            response_buffer[7] <= coe_abort_code[23:16];
                            response_buffer[8] <= coe_abort_code[31:24];
                        end else begin
                            // SDO Response
                            resp_length <= 16'h000A;  // 10 bytes
                            response_buffer[0] <= coe_response_service;
                            response_buffer[1] <= 8'h00;
                            response_buffer[2] <= coe_index[7:0];
                            response_buffer[3] <= coe_index[15:8];
                            response_buffer[4] <= coe_subindex;
                            response_buffer[5] <= coe_response_data[7:0];
                            response_buffer[6] <= coe_response_data[15:8];
                            response_buffer[7] <= coe_response_data[23:16];
                            response_buffer[8] <= coe_response_data[31:24];
                        end
                        
                        byte_cnt <= 8'h0;
                        state <= ST_WRITE_HEADER;
                    end
                end
                
                // ============================================================
                ST_SEND_ERROR: begin
                    // Build error response
                    resp_type <= MBX_TYPE_ERR;
                    resp_length <= 16'h0004;  // 4 bytes
                    response_buffer[0] <= error_code[7:0];
                    response_buffer[1] <= error_code[15:8];
                    response_buffer[2] <= error_detail[7:0];
                    response_buffer[3] <= error_detail[15:8];
                    
                    byte_cnt <= 8'h0;
                    state <= ST_WRITE_HEADER;
                end
                
                // ============================================================
                ST_WRITE_HEADER: begin
                    // Write 6-byte header to SM1
                    mem_req <= 1'b1;
                    mem_wr <= 1'b1;
                    mem_addr <= SM1_ADDR + {8'h0, byte_cnt};
                    
                    case (byte_cnt)
                        0: mem_wdata <= resp_length[7:0];
                        1: mem_wdata <= resp_length[15:8];
                        2: mem_wdata <= 8'h00;  // Address low
                        3: mem_wdata <= 8'h00;  // Address high
                        4: mem_wdata <= mbx_channel;  // Return same channel
                        5: mem_wdata <= resp_type;
                    endcase
                    
                    if (mem_ack) begin
                        if (byte_cnt == 5) begin
                            byte_cnt <= 8'h0;
                            data_len <= resp_length[7:0];
                            state <= ST_WRITE_DATA;
                        end else begin
                            byte_cnt <= byte_cnt + 1;
                        end
                    end
                end
                
                // ============================================================
                ST_WRITE_DATA: begin
                    // Write response data to SM1
                    if (byte_cnt < data_len) begin
                        mem_req <= 1'b1;
                        mem_wr <= 1'b1;
                        mem_addr <= SM1_ADDR + 6 + {8'h0, byte_cnt};
                        mem_wdata <= response_buffer[byte_cnt];
                        
                        if (mem_ack) begin
                            byte_cnt <= byte_cnt + 1;
                        end
                    end else begin
                        state <= ST_NOTIFY_MASTER;
                    end
                end
                
                // ============================================================
                ST_NOTIFY_MASTER: begin
                    // Signal master that response is ready
                    sm1_mailbox_full <= 1'b1;
                    mailbox_irq <= 1'b1;
                    state <= ST_DONE;
                end
                
                // ============================================================
                ST_DONE: begin
                    // Wait for master to read response
                    if (sm1_mailbox_read) begin
                        sm1_mailbox_full <= 1'b0;
                        state <= ST_IDLE;
                    end
                end
                
                // ============================================================
                ST_ERROR: begin
                    mailbox_error <= 8'hFF;
                    state <= ST_IDLE;
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
