// ============================================================================
// EtherCAT MDIO Master for PHY Management
// Implements IEEE 802.3 Clause 22 MDIO protocol
// ESC Registers 0x0510-0x0517
// P2 Medium Priority Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_mdio_master #(
    parameter CLK_FREQ_HZ = 25000000,     // System clock frequency
    parameter MDC_FREQ_HZ = 2500000       // MDC clock frequency (max 2.5MHz)
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Register interface (ESC registers 0x0510-0x0517)
    input  wire                     reg_req,
    input  wire                     reg_wr,
    input  wire [15:0]              reg_addr,
    input  wire [15:0]              reg_wdata,
    output reg  [15:0]              reg_rdata,
    output reg                      reg_ack,
    
    // MDIO interface (directly to PHY)
    output reg                      mdc,              // Management Data Clock
    output reg                      mdio_o,           // MDIO output
    output reg                      mdio_oe,          // MDIO output enable
    input  wire                     mdio_i,           // MDIO input
    
    // Status
    output wire                     mdio_busy,
    output wire                     mdio_error
);

    // ========================================================================
    // ESC MII Management Registers (ETG.1000)
    // ========================================================================
    // 0x0510: MII Management Control/Status (16-bit)
    //         Bit 0: Command/Busy (W: start, R: busy)
    //         Bit 1: Read/Write (0=write, 1=read)
    //         Bit 2-6: PHY address
    //         Bit 7-11: Register address
    //         Bit 12-14: Reserved
    //         Bit 15: Error
    // 0x0512: PHY Data (16-bit read/write data)
    // 0x0514: MII Management ECAT Processing Unit Control (16-bit)
    // 0x0516: Reserved
    
    localparam REG_MII_CTRL      = 16'h0510;  // MII Control/Status
    localparam REG_MII_PHY_ADDR  = 16'h0511;  // PHY address (upper byte of ctrl)
    localparam REG_MII_PHY_DATA  = 16'h0512;  // PHY Data
    localparam REG_MII_PHY_DATA_H= 16'h0513;  // PHY Data high byte
    localparam REG_MII_EPU_CTRL  = 16'h0514;  // EPU Control

    // ========================================================================
    // MDIO Frame Format (IEEE 802.3 Clause 22)
    // ========================================================================
    // Preamble: 32 bits of 1
    // Start:    01
    // Operation: 10 (read), 01 (write)
    // PHY Addr:  5 bits
    // Reg Addr:  5 bits
    // Turnaround: 2 bits (Z0 for read, 10 for write)
    // Data:      16 bits
    
    localparam MDIO_PREAMBLE = 32'hFFFFFFFF;
    localparam MDIO_START    = 2'b01;
    localparam MDIO_OP_READ  = 2'b10;
    localparam MDIO_OP_WRITE = 2'b01;

    // ========================================================================
    // MDC Clock Divider
    // ========================================================================
    localparam MDC_CLKDIV = (CLK_FREQ_HZ / (2 * MDC_FREQ_HZ)) - 1;
    
    reg [7:0]   clk_cnt;
    reg         mdc_tick;   // Half-period tick
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 8'h0;
            mdc_tick <= 1'b0;
        end else begin
            if (clk_cnt >= MDC_CLKDIV[7:0]) begin
                clk_cnt <= 8'h0;
                mdc_tick <= 1'b1;
            end else begin
                clk_cnt <= clk_cnt + 1;
                mdc_tick <= 1'b0;
            end
        end
    end

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_PREAMBLE,
        ST_START,
        ST_OPCODE,
        ST_PHY_ADDR,
        ST_REG_ADDR,
        ST_TURNAROUND,
        ST_DATA,
        ST_DONE,
        ST_ERROR
    } mdio_state_t;
    
    mdio_state_t state;

    // ========================================================================
    // Internal Registers
    // ========================================================================
    // Control registers
    reg         cmd_busy;
    reg         cmd_read;           // 0=write, 1=read
    reg [4:0]   phy_address;
    reg [4:0]   phy_reg_addr;
    reg [15:0]  phy_data;
    reg         cmd_error;
    
    // MDIO transfer state
    reg [5:0]   bit_cnt;
    reg [31:0]  shift_reg;
    reg         mdc_phase;          // 0=falling edge, 1=rising edge

    assign mdio_busy = cmd_busy;
    assign mdio_error = cmd_error;

    // ========================================================================
    // Register Interface
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_rdata <= 16'h0;
            reg_ack <= 1'b0;
            cmd_read <= 1'b0;
            phy_address <= 5'b0;
            phy_reg_addr <= 5'b0;
        end else begin
            reg_ack <= 1'b0;
            
            if (reg_req && !reg_ack) begin
                reg_ack <= 1'b1;
                
                if (reg_wr) begin
                    case (reg_addr)
                        REG_MII_CTRL: begin
                            // Bit 0: Start command
                            if (reg_wdata[0] && !cmd_busy) begin
                                cmd_read <= reg_wdata[1];
                                phy_address <= reg_wdata[6:2];
                                phy_reg_addr <= reg_wdata[11:7];
                            end
                        end
                        REG_MII_PHY_DATA: begin
                            if (!cmd_busy) begin
                                phy_data <= reg_wdata;
                            end
                        end
                    endcase
                end else begin
                    case (reg_addr)
                        REG_MII_CTRL: begin
                            reg_rdata <= {cmd_error, 3'b000, phy_reg_addr, phy_address, cmd_read, cmd_busy};
                        end
                        REG_MII_PHY_DATA: begin
                            reg_rdata <= phy_data;
                        end
                        default: reg_rdata <= 16'h0;
                    endcase
                end
            end
        end
    end

    // ========================================================================
    // MDIO State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            mdc <= 1'b0;
            mdio_o <= 1'b1;
            mdio_oe <= 1'b0;
            cmd_busy <= 1'b0;
            cmd_error <= 1'b0;
            bit_cnt <= 6'h0;
            shift_reg <= 32'h0;
            mdc_phase <= 1'b0;
        end else begin
            if (mdc_tick) begin
                // Toggle MDC on each tick
                mdc <= ~mdc;
                mdc_phase <= ~mdc_phase;
                
                case (state)
                    // ========================================================
                    ST_IDLE: begin
                        mdc <= 1'b0;
                        mdio_o <= 1'b1;
                        mdio_oe <= 1'b0;
                        cmd_error <= 1'b0;
                        
                        // Check for new command
                        if (reg_req && reg_wr && reg_addr == REG_MII_CTRL && reg_wdata[0] && !cmd_busy) begin
                            state <= ST_PREAMBLE;
                            bit_cnt <= 6'd32;
                            cmd_busy <= 1'b1;
                            mdio_oe <= 1'b1;
                            mdio_o <= 1'b1;
                        end
                    end
                    
                    // ========================================================
                    ST_PREAMBLE: begin
                        // Output 32 bits of 1
                        mdio_oe <= 1'b1;
                        mdio_o <= 1'b1;
                        
                        if (mdc_phase) begin  // Rising edge
                            if (bit_cnt == 1) begin
                                state <= ST_START;
                                bit_cnt <= 6'd2;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                    
                    // ========================================================
                    ST_START: begin
                        // Output start sequence: 01
                        mdio_oe <= 1'b1;
                        
                        if (!mdc_phase) begin  // Falling edge - setup data
                            mdio_o <= (bit_cnt == 2) ? 1'b0 : 1'b1;
                        end
                        
                        if (mdc_phase) begin  // Rising edge
                            if (bit_cnt == 1) begin
                                state <= ST_OPCODE;
                                bit_cnt <= 6'd2;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                    
                    // ========================================================
                    ST_OPCODE: begin
                        // Output opcode: 10 (read) or 01 (write)
                        mdio_oe <= 1'b1;
                        
                        if (!mdc_phase) begin
                            if (cmd_read)
                                mdio_o <= (bit_cnt == 2) ? 1'b1 : 1'b0;  // 10
                            else
                                mdio_o <= (bit_cnt == 2) ? 1'b0 : 1'b1;  // 01
                        end
                        
                        if (mdc_phase) begin
                            if (bit_cnt == 1) begin
                                state <= ST_PHY_ADDR;
                                bit_cnt <= 6'd5;
                                shift_reg <= {27'b0, phy_address};
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                    
                    // ========================================================
                    ST_PHY_ADDR: begin
                        // Output 5-bit PHY address (MSB first)
                        mdio_oe <= 1'b1;
                        
                        if (!mdc_phase) begin
                            mdio_o <= shift_reg[4];
                        end
                        
                        if (mdc_phase) begin
                            shift_reg <= {shift_reg[30:0], 1'b0};
                            if (bit_cnt == 1) begin
                                state <= ST_REG_ADDR;
                                bit_cnt <= 6'd5;
                                shift_reg <= {27'b0, phy_reg_addr};
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                    
                    // ========================================================
                    ST_REG_ADDR: begin
                        // Output 5-bit register address (MSB first)
                        mdio_oe <= 1'b1;
                        
                        if (!mdc_phase) begin
                            mdio_o <= shift_reg[4];
                        end
                        
                        if (mdc_phase) begin
                            shift_reg <= {shift_reg[30:0], 1'b0};
                            if (bit_cnt == 1) begin
                                state <= ST_TURNAROUND;
                                bit_cnt <= 6'd2;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                    
                    // ========================================================
                    ST_TURNAROUND: begin
                        // Turnaround: Z0 for read, 10 for write
                        if (cmd_read) begin
                            // Release bus for read
                            mdio_oe <= 1'b0;
                        end else begin
                            // Drive 10 for write
                            mdio_oe <= 1'b1;
                            if (!mdc_phase) begin
                                mdio_o <= (bit_cnt == 2) ? 1'b1 : 1'b0;
                            end
                        end
                        
                        if (mdc_phase) begin
                            if (bit_cnt == 1) begin
                                state <= ST_DATA;
                                bit_cnt <= 6'd16;
                                if (!cmd_read) begin
                                    shift_reg <= {16'b0, phy_data};
                                end
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end
                    end
                    
                    // ========================================================
                    ST_DATA: begin
                        if (cmd_read) begin
                            // Read: sample MDIO on rising edge
                            mdio_oe <= 1'b0;
                            
                            if (mdc_phase) begin
                                shift_reg <= {shift_reg[30:0], mdio_i};
                                if (bit_cnt == 1) begin
                                    phy_data <= {shift_reg[14:0], mdio_i};
                                    state <= ST_DONE;
                                end else begin
                                    bit_cnt <= bit_cnt - 1;
                                end
                            end
                        end else begin
                            // Write: output data MSB first
                            mdio_oe <= 1'b1;
                            
                            if (!mdc_phase) begin
                                mdio_o <= shift_reg[15];
                            end
                            
                            if (mdc_phase) begin
                                shift_reg <= {shift_reg[30:0], 1'b0};
                                if (bit_cnt == 1) begin
                                    state <= ST_DONE;
                                end else begin
                                    bit_cnt <= bit_cnt - 1;
                                end
                            end
                        end
                    end
                    
                    // ========================================================
                    ST_DONE: begin
                        mdio_oe <= 1'b0;
                        mdio_o <= 1'b1;
                        cmd_busy <= 1'b0;
                        state <= ST_IDLE;
                    end
                    
                    // ========================================================
                    ST_ERROR: begin
                        mdio_oe <= 1'b0;
                        cmd_busy <= 1'b0;
                        cmd_error <= 1'b1;
                        state <= ST_IDLE;
                    end
                    
                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
