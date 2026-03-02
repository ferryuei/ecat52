// ============================================================================
// EtherCAT Frame Transmitter
// Handles outgoing EtherCAT frames, working counter update, and FCS
// P0 Critical Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_frame_transmitter #(
    parameter DATA_WIDTH = 16
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Port interface (to PHY)
    output reg  [3:0]               port_id,           // Which port (0-3)
    output reg                      tx_valid,
    output reg  [7:0]               tx_data,
    output reg                      tx_sof,            // Start of frame
    output reg                      tx_eof,            // End of frame
    input  wire                     tx_ready,
    
    // Frame input (from receiver/forwarder)
    input  wire                     fwd_valid,
    input  wire [7:0]               fwd_data,
    input  wire                     fwd_sof,
    input  wire                     fwd_eof,
    input  wire                     fwd_modified,      // Frame was modified
    input  wire [3:0]               fwd_from_port,     // Source port
    
    // Modified data injection (from receiver)
    input  wire                     inject_enable,
    input  wire [10:0]              inject_offset,     // Byte offset in frame
    input  wire [7:0]               inject_data,
    
    // Port control
    input  wire [3:0]               port_enable,       // Which ports are enabled
    input  wire [3:0]               port_link_status,  // Link status per port
    
    // Statistics
    output reg  [15:0]              tx_frame_count,
    output reg  [15:0]              tx_error_count
);

    // ========================================================================
    // Frame Transmitter State Machine
    // ========================================================================
    typedef enum logic [2:0] {
        IDLE,
        WAIT_READY,
        TRANSMIT,
        FCS,
        DONE,
        ERROR
    } tx_state_t;
    
    tx_state_t state, next_state;
    
    // ========================================================================
    // Frame Buffer and Control
    // ========================================================================
    reg [7:0]   frame_buffer [0:1535];  // Max frame size
    reg [10:0]  frame_length;
    reg [10:0]  tx_count;
    reg [10:0]  buffer_write_ptr;
    
    // FCS (Frame Check Sequence) - CRC32
    reg [31:0]  fcs;
    reg [31:0]  fcs_calc;
    
    // Port forwarding logic
    reg [3:0]   target_ports;          // Bitmap of ports to transmit to
    reg [2:0]   current_port_idx;
    
    // ========================================================================
    // State Machine
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end
    
    always_comb begin
        next_state = state;
        
        case (state)
            IDLE: begin
                if (fwd_valid && fwd_sof)
                    next_state = WAIT_READY;
            end
            
            WAIT_READY: begin
                if (tx_ready && |target_ports)
                    next_state = TRANSMIT;
                else if (target_ports == 4'b0000)
                    next_state = IDLE;  // No valid ports
            end
            
            TRANSMIT: begin
                if (tx_count >= frame_length)
                    next_state = FCS;
            end
            
            FCS: begin
                if (tx_count >= 4)  // 4 bytes of FCS
                    next_state = DONE;
            end
            
            DONE: begin
                // Check if we need to transmit to more ports
                if (|target_ports)
                    next_state = WAIT_READY;
                else
                    next_state = IDLE;
            end
            
            ERROR: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // ========================================================================
    // Frame Buffering Logic
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_write_ptr <= '0;
            frame_length <= '0;
        end else begin
            if (state == IDLE && fwd_valid && fwd_sof) begin
                buffer_write_ptr <= 0;
                frame_length <= 0;
            end else if (fwd_valid && state == IDLE) begin
                // Buffer incoming frame
                frame_buffer[buffer_write_ptr] <= fwd_data;
                
                // Check if we need to inject modified data
                if (inject_enable && buffer_write_ptr == inject_offset) begin
                    frame_buffer[buffer_write_ptr] <= inject_data;
                end
                
                buffer_write_ptr <= buffer_write_ptr + 1;
                
                if (fwd_eof) begin
                    frame_length <= buffer_write_ptr + 1;
                end
            end
        end
    end
    
    // ========================================================================
    // Port Selection Logic
    // ========================================================================
    
    // Next port finder - combinational priority encoder
    reg [2:0] next_port;
    reg next_port_valid;
    always @* begin
        next_port = 3'd0;
        next_port_valid = 1'b0;
        // Check ports after current_port_idx
        if (current_port_idx < 3 && target_ports[current_port_idx + 1]) begin
            next_port = current_port_idx + 1;
            next_port_valid = 1'b1;
        end else if (current_port_idx < 2 && target_ports[current_port_idx + 2]) begin
            next_port = current_port_idx + 2;
            next_port_valid = 1'b1;
        end else if (current_port_idx < 1 && target_ports[3]) begin
            next_port = 3'd3;
            next_port_valid = 1'b1;
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            target_ports <= '0;
            current_port_idx <= '0;
        end else begin
            if (state == IDLE && fwd_valid && fwd_sof) begin
                // Determine which ports to forward to
                // Forward to all ports except source port
                target_ports <= port_enable & port_link_status & ~(4'b0001 << fwd_from_port);
                current_port_idx <= 0;
            end else if (state == DONE) begin
                // Clear current port and move to next
                target_ports[current_port_idx] <= 1'b0;
                
                // Move to next active port
                if (next_port_valid) begin
                    current_port_idx <= next_port;
                end
            end
        end
    end
    
    // ========================================================================
    // Transmission Logic
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_valid <= 1'b0;
            tx_data <= '0;
            tx_sof <= 1'b0;
            tx_eof <= 1'b0;
            tx_count <= '0;
            port_id <= '0;
            fcs <= 32'hFFFFFFFF;
            tx_frame_count <= '0;
            tx_error_count <= '0;
        end else begin
            // Default values
            tx_valid <= 1'b0;
            tx_sof <= 1'b0;
            tx_eof <= 1'b0;
            
            case (state)
                IDLE: begin
                    tx_count <= 0;
                    fcs <= 32'hFFFFFFFF;  // CRC initial value
                end
                
                WAIT_READY: begin
                    port_id <= current_port_idx[3:0];
                end
                
                TRANSMIT: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b1;
                        tx_data <= frame_buffer[tx_count];
                        
                        if (tx_count == 0)
                            tx_sof <= 1'b1;
                        
                        // Calculate CRC incrementally
                        fcs <= crc32_byte(fcs, frame_buffer[tx_count]);
                        
                        tx_count <= tx_count + 1;
                    end
                end
                
                FCS: begin
                    if (tx_ready) begin
                        tx_valid <= 1'b1;
                        
                        // Transmit FCS in little-endian order
                        case (tx_count)
                            0: tx_data <= ~fcs[7:0];
                            1: tx_data <= ~fcs[15:8];
                            2: tx_data <= ~fcs[23:16];
                            3: begin
                                tx_data <= ~fcs[31:24];
                                tx_eof <= 1'b1;
                            end
                        endcase
                        
                        tx_count <= tx_count + 1;
                    end
                end
                
                DONE: begin
                    tx_count <= 0;
                    fcs <= 32'hFFFFFFFF;
                    tx_frame_count <= tx_frame_count + 1;
                end
                
                ERROR: begin
                    tx_error_count <= tx_error_count + 1;
                end
            endcase
        end
    end
    
    // ========================================================================
    // CRC32 Calculation (Ethernet polynomial)
    // ========================================================================
    
    function [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0] data;
        reg [31:0] temp;
        reg [7:0] xor_val;
        begin
            temp = crc;
            xor_val = data ^ crc[7:0];
            
            temp = {8'h00, temp[31:8]};
            
            // Apply CRC32 polynomial: 0x04C11DB7
            if (xor_val[0]) temp = temp ^ 32'h77073096;
            if (xor_val[1]) temp = temp ^ 32'hEE0E612C;
            if (xor_val[2]) temp = temp ^ 32'h076DC419;
            if (xor_val[3]) temp = temp ^ 32'h0EDB8832;
            if (xor_val[4]) temp = temp ^ 32'h1DB71064;
            if (xor_val[5]) temp = temp ^ 32'h3B6E20C8;
            if (xor_val[6]) temp = temp ^ 32'h76DC4190;
            if (xor_val[7]) temp = temp ^ 32'hEDB88320;
            
            crc32_byte = temp;
        end
    endfunction

endmodule
