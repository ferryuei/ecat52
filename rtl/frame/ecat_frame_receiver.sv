// ============================================================================
// EtherCAT Frame Receiver
// Handles incoming EtherCAT frames, command decoding, and address matching
// Implements EPU-01 to EPU-12 test requirements
// ============================================================================

`include "ecat_pkg.vh"
`include "ecat_core_defines.vh"

module ecat_frame_receiver #(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 16,
    parameter STATION_ADDR = 16'h0000
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Port interface (from PHY)
    input  wire [3:0]               port_id,
    input  wire                     rx_valid,
    input  wire [7:0]               rx_data,
    input  wire                     rx_sof,
    input  wire                     rx_eof,
    input  wire                     rx_error,
    
    // Register interface
    input  wire [15:0]              station_address,
    input  wire [31:0]              station_alias,
    
    // Memory interface
    output reg  [15:0]              mem_addr,
    output reg  [15:0]              mem_wdata,
    output reg  [1:0]               mem_be,
    output reg                      mem_wr_en,
    output reg                      mem_rd_en,
    input  wire [15:0]              mem_rdata,
    input  wire                     mem_ready,

    // Logical access interface (FMMU translated)
    output reg                      log_req,
    output reg                      log_wr,
    output reg  [31:0]              log_addr,
    output reg  [7:0]               log_wdata,
    input  wire                     log_ack,
    input  wire [7:0]               log_rdata,
    input  wire                     log_err,
    
    // Frame forwarding
    output reg                      fwd_valid,
    output reg  [7:0]               fwd_data,
    output reg                      fwd_sof,
    output reg                      fwd_eof,
    output reg                      fwd_modified,

    // Frame metadata for port controller
    output reg                      frame_rx_valid,
    output reg  [47:0]              frame_src_mac,
    output reg  [47:0]              frame_dst_mac,
    output reg                      frame_is_ecat,
    output reg                      frame_crc_error,
    
    // Statistics
    output reg  [15:0]              rx_frame_count,
    output reg  [15:0]              rx_error_count,
    output reg  [15:0]              rx_crc_error_count, // CRC validation errors
    output reg  [15:0]              wkc_increment_count // WKC increments performed
);

    // ========================================================================
    // Constants
    // ========================================================================
    localparam CMD_NOP   = 8'h00;
    localparam CMD_APRD  = 8'h01;
    localparam CMD_APWR  = 8'h02;
    localparam CMD_APRW  = 8'h03;
    localparam CMD_FPRD  = 8'h04;
    localparam CMD_FPWR  = 8'h05;
    localparam CMD_FPRW  = 8'h06;
    localparam CMD_BRD   = 8'h07;
    localparam CMD_BWR   = 8'h08;
    localparam CMD_BRW   = 8'h09;
    localparam CMD_LRD   = 8'h0A;
    localparam CMD_LWR   = 8'h0B;
    localparam CMD_LRW   = 8'h0C;
    localparam CMD_ARMW  = 8'h0D;
    localparam CMD_FRMW  = 8'h0E;
    
    localparam [15:0] ETHERTYPE_ECAT = 16'h88A4;

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_ETH_HDR,
        S_ECAT_HDR,
        S_DG_HDR,
        S_DG_DATA,
        S_DG_WKC,
        S_FORWARD,
        S_TRANSPARENT,
        S_COMMIT_WR,
        S_ERROR
    } state_t;
    
    state_t state;
    
    // ========================================================================
    // Registers
    // ========================================================================
    reg [10:0]  byte_cnt;
    reg [10:0]  dg_byte_cnt;
    reg [15:0]  ethertype;
    
    // Datagram fields
    reg [7:0]   dg_cmd;
    reg [15:0]  dg_adp;
    reg [15:0]  dg_ado;
    reg [10:0]  dg_len;
    reg         dg_more;
    reg [15:0]  dg_wkc;
    
    // Processing flags
    reg         addr_matched;
    reg         is_read_cmd;
    reg         is_write_cmd;
    reg         is_rw_cmd;
    reg         crc_err;
    wire        is_log_cmd = (dg_cmd == CMD_LRD || dg_cmd == CMD_LWR || dg_cmd == CMD_LRW);
    
    // CRC32 validation
    reg [31:0]  crc_accumulator;
    reg [7:0]   fcs_buffer [0:3];  // Buffer to capture received FCS
    reg [2:0]   fcs_idx;
    reg [10:0]  total_byte_cnt;    // Total bytes received in frame
    
    // WKC handling
    reg [15:0]  wkc_add;
    reg         wkc_modified;
    
    // Data handling
    reg [10:0]  data_idx;
    
    // Write buffer - simple fixed-size buffer
    reg [31:0]  wr_addr [0:31];
    reg [7:0]   wr_data [0:31];
    reg         wr_is_logical [0:31];
    reg [5:0]   wr_cnt;
    reg [5:0]   wr_idx;

    // ========================================================================
    // Command Classification Functions
    // ========================================================================
    function cmd_is_write;
        input [7:0] c;
        begin
            case (c)
                CMD_APWR, CMD_FPWR, CMD_BWR, CMD_LWR: cmd_is_write = 1'b1;
                default: cmd_is_write = 1'b0;
            endcase
        end
    endfunction
    
    function cmd_is_rw;
        input [7:0] c;
        begin
            case (c)
                CMD_APRW, CMD_FPRW, CMD_BRW, CMD_LRW: cmd_is_rw = 1'b1;
                default: cmd_is_rw = 1'b0;
            endcase
        end
    endfunction
    
    function cmd_is_auto_inc;
        input [7:0] c;
        begin
            case (c)
                CMD_APRD, CMD_APWR, CMD_APRW, CMD_ARMW: cmd_is_auto_inc = 1'b1;
                default: cmd_is_auto_inc = 1'b0;
            endcase
        end
    endfunction
    
    function cmd_is_broadcast;
        input [7:0] c;
        begin
            case (c)
                CMD_BRD, CMD_BWR, CMD_BRW: cmd_is_broadcast = 1'b1;
                default: cmd_is_broadcast = 1'b0;
            endcase
        end
    endfunction

    // ========================================================================
    // CRC32 Calculation (Ethernet polynomial: 0x04C11DB7)
    // Same algorithm as transmitter for consistency
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

    // ========================================================================
    // Address Matching
    // ========================================================================
    function check_addr_match;
        input [7:0] c;
        input [15:0] adp;
        input [15:0] sta_addr;
        input [15:0] sta_alias;
        begin
            case (c)
                CMD_APRD, CMD_APWR, CMD_APRW, CMD_ARMW:
                    check_addr_match = (adp == 16'h0000);
                CMD_FPRD, CMD_FPWR, CMD_FPRW, CMD_FRMW:
                    check_addr_match = (adp == sta_addr) || (adp == sta_alias);
                CMD_BRD, CMD_BWR, CMD_BRW:
                    check_addr_match = 1'b1;
                CMD_LRD, CMD_LWR, CMD_LRW:
                    check_addr_match = 1'b1;
                default:
                    check_addr_match = 1'b0;
            endcase
        end
    endfunction

    // ========================================================================
    // Main State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            byte_cnt <= 0;
            dg_byte_cnt <= 0;
            ethertype <= 0;
            dg_cmd <= 0;
            dg_adp <= 0;
            dg_ado <= 0;
            dg_len <= 0;
            dg_more <= 0;
            dg_wkc <= 0;
            addr_matched <= 0;
            is_read_cmd <= 0;
            is_write_cmd <= 0;
            is_rw_cmd <= 0;
            crc_err <= 0;
            crc_accumulator <= 32'hFFFFFFFF;
            fcs_idx <= 0;
            total_byte_cnt <= 0;
            wkc_add <= 0;
            wkc_modified <= 0;
            data_idx <= 0;
            wr_cnt <= 0;
            wr_idx <= 0;
            fwd_valid <= 0;
            fwd_data <= 0;
            fwd_sof <= 0;
            fwd_eof <= 0;
            fwd_modified <= 0;
            mem_addr <= 0;
            mem_wdata <= 0;
            mem_be <= 0;
            mem_wr_en <= 0;
            mem_rd_en <= 0;
            log_req <= 0;
            log_wr <= 0;
            log_addr <= 0;
            log_wdata <= 0;
            frame_rx_valid <= 0;
            frame_src_mac <= 48'h0;
            frame_dst_mac <= 48'h0;
            frame_is_ecat <= 1'b0;
            frame_crc_error <= 1'b0;
            rx_frame_count <= 0;
            rx_error_count <= 0;
            rx_crc_error_count <= 0;
            wkc_increment_count <= 0;
        end else begin
            // Defaults
            fwd_valid <= 0;
            fwd_sof <= 0;
            fwd_eof <= 0;
            mem_wr_en <= 0;
            mem_rd_en <= 0;
            log_req <= 0;
            log_wr <= 0;
            frame_rx_valid <= 0;
            
            case (state)
                // ============================================================
                S_IDLE: begin
                    // BUGFIX: Check for rx_error even in IDLE state
                    if (rx_error && rx_valid) begin
                        rx_error_count <= rx_error_count + 1;
                        state <= S_ERROR;
                    end else if (rx_valid && rx_sof) begin
                        state <= S_ETH_HDR;
                        byte_cnt <= 1;
                        fwd_valid <= 1;
                        fwd_data <= rx_data;
                        fwd_sof <= 1;
                        fwd_modified <= 0;
                        wkc_modified <= 0;
                        crc_err <= 0;
                        crc_accumulator <= crc32_byte(32'hFFFFFFFF, rx_data);
                        total_byte_cnt <= 1;
                        fcs_idx <= 0;
                        ethertype <= 0;
                        wr_cnt <= 0;
                        wr_idx <= 0;
                        frame_is_ecat <= 1'b0;
                        frame_crc_error <= 1'b0;
                    end
                end
                
                // ============================================================
                S_ETH_HDR: begin
                    if (rx_error) crc_err <= 1;
                    
                    if (rx_valid) begin
                        fwd_valid <= 1;
                        fwd_data <= rx_data;
                        
                        // Accumulate CRC for all bytes
                        crc_accumulator <= crc32_byte(crc_accumulator, rx_data);
                        total_byte_cnt <= total_byte_cnt + 1;

                        // Capture MAC addresses
                        if (byte_cnt <= 5) begin
                            frame_dst_mac <= {frame_dst_mac[39:0], rx_data};
                        end else if (byte_cnt <= 11) begin
                            frame_src_mac <= {frame_src_mac[39:0], rx_data};
                        end
                        
                        if (byte_cnt == 12) ethertype[15:8] <= rx_data;
                        if (byte_cnt == 13) ethertype[7:0] <= rx_data;
                        
                        if (byte_cnt == 13) begin
                            if ({ethertype[15:8], rx_data} == ETHERTYPE_ECAT) begin
                                state <= S_ECAT_HDR;
                                frame_is_ecat <= 1'b1;
                                byte_cnt <= 0;
                            end else begin
                                state <= S_TRANSPARENT;
                            end
                        end else begin
                            byte_cnt <= byte_cnt + 1;
                        end
                    end
                    
                    if (rx_eof) begin
                        state <= S_IDLE;
                        rx_frame_count <= rx_frame_count + 1;
                        frame_rx_valid <= 1'b1;
                        frame_crc_error <= crc_err;
                    end
                end
                
                // ============================================================
                S_ECAT_HDR: begin
                    if (rx_error) crc_err <= 1;
                    
                    if (rx_valid) begin
                        fwd_valid <= 1;
                        fwd_data <= rx_data;
                        
                        // Accumulate CRC
                        crc_accumulator <= crc32_byte(crc_accumulator, rx_data);
                        total_byte_cnt <= total_byte_cnt + 1;
                        
                        if (byte_cnt == 1) begin
                            state <= S_DG_HDR;
                            byte_cnt <= 0;
                            dg_byte_cnt <= 0;
                        end else begin
                            byte_cnt <= byte_cnt + 1;
                        end
                    end
                    
                    if (rx_eof) begin
                        state <= S_IDLE;
                        rx_frame_count <= rx_frame_count + 1;
                        frame_rx_valid <= 1'b1;
                        frame_crc_error <= crc_err;
                    end
                end
                
                // ============================================================
                S_DG_HDR: begin
                    if (rx_error) crc_err <= 1;
                    
                    if (rx_valid) begin
                        // Accumulate CRC
                        crc_accumulator <= crc32_byte(crc_accumulator, rx_data);
                        total_byte_cnt <= total_byte_cnt + 1;
                        
                        case (dg_byte_cnt)
                            0: dg_cmd <= rx_data;
                            2: dg_adp[7:0] <= rx_data;
                            3: dg_adp[15:8] <= rx_data;
                            4: dg_ado[7:0] <= rx_data;
                            5: dg_ado[15:8] <= rx_data;
                            6: dg_len[7:0] <= rx_data;
                            7: begin
                                dg_len[10:8] <= rx_data[2:0];
                                dg_more <= rx_data[6];
                            end
                            9: begin
                                addr_matched <= check_addr_match(dg_cmd, dg_adp, station_address, station_alias[15:0]);
                                is_read_cmd <= (dg_cmd == CMD_APRD || dg_cmd == CMD_FPRD || dg_cmd == CMD_BRD || dg_cmd == CMD_LRD);
                                is_write_cmd <= cmd_is_write(dg_cmd);
                                is_rw_cmd <= cmd_is_rw(dg_cmd);
                                wkc_add <= 0;
                                data_idx <= 0;
                            end
                        endcase
                        
                        // Forward with ADP modification for auto-increment
                        fwd_valid <= 1;
                        if (cmd_is_auto_inc(dg_cmd) && dg_byte_cnt == 2) begin
                            fwd_data <= (dg_adp[7:0] + 1);
                            fwd_modified <= 1;
                        end else if (cmd_is_auto_inc(dg_cmd) && dg_byte_cnt == 3) begin
                            fwd_data <= ((dg_adp + 1) >> 8);
                        end else begin
                            fwd_data <= rx_data;
                        end
                        
                        if (dg_byte_cnt == 9) begin
                            state <= S_DG_DATA;
                            dg_byte_cnt <= 0;
                        end else begin
                            dg_byte_cnt <= dg_byte_cnt + 1;
                        end
                    end
                    
                    if (rx_eof) begin
                        state <= S_IDLE;
                        rx_frame_count <= rx_frame_count + 1;
                        frame_rx_valid <= 1'b1;
                        frame_crc_error <= crc_err;
                    end
                end
                
                // ============================================================
                S_DG_DATA: begin
                    if (rx_error) crc_err <= 1;
                    
                    if (rx_valid) begin
                        // Accumulate CRC
                        crc_accumulator <= crc32_byte(crc_accumulator, rx_data);
                        total_byte_cnt <= total_byte_cnt + 1;
                        
                        if (addr_matched) begin
                            // WRITE - buffer data for CRC-gated commit
                            if (is_write_cmd || is_rw_cmd) begin
                                if (wr_cnt < 32) begin
                                    if (is_log_cmd)
                                        wr_addr[wr_cnt] <= {dg_adp, dg_ado} + {21'b0, data_idx};
                                    else
                                        wr_addr[wr_cnt] <= {16'h0000, dg_ado} + {21'b0, data_idx};
                                    wr_data[wr_cnt] <= rx_data;
                                    wr_is_logical[wr_cnt] <= is_log_cmd;
                                    wr_cnt <= wr_cnt + 1;
                                end
                                
                                if (data_idx == 0) begin
                                    wkc_add <= is_rw_cmd ? 16'h0003 : 16'h0001;
                                    fwd_modified <= 1;
                                    wkc_modified <= 1;
                                end
                            end
                            
                            // READ - substitute from memory
                            if (is_read_cmd || is_rw_cmd) begin
                                if (is_log_cmd) begin
                                    log_addr <= {dg_adp, dg_ado} + {21'b0, data_idx};
                                    log_wr <= 1'b0;
                                    log_wdata <= 8'h00;
                                    log_req <= 1'b1;
                                end else begin
                                    mem_addr <= dg_ado + {5'b0, data_idx};
                                    mem_rd_en <= mem_ready;
                                end
                                
                                if (data_idx == 0) begin
                                    wkc_add <= is_rw_cmd ? 16'h0003 : 16'h0001;
                                    fwd_modified <= 1;
                                    wkc_modified <= 1;
                                end
                            end
                        end
                        
                        // Forward
                        fwd_valid <= 1;
                        if (addr_matched && (is_read_cmd || is_rw_cmd) && !crc_err) begin
                            fwd_data <= is_log_cmd ? log_rdata : mem_rdata[7:0];
                        end else begin
                            fwd_data <= rx_data;
                        end
                        
                        data_idx <= data_idx + 1;
                        
                        if (data_idx == dg_len - 1) begin
                            state <= S_DG_WKC;
                            dg_byte_cnt <= 0;
                        end
                    end
                    
                    if (rx_eof) begin
                        state <= S_IDLE;
                        rx_frame_count <= rx_frame_count + 1;
                    end
                end
                
                // ============================================================
                S_DG_WKC: begin
                    if (rx_error) crc_err <= 1;
                    
                    if (rx_valid) begin
                        // Accumulate CRC
                        crc_accumulator <= crc32_byte(crc_accumulator, rx_data);
                        total_byte_cnt <= total_byte_cnt + 1;
                        
                        case (dg_byte_cnt)
                            0: dg_wkc[7:0] <= rx_data;
                            1: dg_wkc[15:8] <= rx_data;
                        endcase
                        
                        // Forward WKC (modified if we processed data)
                        fwd_valid <= 1;
                        if (wkc_modified && !crc_err) begin
                            if (dg_byte_cnt == 0)
                                fwd_data <= rx_data + wkc_add[7:0];
                            else
                                fwd_data <= rx_data + wkc_add[15:8] + 
                                           ((dg_wkc[7:0] + wkc_add[7:0]) > 255 ? 1 : 0);
                        end else begin
                            fwd_data <= rx_data;
                        end
                        
                        if (dg_byte_cnt == 1) begin
                            // Count WKC increments
                            if (wkc_modified && !crc_err) begin
                                wkc_increment_count <= wkc_increment_count + 1;
                            end
                            
                            if (dg_more) begin
                                state <= S_DG_HDR;
                                dg_byte_cnt <= 0;
                                wkc_modified <= 0;
                            end else begin
                                state <= S_FORWARD;
                            end
                        end else begin
                            dg_byte_cnt <= dg_byte_cnt + 1;
                        end
                    end
                    
                    if (rx_eof) begin
                        // Frame ended - validate CRC
                        // CRC32 residue should equal 0xC704DD7B for valid frames
                        if (crc_accumulator != 32'hC704DD7B) begin
                            crc_err <= 1;
                            rx_crc_error_count <= rx_crc_error_count + 1;
                        end
                        
                        // Go to commit if writes pending and no errors
                        // Check rx_error directly since crc_err non-blocking update
                        // won't be visible yet on the same cycle
                        if (wr_cnt > 0 && !crc_err && !rx_error && (crc_accumulator == 32'hC704DD7B)) begin
                            state <= S_COMMIT_WR;
                            wr_idx <= 0;
                        end else begin
                            state <= S_IDLE;
                        end
                        fwd_eof <= 1;
                        rx_frame_count <= rx_frame_count + 1;
                    end
                end
                
                // ============================================================
                S_FORWARD: begin
                    if (rx_valid) begin
                        fwd_valid <= 1;
                        fwd_data <= rx_data;
                        
                        // Continue accumulating CRC (includes FCS bytes)
                        crc_accumulator <= crc32_byte(crc_accumulator, rx_data);
                        total_byte_cnt <= total_byte_cnt + 1;
                    end
                    if (rx_error) crc_err <= 1;
                    if (rx_eof) begin
                        fwd_eof <= 1;
                        rx_frame_count <= rx_frame_count + 1;
                        
                        // CRC32 validation: After processing all bytes including FCS,
                        // the CRC residue should equal the magic constant 0xC704DD7B
                        // if the frame is valid. Check on the accumulated value.
                        if (crc_accumulator != 32'hC704DD7B) begin
                            crc_err <= 1;
                            rx_crc_error_count <= rx_crc_error_count + 1;
                        end
                        
                        // Go to commit writes if pending and no CRC error
                        // Check rx_error directly for same-cycle error detection
                        // Also check CRC validation result
                        if (wr_cnt > 0 && !crc_err && !rx_error && (crc_accumulator == 32'hC704DD7B)) begin
                            state <= S_COMMIT_WR;
                            wr_idx <= 0;
                        end else begin
                            state <= S_IDLE;
                        end
                    end
                end
                
                // ============================================================
                S_COMMIT_WR: begin
                    // Commit buffered writes one at a time
                    if (wr_idx < wr_cnt) begin
                        if (wr_is_logical[wr_idx]) begin
                            log_addr <= wr_addr[wr_idx];
                            log_wr <= 1'b1;
                            log_wdata <= wr_data[wr_idx];
                            log_req <= 1'b1;
                            if (log_ack) begin
                                wr_idx <= wr_idx + 1;
                            end
                        end else begin
                            mem_addr <= wr_addr[wr_idx][15:0];
                            mem_wdata <= {8'h00, wr_data[wr_idx]};
                            mem_be <= 2'b01;
                            mem_wr_en <= 1;
                            wr_idx <= wr_idx + 1;
                        end
                    end else begin
                        state <= S_IDLE;
                        wr_cnt <= 0;
                    end
                end
                
                // ============================================================
                S_TRANSPARENT: begin
                    if (rx_valid) begin
                        fwd_valid <= 1;
                        fwd_data <= rx_data;
                        // Accumulate CRC for transparent frames too
                        crc_accumulator <= crc32_byte(crc_accumulator, rx_data);
                        total_byte_cnt <= total_byte_cnt + 1;
                    end
                    if (rx_eof) begin
                        fwd_eof <= 1;
                        rx_frame_count <= rx_frame_count + 1;
                        // Validate CRC for transparent frames
                        if (crc_accumulator != 32'hC704DD7B) begin
                            crc_err <= 1;
                            rx_error_count <= rx_error_count + 1;
                        end
                        state <= S_IDLE;
                        frame_rx_valid <= 1'b1;
                        frame_crc_error <= (crc_accumulator != 32'hC704DD7B);
                    end
                end
                
                // ============================================================
                S_ERROR: begin
                    rx_error_count <= rx_error_count + 1;
                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

    // ========================================================================
    // SVA Formal Assertions (Frame Receiver Correctness)
    // ========================================================================
    `ifdef FORMAL
    
    // CRC magic constant for validation
    localparam CRC32_VALID_RESIDUE = 32'hC704DD7B;
    
    // No write commit if CRC error
    property no_commit_on_crc_error;
        @(posedge clk) disable iff (!rst_n)
        (crc_err) |-> (state != S_COMMIT_WR)[*1:$];
    endproperty
    assert property (no_commit_on_crc_error) else $error("Write commit with CRC error");
    
    // CRC error count monotonically increases
    property crc_error_count_monotonic;
        @(posedge clk) disable iff (!rst_n)
        (rx_crc_error_count >= $past(rx_crc_error_count));
    endproperty
    assert property (crc_error_count_monotonic);
    
    // Frame count increases on EOF
    property frame_count_on_eof;
        @(posedge clk) disable iff (!rst_n)
        (rx_eof && state != S_IDLE) |=> (rx_frame_count == $past(rx_frame_count) + 1);
    endproperty
    
    // State machine valid states
    property valid_state;
        @(posedge clk) disable iff (!rst_n)
        (state inside {S_IDLE, S_ETH_HDR, S_ECAT_HDR, S_DG_HDR, S_DG_DATA, 
                       S_DG_WKC, S_FORWARD, S_COMMIT_WR, S_TRANSPARENT, S_ERROR});
    endproperty
    assert property (valid_state) else $error("Invalid state");
    
    // Forward valid implies we have data
    property fwd_valid_has_data;
        @(posedge clk) disable iff (!rst_n)
        (fwd_valid) |-> (state != S_IDLE && state != S_COMMIT_WR);
    endproperty
    
    // Memory write enable is single cycle
    property mem_wr_single_cycle;
        @(posedge clk) disable iff (!rst_n)
        (mem_wr_en) |=> (!mem_wr_en || state == S_COMMIT_WR);
    endproperty
    
    // WKC increment count accuracy
    property wkc_increment_valid;
        @(posedge clk) disable iff (!rst_n)
        (wkc_modified && state == S_DG_WKC && dg_byte_cnt == 1 && !crc_err) |=>
        (wkc_increment_count == $past(wkc_increment_count) + 1);
    endproperty
    assert property (wkc_increment_valid) else $error("WKC increment mismatch");
    
    // Cover: Valid EtherCAT frame processed
    cover property (@(posedge clk) disable iff (!rst_n)
        (state == S_DG_HDR) ##[1:1000] (state == S_FORWARD) ##[1:100] 
        (rx_eof && crc_accumulator == CRC32_VALID_RESIDUE));
    
    // Cover: CRC error detected
    cover property (@(posedge clk) disable iff (!rst_n)
        (rx_eof && crc_accumulator != CRC32_VALID_RESIDUE));
    
    `endif

endmodule
