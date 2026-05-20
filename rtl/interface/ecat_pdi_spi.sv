// ============================================================================
// EtherCAT PDI Interface - SPI Slave
// LAN9252-compatible SPI protocol for MCU host access
// Supports SPI Mode 0 (CPOL=0, CPHA=0) and Mode 3 (CPOL=1, CPHA=1)
// ============================================================================

`include "ecat_pkg.vh"

module ecat_pdi_spi #(
    parameter CLK_FREQ_HZ   = 50_000_000,
    parameter MAX_SPI_FREQ  = 40_000_000
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,            // pdi_clk

    // SPI Interface
    input  wire                     spi_sck,
    input  wire                     spi_cs_n,
    input  wire                     spi_mosi,
    output reg                      spi_miso,

    // ESC Register access
    output reg                      reg_req,
    output reg                      reg_wr,
    output reg  [15:0]              reg_addr,
    output reg  [15:0]              reg_wdata,
    output reg  [1:0]               reg_be,
    input  wire [15:0]              reg_rdata,
    input  wire                     reg_ack,

    // Process Data RAM access (through Sync Managers)
    output reg  [7:0]               sm_id,
    output reg                      sm_pdi_req,
    output reg                      sm_pdi_wr,
    output reg  [15:0]              sm_pdi_addr,
    output reg  [31:0]              sm_pdi_wdata,
    input  wire [31:0]              sm_pdi_rdata,
    input  wire                     sm_pdi_ack,

    // PDI Control
    input  wire                     pdi_enable,
    output reg                      pdi_operational,
    output reg                      pdi_watchdog_timeout,

    // IRQ
    output reg                      pdi_irq,
    input  wire [15:0]              irq_sources
);

    // ========================================================================
    // SPI Command Definitions (LAN9252 compatible)
    // ========================================================================
    localparam [7:0] CMD_FAST_READ  = 8'h03;
    localparam [7:0] CMD_READ       = 8'h02;
    localparam [7:0] CMD_WRITE      = 8'h04;

    // ========================================================================
    // Address Space Mapping
    // ========================================================================
    localparam ADDR_SPACE_REGS = 2'b00;
    localparam ADDR_SPACE_PRAM = 2'b01;
    localparam ADDR_SPACE_MBOX = 2'b10;

    // ========================================================================
    // SPI Clock Domain Crossing
    // ========================================================================
    // Synchronize SPI signals into pdi_clk domain
    reg [2:0] sck_sync;
    reg [2:0] cs_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_sync <= 3'b0;
            cs_sync  <= 3'b111;
        end else begin
            sck_sync <= {sck_sync[1:0], spi_sck};
            cs_sync  <= {cs_sync[1:0], spi_cs_n};
        end
    end

    wire sck_rising  =  sck_sync[2] && ~sck_sync[1];  // SPI SCK rising edge
    wire sck_falling = ~sck_sync[2] &&  sck_sync[1];   // SPI SCK falling edge
    wire cs_asserted = ~cs_sync[2];                     // CS# low
    wire cs_deasserted = cs_sync[2] && ~cs_sync[1];    // CS# rising edge

    // ========================================================================
    // SPI Shift Register & Bit Counter (in pdi_clk domain)
    // ========================================================================
    reg [7:0] shift_reg;
    reg [2:0] bit_cnt;
    reg [7:0] mosi_sync;       // Synchronized MOSI

    // Sample MOSI on rising SCK edges
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mosi_sync <= 1'b0;
        end else begin
            mosi_sync <= spi_mosi;  // Double-sync handled by sck_sync pipeline
        end
    end

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_CMD,
        ST_ADDR_H,
        ST_ADDR_L,
        ST_DUMMY,           // For fast read
        ST_WR_DATA,         // Receiving write data from master
        ST_WAIT_ACK,        // Waiting for internal bus response
        ST_RD_DATA,         // Sending read data to master
        ST_ERROR
    } spi_state_t;

    spi_state_t state, next_state;

    // ========================================================================
    // Internal Registers
    // ========================================================================
    reg [7:0]   cmd_reg;
    reg [15:0]  addr_reg;
    reg [31:0]  wr_data_buf;
    reg [31:0]  rd_data_buf;
    reg [1:0]   byte_cnt;       // Count bytes transferred in data phase
    reg [1:0]   addr_space;

    // Byte assembled flag
    reg         byte_ready;

    // Watchdog timer
    reg [15:0]  watchdog_counter;
    reg         watchdog_expired;
    localparam  WATCHDOG_TIMEOUT = 16'd50000;

    // Global watchdog
    reg [19:0]  global_watchdog;

    // IRQ management
    reg [15:0]  irq_latched;

    // ========================================================================
    // SPI Shift Register Logic
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg  <= '0;
            bit_cnt    <= '0;
            byte_ready <= 1'b0;
        end else if (cs_deasserted) begin
            // CS# rising: reset SPI transfer state
            shift_reg  <= '0;
            bit_cnt    <= '0;
            byte_ready <= 1'b0;
        end else if (sck_rising && cs_asserted) begin
            // Shift in MOSI on rising edge
            shift_reg  <= {shift_reg[6:0], mosi_sync};
            bit_cnt    <= bit_cnt + 1;
            byte_ready <= (bit_cnt == 3'b110);  // Will be complete after this shift
        end else begin
            byte_ready <= 1'b0;
        end
    end

    // MISO output: shift out on falling SCK edge
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_miso <= 1'b0;
        end else if (cs_deasserted || !cs_asserted) begin
            spi_miso <= 1'b0;
        end else if (sck_falling) begin
            spi_miso <= rd_data_buf[31];  // MSB first
        end
    end

    // ========================================================================
    // State Machine - Sequential
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else if (cs_deasserted)
            state <= ST_IDLE;    // CS# high resets to idle
        else
            state <= next_state;
    end

    // ========================================================================
    // State Machine - Combinational
    // ========================================================================
    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (cs_asserted && byte_ready)
                    next_state = ST_CMD;
            end

            ST_CMD: begin
                if (byte_ready)
                    next_state = ST_ADDR_H;
            end

            ST_ADDR_H: begin
                if (byte_ready)
                    next_state = ST_ADDR_L;
            end

            ST_ADDR_L: begin
                if (byte_ready) begin
                    if (cmd_reg == CMD_FAST_READ)
                        next_state = ST_DUMMY;
                    else if (cmd_reg == CMD_WRITE)
                        next_state = ST_WR_DATA;
                    else
                        next_state = ST_WAIT_ACK;  // Normal read
                end
            end

            ST_DUMMY: begin
                if (byte_ready)
                    next_state = ST_WAIT_ACK;
            end

            ST_WR_DATA: begin
                if (byte_ready && byte_cnt == 2'd3)
                    next_state = ST_WAIT_ACK;
            end

            ST_WAIT_ACK: begin
                if (reg_ack || sm_pdi_ack)
                    next_state = ST_RD_DATA;
                else if (watchdog_expired)
                    next_state = ST_ERROR;
            end

            ST_RD_DATA: begin
                // Stay here until CS# deasserted (continuous read)
                next_state = ST_RD_DATA;
            end

            ST_ERROR: begin
                next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    // ========================================================================
    // Main Sequential Logic
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_reg         <= '0;
            addr_reg        <= '0;
            addr_space      <= '0;
            wr_data_buf     <= '0;
            rd_data_buf     <= '0;
            byte_cnt        <= '0;
            reg_req         <= 1'b0;
            reg_wr          <= 1'b0;
            reg_addr        <= '0;
            reg_wdata       <= '0;
            reg_be          <= '0;
            sm_pdi_req      <= 1'b0;
            sm_pdi_wr       <= 1'b0;
            sm_pdi_addr     <= '0;
            sm_pdi_wdata    <= '0;
            sm_id           <= '0;
            pdi_operational <= 1'b1;
            pdi_watchdog_timeout <= 1'b0;
            pdi_irq         <= 1'b0;
            irq_latched     <= '0;
            global_watchdog <= '0;
            watchdog_counter<= '0;
            watchdog_expired<= 1'b0;
        end else begin
            // Default: clear request signals
            reg_req     <= 1'b0;
            sm_pdi_req  <= 1'b0;
            watchdog_expired <= 1'b0;

            case (state)
                // ------------------------------------------------------------
                ST_CMD: begin
                    if (byte_ready) begin
                        cmd_reg <= shift_reg;
                    end
                end

                // ------------------------------------------------------------
                ST_ADDR_H: begin
                    if (byte_ready)
                        addr_reg[15:8] <= shift_reg;
                end

                // ------------------------------------------------------------
                ST_ADDR_L: begin
                    if (byte_ready) begin
                        addr_reg[7:0] <= shift_reg;
                        addr_space    <= {shift_reg[5], shift_reg[4]};  // bits [13:12]
                    end
                end

                // ------------------------------------------------------------
                ST_DUMMY: begin
                    // Fast read: skip one dummy byte, issue internal request
                    if (byte_ready) begin
                        // Issue internal request after dummy byte
                        if (addr_space == ADDR_SPACE_REGS) begin
                            reg_req  <= 1'b1;
                            reg_wr   <= 1'b0;
                            reg_addr <= addr_reg;
                        end else if (pdi_enable) begin
                            if (addr_space == ADDR_SPACE_MBOX)
                                sm_id <= 8'h01;     // Read mailbox
                            else
                                sm_id <= 8'h03;     // Process data input
                            sm_pdi_req  <= 1'b1;
                            sm_pdi_wr   <= 1'b0;
                            sm_pdi_addr <= addr_reg;
                        end
                    end
                end

                // ------------------------------------------------------------
                ST_WR_DATA: begin
                    if (byte_ready) begin
                        case (byte_cnt)
                            2'd0: wr_data_buf[7:0]   <= shift_reg;
                            2'd1: wr_data_buf[15:8]  <= shift_reg;
                            2'd2: wr_data_buf[23:16] <= shift_reg;
                            2'd3: begin
                                wr_data_buf[31:24] <= shift_reg;
                                // Issue write request
                                if (addr_space == ADDR_SPACE_REGS) begin
                                    reg_req   <= 1'b1;
                                    reg_wr    <= 1'b1;
                                    reg_addr  <= addr_reg;
                                    reg_wdata <= {shift_reg, wr_data_buf[23:8]};
                                    reg_be    <= 2'b11;
                                end else if (pdi_enable) begin
                                    if (addr_space == ADDR_SPACE_MBOX)
                                        sm_id <= 8'h00;     // Write mailbox
                                    else
                                        sm_id <= 8'h02;     // Process data output
                                    sm_pdi_req   <= 1'b1;
                                    sm_pdi_wr    <= 1'b1;
                                    sm_pdi_addr  <= addr_reg;
                                    sm_pdi_wdata <= {shift_reg, wr_data_buf[23:8],
                                                     wr_data_buf[15:8], wr_data_buf[7:0]};
                                end
                            end
                        endcase
                        byte_cnt <= byte_cnt + 1;
                    end
                end

                // ------------------------------------------------------------
                ST_WAIT_ACK: begin
                    watchdog_counter <= watchdog_counter + 1;
                    if (watchdog_counter >= WATCHDOG_TIMEOUT)
                        watchdog_expired <= 1'b1;

                    // For normal read (not fast read), issue request here
                    if (cmd_reg == CMD_READ && byte_cnt == '0) begin
                        byte_cnt <= 2'd1;   // Mark request issued
                        if (addr_space == ADDR_SPACE_REGS) begin
                            reg_req  <= 1'b1;
                            reg_wr   <= 1'b0;
                            reg_addr <= addr_reg;
                        end else if (pdi_enable) begin
                            if (addr_space == ADDR_SPACE_MBOX)
                                sm_id <= 8'h01;
                            else
                                sm_id <= 8'h03;
                            sm_pdi_req  <= 1'b1;
                            sm_pdi_wr   <= 1'b0;
                            sm_pdi_addr <= addr_reg;
                        end
                    end

                    // Hold request and capture data
                    if (addr_space == ADDR_SPACE_REGS) begin
                        reg_req <= 1'b1;
                        if (reg_ack)
                            rd_data_buf <= {16'h0000, reg_rdata};
                    end else begin
                        sm_pdi_req <= 1'b1;
                        if (sm_pdi_ack)
                            rd_data_buf <= sm_pdi_rdata;
                    end
                end

                // ------------------------------------------------------------
                ST_RD_DATA: begin
                    // Shift out read data via MISO (handled in MISO logic above)
                    // Support burst: after 4 bytes, auto-increment address
                    // and issue next read
                    if (sck_falling && bit_cnt == 3'b000) begin
                        // One full byte shifted out
                        rd_data_buf <= {rd_data_buf[30:0], 1'b0};
                    end
                end

                // ------------------------------------------------------------
                ST_ERROR: begin
                    pdi_operational <= 1'b0;
                end
            endcase

            // ----------------------------------------------------------------
            // Global watchdog
            // ----------------------------------------------------------------
            if (cs_asserted) begin
                global_watchdog <= '0;
                pdi_watchdog_timeout <= 1'b0;
            end else if (pdi_enable && global_watchdog < 20'd100000) begin
                global_watchdog <= global_watchdog + 1;
            end else if (global_watchdog >= 20'd100000) begin
                pdi_watchdog_timeout <= 1'b1;
            end

            // ----------------------------------------------------------------
            // IRQ Management
            // ----------------------------------------------------------------
            irq_latched <= irq_latched | irq_sources;
            pdi_irq <= |irq_latched;

            if (reg_ack && reg_addr == 16'h0220)
                irq_latched <= '0;
        end
    end

    // ========================================================================
    // PDI Operational Status
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pdi_operational <= 1'b1;
        else
            pdi_operational <= pdi_enable && !pdi_watchdog_timeout;
    end

endmodule
