// ============================================================================
// EtherCAT PDI Interface - Parallel MCU Bus (8/16-bit)
// Asynchronous memory-mapped peripheral interface for MCU host access
// ============================================================================

`include "ecat_pkg.vh"

module ecat_pdi_parallel #(
    parameter DATA_WIDTH = 8,       // 8 or 16
    parameter ADDR_WIDTH = 16
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,            // pdi_clk

    // Parallel MCU bus interface
    inout  wire [DATA_WIDTH-1:0]    mcu_data,       // Bidirectional data bus
    input  wire [ADDR_WIDTH-1:0]    mcu_addr,       // Address bus
    input  wire                     mcu_cs_n,       // Chip select (active low)
    input  wire                     mcu_rd_n,       // Read strobe (active low)
    input  wire                     mcu_wr_n,       // Write strobe (active low)
    input  wire                     mcu_ale,        // Address latch enable
    output reg                      mcu_wait_n,     // Wait signal (active low)
    output wire                     mcu_irq,        // Interrupt to MCU

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
    input  wire [15:0]              irq_sources
);

    // ========================================================================
    // Address Space Mapping (same as Avalon)
    // ========================================================================
    localparam ADDR_SPACE_REGS = 2'b00;  // 0x0000-0x0FFF
    localparam ADDR_SPACE_PRAM = 2'b01;  // 0x1000-0x1FFF
    localparam ADDR_SPACE_MBOX = 2'b10;  // 0x2000-0x2FFF

    // ========================================================================
    // State Machine
    // ========================================================================
    typedef enum logic [2:0] {
        IDLE,
        REG_ACCESS,
        SM_ACCESS,
        WAIT_ACK,
        DONE,
        ERROR
    } pdi_state_t;

    pdi_state_t state, next_state;

    // ========================================================================
    // Synchronize async MCU bus signals into pdi_clk domain
    // ========================================================================
    reg [2:0] cs_sync;
    reg [2:0] rd_sync;
    reg [2:0] wr_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs_sync <= 3'b111;
            rd_sync <= 3'b111;
            wr_sync <= 3'b111;
        end else begin
            cs_sync <= {cs_sync[1:0], mcu_cs_n};
            rd_sync <= {rd_sync[1:0], mcu_rd_n};
            wr_sync <= {wr_sync[1:0], mcu_wr_n};
        end
    end

    // Edge detection (after sync)
    wire cs_active   = ~cs_sync[2];                    // CS# is low
    wire rd_falling  = ~rd_sync[2] & rd_sync[1];       // RD# falling edge
    wire wr_falling  = ~wr_sync[2] & wr_sync[1];       // WR# falling edge
    wire rd_active   = ~rd_sync[2];
    wire wr_active   = ~wr_sync[2];

    // ========================================================================
    // Address latch (for ALE mode) and sampled address
    // ========================================================================
    reg [ADDR_WIDTH-1:0] latched_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            latched_addr <= '0;
        else if (cs_active)
            latched_addr <= mcu_addr;
    end

    // ========================================================================
    // Internal Registers
    // ========================================================================
    reg [1:0]   addr_space;
    reg [15:0]  access_addr;
    reg [31:0]  write_data;
    reg [3:0]   byte_enable;
    reg         is_write;
    reg         is_read;
    reg [31:0]  read_data_buf;

    // Watchdog timer
    reg [15:0]  watchdog_counter;
    reg         watchdog_expired;
    localparam  WATCHDOG_TIMEOUT = 16'd50000;

    // Global watchdog
    reg [19:0]  global_watchdog;

    // IRQ management
    reg [15:0]  irq_latched;

    // Data bus output register
    reg [DATA_WIDTH-1:0] data_out;
    reg                  data_oe;      // Output enable for tri-state

    // ========================================================================
    // State Machine - Sequential
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // ========================================================================
    // State Machine - Combinational
    // ========================================================================
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (cs_active && (rd_falling || wr_falling)) begin
                    if (addr_space == ADDR_SPACE_REGS)
                        next_state = REG_ACCESS;
                    else if (pdi_enable)
                        next_state = SM_ACCESS;
                    else
                        next_state = ERROR;
                end
            end

            REG_ACCESS:   next_state = WAIT_ACK;
            SM_ACCESS:    next_state = WAIT_ACK;

            WAIT_ACK: begin
                if (reg_ack || sm_pdi_ack)
                    next_state = DONE;
                else if (watchdog_expired)
                    next_state = ERROR;
            end

            DONE:   next_state = IDLE;
            ERROR:  next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    // ========================================================================
    // Main Sequential Logic
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
            addr_space      <= '0;
            access_addr     <= '0;
            write_data      <= '0;
            byte_enable     <= '0;
            is_write        <= 1'b0;
            is_read         <= 1'b0;
            read_data_buf   <= '0;
            data_out        <= '0;
            data_oe         <= 1'b0;
            mcu_wait_n      <= 1'b1;
            watchdog_counter<= '0;
            watchdog_expired<= 1'b0;
            pdi_operational <= 1'b1;
            pdi_watchdog_timeout <= 1'b0;
            global_watchdog <= '0;
            irq_latched     <= '0;
        end else begin
            // Default: clear handshake signals
            reg_req         <= 1'b0;
            sm_pdi_req      <= 1'b0;
            watchdog_expired<= 1'b0;
            data_oe         <= 1'b0;

            case (state)
                // ------------------------------------------------------------
                IDLE: begin
                    mcu_wait_n <= 1'b1;
                    watchdog_counter <= '0;

                    if (cs_active && (rd_falling || wr_falling)) begin
                        // Capture address space and address
                        addr_space  <= latched_addr[13:12];
                        access_addr <= latched_addr;
                        is_write    <= wr_falling;
                        is_read     <= rd_falling;
                        mcu_wait_n  <= 1'b0;     // Assert wait immediately

                        // Sample write data from bus
                        if (wr_falling) begin
                            write_data[DATA_WIDTH-1:0] <= mcu_data;
                            if (DATA_WIDTH == 8) begin
                                byte_enable <= 4'h03;     // Low 2 bytes
                            end else begin
                                byte_enable <= 4'h0F;     // All 4 bytes
                            end
                        end else begin
                            byte_enable <= '0;
                        end
                    end
                end

                // ------------------------------------------------------------
                REG_ACCESS: begin
                    reg_req  <= 1'b1;
                    reg_wr   <= is_write;
                    reg_addr <= access_addr;

                    if (is_write) begin
                        if (DATA_WIDTH == 8) begin
                            // 8-bit: single byte write to low half of 16-bit register
                            reg_wdata <= {8'h00, write_data[7:0]};
                            reg_be    <= byte_enable[1:0];
                        end else begin
                            // 16-bit: full register write
                            reg_wdata <= write_data[15:0];
                            reg_be    <= byte_enable[1:0];
                        end
                    end
                end

                // ------------------------------------------------------------
                SM_ACCESS: begin
                    // Select SM based on address space
                    if (addr_space == ADDR_SPACE_MBOX) begin
                        sm_id <= is_write ? 8'h00 : 8'h01;
                    end else begin
                        sm_id <= is_write ? 8'h02 : 8'h03;
                    end

                    sm_pdi_req  <= 1'b1;
                    sm_pdi_wr   <= is_write;
                    sm_pdi_addr <= access_addr;

                    if (is_write) begin
                        if (DATA_WIDTH == 8) begin
                            sm_pdi_wdata <= {24'h0, write_data[7:0]};
                        end else begin
                            sm_pdi_wdata <= {16'h0, write_data[15:0]};
                        end
                    end
                end

                // ------------------------------------------------------------
                WAIT_ACK: begin
                    // Hold request active
                    if (addr_space == ADDR_SPACE_REGS)
                        reg_req <= 1'b1;
                    else
                        sm_pdi_req <= 1'b1;

                    // Watchdog
                    watchdog_counter <= watchdog_counter + 1;
                    if (watchdog_counter >= WATCHDOG_TIMEOUT)
                        watchdog_expired <= 1'b1;

                    // Capture read data
                    if (reg_ack && is_read) begin
                        read_data_buf <= {16'h0000, reg_rdata};
                    end else if (sm_pdi_ack && is_read) begin
                        read_data_buf <= sm_pdi_rdata;
                    end
                end

                // ------------------------------------------------------------
                DONE: begin
                    mcu_wait_n <= 1'b1;

                    if (is_read && rd_active) begin
                        data_oe  <= 1'b1;
                        if (DATA_WIDTH == 8)
                            data_out <= read_data_buf[7:0];
                        else
                            data_out <= read_data_buf[15:0];
                    end
                end

                // ------------------------------------------------------------
                ERROR: begin
                    mcu_wait_n <= 1'b1;
                    pdi_operational <= 1'b0;
                end
            endcase

            // ----------------------------------------------------------------
            // Global watchdog
            // ----------------------------------------------------------------
            if (cs_active && (rd_falling || wr_falling)) begin
                global_watchdog <= '0;
                pdi_watchdog_timeout <= 1'b0;
            end else if (pdi_enable && global_watchdog < 20'd100000) begin
                global_watchdog <= global_watchdog + 1;
            end else if (global_watchdog >= 20'd100000) begin
                pdi_watchdog_timeout <= 1'b1;
            end
        end
    end

    // ========================================================================
    // Tri-state Data Bus
    // ========================================================================
    genvar i;
    generate
        for (i = 0; i < DATA_WIDTH; i = i + 1) begin : gen_data_tri
            assign mcu_data[i] = data_oe ? data_out[i] : 1'bz;
        end
    endgenerate

    // ========================================================================
    // IRQ Generation
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_latched <= '0;
        end else begin
            irq_latched <= irq_latched | irq_sources;
            if (reg_ack && is_read && reg_addr == 16'h0220)
                irq_latched <= '0;
        end
    end

    assign mcu_irq = |irq_latched;

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
