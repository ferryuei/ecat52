// ============================================================================
// EtherCAT EoE (Ethernet over EtherCAT) Handler
// Implements standard Ethernet tunneling per ETG.1000 Section 5.7
// P1 Priority Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_eoe_handler #(
    parameter MTU_SIZE = 1500,            // Maximum Ethernet payload
    parameter TX_BUFFER_SIZE = 2048,      // TX buffer size
    parameter RX_BUFFER_SIZE = 2048,      // RX buffer size
    parameter TIMEOUT_CYCLES = 100000     // BUGFIX F1-GEN-01: Timeout = 1ms @ 100MHz
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Mailbox interface (packed arrays for Yosys)
    input  wire                     eoe_request,
    input  wire [3:0]               eoe_type,           // Frame type
    input  wire [3:0]               eoe_port,           // Port number
    input  wire                     eoe_last_fragment,  // Last fragment flag
    input  wire                     eoe_time_appended,  // Timestamp appended
    input  wire                     eoe_time_request,   // Time request
    input  wire [15:0]              eoe_fragment_no,    // Fragment number
    input  wire [15:0]              eoe_offset,         // Offset in 32-byte units
    input  wire [15:0]              eoe_frame_no,       // Frame number
    input  wire [1023:0]            eoe_data,           // 128 bytes packed
    input  wire [7:0]               eoe_data_len,       // Data length
    
    output reg                      eoe_response_ready,
    output reg  [3:0]               eoe_response_type,
    output reg  [15:0]              eoe_response_result,
    output reg  [1023:0]            eoe_response_data,  // 128 bytes packed
    output reg  [7:0]               eoe_response_len,
    
    // Virtual Ethernet interface (to local TCP/IP stack or external port)
    output reg                      eth_tx_valid,
    output reg  [7:0]               eth_tx_data,
    output reg                      eth_tx_last,
    input  wire                     eth_tx_ready,
    
    input  wire                     eth_rx_valid,
    input  wire [7:0]               eth_rx_data,
    input  wire                     eth_rx_last,
    output reg                      eth_rx_ready,
    
    // IP address configuration
    input  wire [31:0]              ip_address,
    input  wire [31:0]              subnet_mask,
    input  wire [31:0]              gateway,
    input  wire [47:0]              mac_address,
    
    // Status
    output reg                      eoe_busy,
    output reg                      eoe_active,
    output reg  [15:0]              frames_received,
    output reg  [15:0]              frames_sent,
    output reg  [15:0]              fragments_pending
);

    // ========================================================================
    // EoE Frame Types (ETG.1000)
    // ========================================================================
    localparam EOE_TYPE_FRAG_DATA     = 4'h0;   // Fragment Data
    localparam EOE_TYPE_INIT_REQ      = 4'h1;   // Init Request (deprecated)
    localparam EOE_TYPE_INIT_RSP      = 4'h2;   // Init Response
    localparam EOE_TYPE_SET_IP_REQ    = 4'h3;   // Set IP Parameter Request
    localparam EOE_TYPE_SET_IP_RSP    = 4'h4;   // Set IP Parameter Response
    localparam EOE_TYPE_SET_FILTER_REQ = 4'h5;  // Set Address Filter Request
    localparam EOE_TYPE_SET_FILTER_RSP = 4'h6;  // Set Address Filter Response
    localparam EOE_TYPE_GET_IP_REQ    = 4'h7;   // Get IP Parameter Request
    localparam EOE_TYPE_GET_IP_RSP    = 4'h8;   // Get IP Parameter Response
    localparam EOE_TYPE_GET_FILTER_REQ = 4'h9;  // Get Address Filter Request
    localparam EOE_TYPE_GET_FILTER_RSP = 4'hA;  // Get Address Filter Response

    // EoE Result Codes
    localparam EOE_RESULT_SUCCESS       = 16'h0000;
    localparam EOE_RESULT_UNSPECIFIED   = 16'h0001;
    localparam EOE_RESULT_UNSUPPORTED   = 16'h0002;
    localparam EOE_RESULT_NO_IP_SUPPORT = 16'h0003;
    localparam EOE_RESULT_NO_FILTER     = 16'h0004;

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_RECEIVE_FRAGMENT,
        ST_REASSEMBLE,
        ST_FORWARD_FRAME,
        ST_PROCESS_INIT,
        ST_PROCESS_SET_IP,
        ST_PROCESS_GET_IP,
        ST_PROCESS_SET_FILTER,
        ST_PROCESS_GET_FILTER,
        ST_SEND_RESPONSE,
        ST_FRAGMENT_TX,
        ST_DONE
    } eoe_state_t;

    eoe_state_t state;

    // ========================================================================
    // Frame Reassembly Buffer
    // ========================================================================
    reg [7:0]   rx_frame_buffer [0:MTU_SIZE+14-1];  // Full Ethernet frame
    reg [15:0]  rx_frame_len;
    reg [15:0]  rx_frame_no;
    reg [15:0]  rx_expected_fragment;
    reg         rx_frame_complete;

    // TX Fragmentation Buffer
    reg [7:0]   tx_frame_buffer [0:MTU_SIZE+14-1];
    reg [15:0]  tx_frame_len;
    reg [15:0]  tx_frame_no;
    reg [15:0]  tx_fragment_offset;
    reg [15:0]  tx_fragment_no;
    
    // IP Configuration (writable)
    reg [31:0]  cfg_ip_address;
    reg [31:0]  cfg_subnet_mask;
    reg [31:0]  cfg_gateway;
    reg [47:0]  cfg_mac_address;
    reg         cfg_dhcp_enable;
    reg         cfg_dns_enable;
    reg [31:0]  cfg_dns_server;

    // Address filter (packed)
    reg [191:0] filter_mac;  // 4 x 48-bit MACs packed
    reg [3:0]   filter_enable;
    reg         filter_broadcast;
    reg         filter_multicast;

    // ========================================================================
    // Internal Counters
    // ========================================================================
    reg [10:0]  byte_index;
    reg [15:0]  timeout_counter;  // Existing counter, repurpose for fragment timeout
    
    // BUGFIX F1-GEN-01: Watchdog timer for timeout protection
    reg [19:0]  watchdog_counter;

    // Helper: Extract byte from packed input
    function [7:0] get_data_byte;
        input [1023:0] data;
        input [6:0] idx;
        begin
            get_data_byte = data[idx*8 +: 8];
        end
    endfunction

    // Helper wires for byte access (Yosys compatibility)
    wire [7:0] eoe_byte0 = eoe_data[7:0];
    wire [7:0] eoe_byte1 = eoe_data[15:8];

    // ========================================================================
    // Main State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            eoe_response_ready <= 1'b0;
            eoe_response_type <= 4'h0;
            eoe_response_result <= 16'h0;
            eoe_response_data <= 1024'h0;
            eoe_response_len <= 8'h0;
            eth_tx_valid <= 1'b0;
            eth_tx_data <= 8'h0;
            eth_tx_last <= 1'b0;
            eth_rx_ready <= 1'b0;
            eoe_busy <= 1'b0;
            eoe_active <= 1'b0;
            frames_received <= 16'h0;
            frames_sent <= 16'h0;
            fragments_pending <= 16'h0;
            rx_frame_len <= 16'h0;
            rx_frame_no <= 16'h0;
            rx_expected_fragment <= 16'h0;
            rx_frame_complete <= 1'b0;
            tx_frame_len <= 16'h0;
            tx_frame_no <= 16'h0;
            tx_fragment_offset <= 16'h0;
            tx_fragment_no <= 16'h0;
            cfg_ip_address <= 32'h0;
            cfg_subnet_mask <= 32'hFFFFFF00;
            cfg_gateway <= 32'h0;
            cfg_mac_address <= 48'h0;
            cfg_dhcp_enable <= 1'b0;
            cfg_dns_enable <= 1'b0;
            cfg_dns_server <= 32'h0;
            filter_mac <= 192'h0;
            filter_enable <= 4'h0;
            filter_broadcast <= 1'b1;
            filter_multicast <= 1'b0;
            byte_index <= 11'h0;
            timeout_counter <= 16'h0;
            watchdog_counter <= 20'h0;  // BUGFIX F1-GEN-01: Initialize watchdog
        end else begin
            // Defaults
            eoe_response_ready <= 1'b0;
            eth_tx_valid <= 1'b0;
            eth_tx_last <= 1'b0;
            
            // BUGFIX F1-GEN-01: Watchdog timer management
            if (state != ST_IDLE && state != ST_DONE) begin
                watchdog_counter <= watchdog_counter + 1;
                
                // Check for timeout
                if (watchdog_counter >= TIMEOUT_CYCLES[19:0]) begin
                    eoe_response_result <= EOE_RESULT_UNSPECIFIED;
                    eoe_response_type <= eoe_type | 4'h1;  // Response type = Request type + 1
                    state <= ST_SEND_RESPONSE;
                    watchdog_counter <= 20'h0;
                end
            end else begin
                watchdog_counter <= 20'h0;
            end

            case (state)
                // ============================================================
                ST_IDLE: begin
                    eoe_busy <= 1'b0;
                    
                    if (eoe_request) begin
                        eoe_busy <= 1'b1;
                        eoe_active <= 1'b1;
                        
                        case (eoe_type)
                            EOE_TYPE_FRAG_DATA: state <= ST_RECEIVE_FRAGMENT;
                            EOE_TYPE_INIT_REQ:  state <= ST_PROCESS_INIT;
                            EOE_TYPE_SET_IP_REQ: state <= ST_PROCESS_SET_IP;
                            EOE_TYPE_GET_IP_REQ: state <= ST_PROCESS_GET_IP;
                            EOE_TYPE_SET_FILTER_REQ: state <= ST_PROCESS_SET_FILTER;
                            EOE_TYPE_GET_FILTER_REQ: state <= ST_PROCESS_GET_FILTER;
                            default: begin
                                eoe_response_result <= EOE_RESULT_UNSUPPORTED;
                                state <= ST_SEND_RESPONSE;
                            end
                        endcase
                    end
                    
                    // Check for frames to send from virtual Ethernet
                    if (eth_rx_valid && !eoe_busy) begin
                        eth_rx_ready <= 1'b1;
                        byte_index <= 11'h0;
                        tx_frame_len <= 16'h0;
                        state <= ST_FRAGMENT_TX;
                    end
                end

                // ============================================================
                ST_RECEIVE_FRAGMENT: begin
                    // Receive fragment data into reassembly buffer
                    if (eoe_frame_no != rx_frame_no) begin
                        // New frame, reset reassembly
                        rx_frame_no <= eoe_frame_no;
                        rx_expected_fragment <= 16'h0;
                        rx_frame_len <= 16'h0;
                        rx_frame_complete <= 1'b0;
                    end
                    
                    if (eoe_fragment_no == rx_expected_fragment) begin
                        // Copy fragment data to buffer (unrolled for synthesis)
                        for (int i = 0; i < 128; i++) begin
                            if (i < eoe_data_len && (eoe_offset * 32 + i) < MTU_SIZE + 14) begin
                                rx_frame_buffer[eoe_offset * 32 + i] <= get_data_byte(eoe_data, i[6:0]);
                            end
                        end
                        
                        rx_frame_len <= eoe_offset * 32 + {8'h0, eoe_data_len};
                        rx_expected_fragment <= rx_expected_fragment + 1;
                        fragments_pending <= fragments_pending + 1;
                        
                        if (eoe_last_fragment) begin
                            rx_frame_complete <= 1'b1;
                            state <= ST_REASSEMBLE;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                // ============================================================
                ST_REASSEMBLE: begin
                    frames_received <= frames_received + 1;
                    fragments_pending <= 16'h0;
                    byte_index <= 11'h0;
                    state <= ST_FORWARD_FRAME;
                end

                // ============================================================
                ST_FORWARD_FRAME: begin
                    if (byte_index < rx_frame_len) begin
                        eth_tx_valid <= 1'b1;
                        eth_tx_data <= rx_frame_buffer[byte_index];
                        eth_tx_last <= (byte_index == rx_frame_len - 1);
                        
                        if (eth_tx_ready) begin
                            byte_index <= byte_index + 1;
                        end
                    end else begin
                        rx_frame_complete <= 1'b0;
                        state <= ST_DONE;
                    end
                end

                // ============================================================
                ST_PROCESS_INIT: begin
                    eoe_response_type <= EOE_TYPE_INIT_RSP;
                    eoe_response_result <= EOE_RESULT_SUCCESS;
                    eoe_response_len <= 8'h0;
                    state <= ST_SEND_RESPONSE;
                end

                // ============================================================
                ST_PROCESS_SET_IP: begin
                    if (eoe_data_len >= 22) begin
                        cfg_mac_address <= {get_data_byte(eoe_data, 4), get_data_byte(eoe_data, 5),
                                           get_data_byte(eoe_data, 6), get_data_byte(eoe_data, 7),
                                           get_data_byte(eoe_data, 8), get_data_byte(eoe_data, 9)};
                        cfg_ip_address <= {get_data_byte(eoe_data, 10), get_data_byte(eoe_data, 11),
                                          get_data_byte(eoe_data, 12), get_data_byte(eoe_data, 13)};
                        cfg_subnet_mask <= {get_data_byte(eoe_data, 14), get_data_byte(eoe_data, 15),
                                           get_data_byte(eoe_data, 16), get_data_byte(eoe_data, 17)};
                        cfg_gateway <= {get_data_byte(eoe_data, 18), get_data_byte(eoe_data, 19),
                                       get_data_byte(eoe_data, 20), get_data_byte(eoe_data, 21)};
                        cfg_dhcp_enable <= eoe_byte0[0];
                        cfg_dns_enable <= eoe_byte0[1];
                        eoe_response_result <= EOE_RESULT_SUCCESS;
                    end else begin
                        eoe_response_result <= EOE_RESULT_UNSPECIFIED;
                    end
                    
                    eoe_response_type <= EOE_TYPE_SET_IP_RSP;
                    eoe_response_len <= 8'h0;
                    state <= ST_SEND_RESPONSE;
                end

                // ============================================================
                ST_PROCESS_GET_IP: begin
                    eoe_response_type <= EOE_TYPE_GET_IP_RSP;
                    eoe_response_result <= EOE_RESULT_SUCCESS;
                    
                    // Build response in packed format
                    eoe_response_data[7:0] <= {6'h0, cfg_dns_enable, cfg_dhcp_enable};
                    eoe_response_data[15:8] <= 8'h0;
                    eoe_response_data[23:16] <= 8'h0;
                    eoe_response_data[31:24] <= 8'h0;
                    eoe_response_data[39:32] <= cfg_mac_address[47:40];
                    eoe_response_data[47:40] <= cfg_mac_address[39:32];
                    eoe_response_data[55:48] <= cfg_mac_address[31:24];
                    eoe_response_data[63:56] <= cfg_mac_address[23:16];
                    eoe_response_data[71:64] <= cfg_mac_address[15:8];
                    eoe_response_data[79:72] <= cfg_mac_address[7:0];
                    eoe_response_data[87:80] <= cfg_ip_address[31:24];
                    eoe_response_data[95:88] <= cfg_ip_address[23:16];
                    eoe_response_data[103:96] <= cfg_ip_address[15:8];
                    eoe_response_data[111:104] <= cfg_ip_address[7:0];
                    eoe_response_data[119:112] <= cfg_subnet_mask[31:24];
                    eoe_response_data[127:120] <= cfg_subnet_mask[23:16];
                    eoe_response_data[135:128] <= cfg_subnet_mask[15:8];
                    eoe_response_data[143:136] <= cfg_subnet_mask[7:0];
                    eoe_response_data[151:144] <= cfg_gateway[31:24];
                    eoe_response_data[159:152] <= cfg_gateway[23:16];
                    eoe_response_data[167:160] <= cfg_gateway[15:8];
                    eoe_response_data[175:168] <= cfg_gateway[7:0];
                    eoe_response_data[183:176] <= cfg_dns_server[31:24];
                    eoe_response_data[191:184] <= cfg_dns_server[23:16];
                    eoe_response_data[199:192] <= cfg_dns_server[15:8];
                    eoe_response_data[207:200] <= cfg_dns_server[7:0];
                    
                    eoe_response_len <= 8'd26;
                    state <= ST_SEND_RESPONSE;
                end

                // ============================================================
                ST_PROCESS_SET_FILTER: begin
                    if (eoe_data_len >= 2) begin
                        filter_enable <= eoe_byte0[3:0];
                        filter_broadcast <= eoe_byte1[0];
                        filter_multicast <= eoe_byte1[1];
                        
                        if (eoe_data_len >= 8) begin
                            filter_mac[47:0] <= {get_data_byte(eoe_data, 2), get_data_byte(eoe_data, 3),
                                                get_data_byte(eoe_data, 4), get_data_byte(eoe_data, 5),
                                                get_data_byte(eoe_data, 6), get_data_byte(eoe_data, 7)};
                        end
                        if (eoe_data_len >= 14) begin
                            filter_mac[95:48] <= {get_data_byte(eoe_data, 8), get_data_byte(eoe_data, 9),
                                                 get_data_byte(eoe_data, 10), get_data_byte(eoe_data, 11),
                                                 get_data_byte(eoe_data, 12), get_data_byte(eoe_data, 13)};
                        end
                        
                        eoe_response_result <= EOE_RESULT_SUCCESS;
                    end else begin
                        eoe_response_result <= EOE_RESULT_UNSPECIFIED;
                    end
                    
                    eoe_response_type <= EOE_TYPE_SET_FILTER_RSP;
                    eoe_response_len <= 8'h0;
                    state <= ST_SEND_RESPONSE;
                end

                // ============================================================
                ST_PROCESS_GET_FILTER: begin
                    eoe_response_type <= EOE_TYPE_GET_FILTER_RSP;
                    eoe_response_result <= EOE_RESULT_SUCCESS;
                    
                    eoe_response_data[7:0] <= {4'h0, filter_enable};
                    eoe_response_data[15:8] <= {6'h0, filter_multicast, filter_broadcast};
                    eoe_response_data[23:16] <= filter_mac[47:40];
                    eoe_response_data[31:24] <= filter_mac[39:32];
                    eoe_response_data[39:32] <= filter_mac[31:24];
                    eoe_response_data[47:40] <= filter_mac[23:16];
                    eoe_response_data[55:48] <= filter_mac[15:8];
                    eoe_response_data[63:56] <= filter_mac[7:0];
                    
                    eoe_response_len <= 8'd8;
                    state <= ST_SEND_RESPONSE;
                end

                // ============================================================
                ST_SEND_RESPONSE: begin
                    eoe_response_ready <= 1'b1;
                    // BUGFIX P1-EOE-01: Keep response signal high until request cleared
                    // Previous bug: response_ready only lasted 1 clock cycle, 
                    // causing testbench to miss the response
                    if (!eoe_request) begin
                        state <= ST_DONE;
                    end
                end

                // ============================================================
                ST_FRAGMENT_TX: begin
                    eth_rx_ready <= 1'b1;
                    
                    if (eth_rx_valid) begin
                        if (byte_index < MTU_SIZE + 14) begin
                            tx_frame_buffer[byte_index] <= eth_rx_data;
                            byte_index <= byte_index + 1;
                            tx_frame_len <= {5'h0, byte_index} + 1;
                        end
                        
                        if (eth_rx_last) begin
                            eth_rx_ready <= 1'b0;
                            frames_sent <= frames_sent + 1;
                            tx_frame_no <= tx_frame_no + 1;
                            state <= ST_DONE;
                        end
                    end
                end

                // ============================================================
                ST_DONE: begin
                    eoe_busy <= 1'b0;
                    eoe_response_ready <= 1'b0;  // Clear response signal
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
