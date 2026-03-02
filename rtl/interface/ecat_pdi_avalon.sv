// ============================================================================
// EtherCAT PDI Interface - AVALON Bus
// Provides host CPU access to EtherCAT memory and registers
// P0 Critical Function (FPGA-friendly interface)
// ============================================================================

`include "ecat_pkg.vh"

module ecat_pdi_avalon #(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 32
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // AVALON Memory-Mapped Slave interface
    input  wire [ADDR_WIDTH-1:0]    avs_address,
    input  wire                     avs_read,
    output reg  [DATA_WIDTH-1:0]    avs_readdata,
    output reg                      avs_readdatavalid,
    input  wire                     avs_write,
    input  wire [DATA_WIDTH-1:0]    avs_writedata,
    input  wire [(DATA_WIDTH/8)-1:0] avs_byteenable,
    output reg                      avs_waitrequest,
    
    // ESC Register access
    output reg                      reg_req,
    output reg                      reg_wr,
    output reg  [15:0]              reg_addr,
    output reg  [15:0]              reg_wdata,
    output reg  [1:0]               reg_be,
    input  wire [15:0]              reg_rdata,
    input  wire                     reg_ack,
    
    // Process Data RAM access (through Sync Managers)
    output reg  [7:0]               sm_id,             // Which SM to access
    output reg                      sm_pdi_req,
    output reg                      sm_pdi_wr,
    output reg  [15:0]              sm_pdi_addr,
    output reg  [DATA_WIDTH-1:0]    sm_pdi_wdata,
    input  wire [DATA_WIDTH-1:0]    sm_pdi_rdata,
    input  wire                     sm_pdi_ack,
    
    // PDI Control
    input  wire                     pdi_enable,        // From AL state machine
    output reg                      pdi_operational,   // PDI is ready
    output reg                      pdi_watchdog_timeout,
    
    // IRQ to host
    output reg                      pdi_irq,
    input  wire [15:0]              irq_sources
);

    // ========================================================================
    // Address Space Mapping
    // ========================================================================
    // 0x0000-0x0FFF: ESC Registers (direct access)
    // 0x1000-0x1FFF: Process Data (via Sync Managers)
    // 0x2000-0x2FFF: Mailbox (via Sync Managers 0/1)
    
    localparam ADDR_SPACE_REGS = 2'b00;  // 0x0000-0x0FFF
    localparam ADDR_SPACE_PRAM = 2'b01;  // 0x1000-0x1FFF
    localparam ADDR_SPACE_MBOX = 2'b10;  // 0x2000-0x2FFF
    
    // ========================================================================
    // PDI Access State Machine
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
    // Internal Registers
    // ========================================================================
    reg [1:0]   addr_space;
    reg [15:0]  access_addr;
    reg [31:0]  write_data;
    reg [3:0]   byte_enable;
    reg         is_write;
    reg         is_read;
    
    // Watchdog timer (1ms timeout typical)
    reg [15:0]  watchdog_counter;
    reg         watchdog_expired;
    localparam  WATCHDOG_TIMEOUT = 16'd50000;  // Assuming 50MHz clock
    
    // IRQ management
    reg [15:0]  irq_latched;
    
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
                // BUGFIX: Allow register access even when PDI not enabled (for device discovery)
                // Only block SM/Process Data access when not enabled
                if (avs_read || avs_write) begin
                    if (addr_space == ADDR_SPACE_REGS) begin
                        // Register access always allowed for configuration
                        next_state = REG_ACCESS;
                    end else if (pdi_enable) begin
                        // Process data/mailbox only when PDI enabled
                        next_state = SM_ACCESS;
                    end else begin
                        // Block process data access when PDI disabled
                        next_state = ERROR;
                    end
                end
            end
            
            REG_ACCESS: begin
                next_state = WAIT_ACK;
            end
            
            SM_ACCESS: begin
                next_state = WAIT_ACK;
            end
            
            WAIT_ACK: begin
                if (reg_ack || sm_pdi_ack)
                    next_state = DONE;
                else if (watchdog_expired)
                    next_state = ERROR;
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            ERROR: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // ========================================================================
    // Address Decode and Control Logic
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avs_waitrequest <= 1'b0;
            avs_readdatavalid <= 1'b0;
            avs_readdata <= '0;
            reg_req <= 1'b0;
            reg_wr <= 1'b0;
            reg_addr <= '0;
            reg_wdata <= '0;
            reg_be <= '0;
            sm_pdi_req <= 1'b0;
            sm_pdi_wr <= 1'b0;
            sm_pdi_addr <= '0;
            sm_pdi_wdata <= '0;
            sm_id <= '0;
            addr_space <= '0;
            access_addr <= '0;
            write_data <= '0;
            byte_enable <= '0;
            is_write <= 1'b0;
            is_read <= 1'b0;
            watchdog_counter <= '0;
            watchdog_expired <= 1'b0;
            pdi_operational <= 1'b1;
        end else begin
            // Default values
            avs_readdatavalid <= 1'b0;
            reg_req <= 1'b0;
            sm_pdi_req <= 1'b0;
            watchdog_expired <= 1'b0;
            
            case (state)
                IDLE: begin
                    avs_waitrequest <= 1'b0;
                    watchdog_counter <= '0;
                    
                    if (avs_read || avs_write) begin
                        // Decode address space (bits 13:12 for 4KB regions)
                        // 0x0xxx = REGS, 0x1xxx = PRAM, 0x2xxx = MBOX
                        addr_space <= avs_address[13:12];
                        access_addr <= avs_address[15:0];
                        write_data <= avs_writedata;
                        byte_enable <= avs_byteenable;
                        is_write <= avs_write;
                        is_read <= avs_read;
                        avs_waitrequest <= 1'b1;
                    end
                end
                
                REG_ACCESS: begin
                    // Access ESC registers - setup request
                    reg_req <= 1'b1;
                    reg_wr <= is_write;
                    reg_addr <= access_addr[15:0];
                    
                    if (is_write) begin
                        // Convert 32-bit write to 16-bit writes
                        if (byte_enable[1:0] != 2'b00) begin
                            reg_wdata <= write_data[15:0];
                            reg_be <= byte_enable[1:0];
                        end else begin
                            reg_wdata <= write_data[31:16];
                            reg_be <= byte_enable[3:2];
                        end
                    end
                end
                
                SM_ACCESS: begin
                    // Access process data through Sync Managers
                    // Determine which SM based on address
                    if (addr_space == ADDR_SPACE_MBOX) begin
                        // Mailbox: SM0 (write) or SM1 (read)
                        sm_id <= is_write ? 8'h00 : 8'h01;
                    end else begin
                        // Process data: SM2 (outputs) or SM3 (inputs)
                        sm_id <= is_write ? 8'h02 : 8'h03;
                    end
                    
                    sm_pdi_req <= 1'b1;
                    sm_pdi_wr <= is_write;
                    sm_pdi_addr <= access_addr[15:0];
                    
                    if (is_write) begin
                        sm_pdi_wdata <= write_data;
                    end
                end
                
                WAIT_ACK: begin
                    // Keep request active until acknowledged
                    if (addr_space == ADDR_SPACE_REGS) begin
                        reg_req <= 1'b1;  // Hold reg_req until ack
                    end else begin
                        sm_pdi_req <= 1'b1;  // Hold sm_pdi_req until ack
                    end
                    
                    watchdog_counter <= watchdog_counter + 1;
                    
                    if (watchdog_counter >= WATCHDOG_TIMEOUT) begin
                        watchdog_expired <= 1'b1;
                    end
                    
                    if (reg_ack) begin
                        if (is_read) begin
                            avs_readdata <= {16'h0000, reg_rdata};
                        end
                    end else if (sm_pdi_ack) begin
                        if (is_read) begin
                            avs_readdata <= sm_pdi_rdata;
                        end
                    end
                end
                
                DONE: begin
                    avs_waitrequest <= 1'b0;
                    if (is_read) begin
                        avs_readdatavalid <= 1'b1;
                    end
                end
                
                ERROR: begin
                    avs_waitrequest <= 1'b0;
                    avs_readdatavalid <= 1'b0;
                    pdi_operational <= 1'b0;  // Signal error
                end
            endcase
        end
    end
    
    // ========================================================================
    // Watchdog Timer (for PDI communication timeout)
    // ========================================================================
    reg [19:0] global_watchdog;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_watchdog <= '0;
            pdi_watchdog_timeout <= 1'b0;
        end else begin
            if (avs_read || avs_write) begin
                global_watchdog <= '0;  // Reset on any access
                pdi_watchdog_timeout <= 1'b0;
            end else if (pdi_enable && global_watchdog < 20'd1000000) begin
                global_watchdog <= global_watchdog + 1;
            end else if (global_watchdog >= 20'd1000000) begin
                pdi_watchdog_timeout <= 1'b1;  // 20ms timeout
            end
        end
    end
    
    // ========================================================================
    // IRQ Generation
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_latched <= '0;
            pdi_irq <= 1'b0;
        end else begin
            // Latch interrupt sources
            irq_latched <= irq_latched | irq_sources;
            
            // Generate IRQ pulse
            pdi_irq <= |irq_latched;
            
            // Clear on read of IRQ register (address 0x0220)
            if (reg_ack && is_read && reg_addr == 16'h0220) begin
                irq_latched <= '0;
            end
        end
    end
    
    // ========================================================================
    // PDI Operational Status
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pdi_operational <= 1'b1;
        end else begin
            // PDI is operational if:
            // - No watchdog timeout
            // - Enabled by AL state machine
            // - Recent activity detected
            pdi_operational <= pdi_enable && !pdi_watchdog_timeout;
        end
    end

endmodule
