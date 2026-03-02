// ============================================================================
// EtherCAT Sync Manager (SM)
// Manages buffered access to process data RAM
// Implements 3-buffer mechanism for deterministic data exchange
// Complete implementation based on ETG.1000 specification
// ============================================================================

`include "ecat_pkg.vh"
`include "ecat_core_defines.vh"

module ecat_sync_manager #(
    parameter SM_ID = 0,                      // Sync Manager ID (0-7)
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 8
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    input  wire                     pdi_clk,          // PDI clock domain
    input  wire [255:0]             feature_vector,
    
    // Configuration interface (ESC registers)
    input  wire                     cfg_wr,
    input  wire [7:0]               cfg_addr,
    input  wire [15:0]              cfg_wdata,
    output reg  [15:0]              cfg_rdata,
    
    // EtherCAT side interface
    input  wire                     ecat_req,         // Request from EtherCAT
    input  wire                     ecat_wr,          // Write (1) or Read (0)
    input  wire [ADDR_WIDTH-1:0]    ecat_addr,        // Address
    input  wire [DATA_WIDTH-1:0]    ecat_wdata,       // Write data
    output reg                      ecat_ack,         // Acknowledge
    output reg  [DATA_WIDTH-1:0]    ecat_rdata,       // Read data
    
    // PDI side interface  
    input  wire                     pdi_req,          // Request from PDI
    input  wire                     pdi_wr,           // Write (1) or Read (0)
    input  wire [ADDR_WIDTH-1:0]    pdi_addr,         // Address
    input  wire [DATA_WIDTH-1:0]    pdi_wdata,        // Write data
    output reg                      pdi_ack,          // Acknowledge
    output reg  [DATA_WIDTH-1:0]    pdi_rdata,        // Read data
    
    // Memory interface (to dual-port RAM)
    output reg                      mem_req,
    output reg                      mem_wr,
    output reg  [ADDR_WIDTH-1:0]    mem_addr,
    output reg  [DATA_WIDTH-1:0]    mem_wdata,
    input  wire                     mem_ack,
    input  wire [DATA_WIDTH-1:0]    mem_rdata,
    
    // Status and events
    output reg                      sm_active,        // SM is active
    output reg                      sm_irq,           // Interrupt request
    output reg  [7:0]               sm_status         // Status register
);

    // ========================================================================
    // Sync Manager Register Map (per EtherCAT specification)
    // ========================================================================
    
    localparam REG_START_ADDR   = 8'h00;  // Physical start address [15:0]
    localparam REG_LENGTH       = 8'h02;  // Length [15:0]
    localparam REG_CONTROL      = 8'h04;  // Control register [7:0]
    localparam REG_STATUS       = 8'h05;  // Status register [7:0]
    localparam REG_ACTIVATE     = 8'h06;  // Activate [7:0]
    localparam REG_PDI_CONTROL  = 8'h07;  // PDI Control [7:0]
    
    // Control register bits
    localparam CTRL_MODE_BIT0   = 0;      // Operating mode bit 0
    localparam CTRL_MODE_BIT1   = 1;      // Operating mode bit 1
    localparam CTRL_DIRECTION   = 2;      // 0=Read (Master->Slave), 1=Write (Slave->Master)
    localparam CTRL_IRQ_ECAT    = 3;      // EtherCAT interrupt enable
    localparam CTRL_IRQ_PDI     = 4;      // PDI interrupt enable
    localparam CTRL_WATCHDOG    = 5;      // Watchdog trigger enable
    localparam CTRL_IRQ_WRITE   = 6;      // Write event interrupt
    localparam CTRL_IRQ_READ    = 7;      // Read event interrupt
    
    // Status register bits (ETG.1000 Section 6.7 compliant)
    localparam STAT_IRQ_WRITE      = 0;   // Write event occurred
    localparam STAT_IRQ_READ       = 1;   // Read event occurred
    localparam STAT_BUFFER_WRITTEN = 2;   // Buffered mode: at least 1 buffer written
    localparam STAT_MAILBOX_FULL   = 3;   // Mailbox mode: full / Buffered: buffer full
    localparam STAT_WATCHDOG       = 6;   // Watchdog expired
    localparam STAT_IRQ_PENDING    = 7;   // Interrupt pending
    
    // ========================================================================
    // Configuration Registers
    // ========================================================================
    
    reg [15:0]  start_addr;               // Physical start address in RAM
    reg [15:0]  length;                   // Buffer length
    reg [7:0]   control;                  // Control register
    reg [7:0]   status;                   // Status register
    reg         sm_enable;                // SM enabled
    reg [7:0]   pdi_control;              // PDI control
    
    // Decoded control fields
    wire [1:0]  op_mode;
    wire        direction;                // 0=read (ECAT writes), 1=write (PDI writes)
    wire        irq_ecat_en;
    wire        irq_pdi_en;
    wire        watchdog_en;
    
    assign op_mode = control[1:0];
    assign direction = control[CTRL_DIRECTION];
    assign irq_ecat_en = control[CTRL_IRQ_ECAT];
    assign irq_pdi_en = control[CTRL_IRQ_PDI];
    assign watchdog_en = control[CTRL_WATCHDOG];
    
    // Watchdog timer (SM-05: Watchdog functionality)
    reg [15:0]  watchdog_counter;
    reg [15:0]  watchdog_timeout;         // Configurable timeout value
    reg         watchdog_expired;
    reg         watchdog_reload;          // Reload signal from ECAT access
    
    // Operating modes
    localparam MODE_3BUFFER     = 2'b00;  // 3-buffer mode
    localparam MODE_MAILBOX     = 2'b10;  // Mailbox mode
    localparam MODE_RESERVED    = 2'b01;  // Reserved
    
    // ========================================================================
    // Buffer Management (3-Buffer Mechanism)
    // ========================================================================
    
    // Buffer indices
    reg [1:0]   ecat_buffer;              // Buffer currently used by EtherCAT
    reg [1:0]   pdi_buffer;               // Buffer currently used by PDI
    reg [1:0]   temp_buffer;              // Temporary/exchange buffer
    
    // Buffer status
    reg [2:0]   buffer_written;           // Buffer has been written
    reg [2:0]   buffer_read;              // Buffer has been read
    reg         buffer_swap_pending;       // Buffer swap needed
    
    // Mailbox mode specific signals
    reg         mailbox_full;              // Mailbox buffer contains unread data
    reg         write_in_progress;         // Multi-byte write in progress
    reg [15:0]  mailbox_write_count;       // Bytes written to current mailbox
    
    // Address calculation
    wire [ADDR_WIDTH-1:0] buffer_base [0:2];
    
    assign buffer_base[0] = start_addr;
    assign buffer_base[1] = start_addr + length;
    assign buffer_base[2] = start_addr + (length << 1);
    
    // ========================================================================
    // Configuration Register Access
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_addr <= 16'h0000;
            length <= 16'h0000;
            control <= 8'h00;
            status <= 8'h00;
            sm_enable <= 1'b0;
            pdi_control <= 8'h00;
            cfg_rdata <= 16'h0000;
        end else begin
            // Write access
            if (cfg_wr) begin
                case (cfg_addr)
                    REG_START_ADDR: start_addr <= cfg_wdata;
                    REG_LENGTH: length <= cfg_wdata;
                    REG_CONTROL: control <= cfg_wdata[7:0];
                    REG_STATUS: begin
                        // Writing 1 clears status bits
                        if (cfg_wdata[STAT_IRQ_WRITE])
                            status[STAT_IRQ_WRITE] <= 1'b0;
                        if (cfg_wdata[STAT_IRQ_READ])
                            status[STAT_IRQ_READ] <= 1'b0;
                    end
                    REG_ACTIVATE: sm_enable <= (cfg_wdata[0] == 1'b1);
                    REG_PDI_CONTROL: pdi_control <= cfg_wdata[7:0];
                    default: ;
                endcase
            end
            
            // Read access
            case (cfg_addr)
                REG_START_ADDR: cfg_rdata <= start_addr;
                REG_LENGTH: cfg_rdata <= length;
                REG_CONTROL: cfg_rdata <= {8'h00, control};
                REG_STATUS: cfg_rdata <= {8'h00, status};
                REG_ACTIVATE: cfg_rdata <= {15'h0000, sm_enable};
                REG_PDI_CONTROL: cfg_rdata <= {8'h00, pdi_control};
                default: cfg_rdata <= 16'h0000;
            endcase
        end
    end
    
    // ========================================================================
    // Watchdog Timer (SM-05)
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            watchdog_counter <= 16'hFFFF;
            watchdog_timeout <= 16'h1000;  // Default timeout
            watchdog_expired <= 1'b0;
            watchdog_reload <= 1'b0;
        end else begin
            watchdog_reload <= 1'b0;
            
            if (!sm_enable || !watchdog_en) begin
                // Watchdog disabled - reset
                watchdog_counter <= watchdog_timeout;
                watchdog_expired <= 1'b0;
            end else if (watchdog_reload) begin
                // Reload on ECAT access
                watchdog_counter <= watchdog_timeout;
                watchdog_expired <= 1'b0;
                status[STAT_WATCHDOG] <= 1'b0;
            end else if (watchdog_counter > 0) begin
                // Count down
                watchdog_counter <= watchdog_counter - 1'b1;
            end else if (!watchdog_expired) begin
                // Watchdog expired!
                watchdog_expired <= 1'b1;
                status[STAT_WATCHDOG] <= 1'b1;
                // Generate interrupt to PDI
                if (irq_pdi_en)
                    sm_irq <= 1'b1;
            end
        end
    end
    
    // ========================================================================
    // Buffer State Machine
    // ========================================================================
    
    typedef enum logic [2:0] {
        SM_IDLE,
        SM_ECAT_ACCESS,
        SM_PDI_ACCESS,
        SM_CHECK_ADDR,
        SM_SWAP_BUFFERS,
        SM_MEM_ACCESS,
        SM_COMPLETE
    } sm_state_t;
    
    sm_state_t state, next_state;
    
    // Current access info
    reg         current_wr;
    reg [ADDR_WIDTH-1:0] current_addr;
    reg [DATA_WIDTH-1:0] current_wdata;
    reg         current_is_ecat;
    
    // State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= SM_IDLE;
        else
            state <= next_state;
    end
    
    // Next state logic
    always_comb begin
        next_state = state;
        
        case (state)
            SM_IDLE: begin
                if (sm_enable) begin
                    if (ecat_req) begin
                        // In mailbox mode, block ECAT writes if mailbox is full
                        if (op_mode == MODE_MAILBOX && mailbox_full && ecat_wr && direction == 1'b0)
                            next_state = SM_IDLE;  // Reject - mailbox full
                        else
                            next_state = SM_ECAT_ACCESS;
                    end else if (pdi_req) begin
                        next_state = SM_PDI_ACCESS;
                    end
                end
            end
            
            SM_ECAT_ACCESS,
            SM_PDI_ACCESS: begin
                // Capture address in this cycle, check in next
                next_state = SM_CHECK_ADDR;
            end
            
            SM_CHECK_ADDR: begin
                // Check if address is within SM range
                if (current_addr >= start_addr && 
                    current_addr < (start_addr + length * 3)) begin
                    next_state = SM_MEM_ACCESS;
                end else begin
                    next_state = SM_COMPLETE;  // Out of range
                end
            end
            
            SM_MEM_ACCESS: begin
                if (mem_ack)
                    next_state = SM_COMPLETE;
            end
            
            SM_COMPLETE: begin
                // Only swap buffers in 3-buffer mode, not in mailbox mode
                if (buffer_swap_pending && op_mode != MODE_MAILBOX)
                    next_state = SM_SWAP_BUFFERS;
                else
                    next_state = SM_IDLE;
            end
            
            SM_SWAP_BUFFERS: begin
                next_state = SM_IDLE;
            end
            
            default: next_state = SM_IDLE;
        endcase
    end
    
    // Output and buffer management logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ecat_ack <= 1'b0;
            ecat_rdata <= '0;
            pdi_ack <= 1'b0;
            pdi_rdata <= '0;
            mem_req <= 1'b0;
            mem_wr <= 1'b0;
            mem_addr <= '0;
            mem_wdata <= '0;
            sm_active <= 1'b0;
            sm_irq <= 1'b0;
            ecat_buffer <= 2'd0;
            pdi_buffer <= 2'd1;
            temp_buffer <= 2'd2;
            buffer_written <= 3'b000;
            buffer_read <= 3'b000;
            buffer_swap_pending <= 1'b0;
            mailbox_full <= 1'b0;
            write_in_progress <= 1'b0;
            mailbox_write_count <= 16'h0000;
            current_wr <= 1'b0;
            current_addr <= '0;
            current_wdata <= '0;
            current_is_ecat <= 1'b0;
        end else begin
            case (state)
                SM_IDLE: begin
                    ecat_ack <= 1'b0;
                    pdi_ack <= 1'b0;
                    mem_req <= 1'b0;
                    sm_active <= 1'b0;
                end
                
                SM_ECAT_ACCESS: begin
                    sm_active <= 1'b1;
                    current_wr <= ecat_wr;
                    current_addr <= ecat_addr;
                    current_wdata <= ecat_wdata;
                    current_is_ecat <= 1'b1;
                end
                
                SM_PDI_ACCESS: begin
                    sm_active <= 1'b1;
                    current_wr <= pdi_wr;
                    current_addr <= pdi_addr;
                    current_wdata <= pdi_wdata;
                    current_is_ecat <= 1'b0;
                end
                
                SM_CHECK_ADDR: begin
                    // Address captured, wait for range check in next_state logic
                end
                
                SM_MEM_ACCESS: begin
                    // Calculate actual memory address based on operating mode
                    if (op_mode == MODE_MAILBOX) begin
                        // Mailbox mode: always use single buffer at start_addr
                        mem_addr <= start_addr + (current_addr - start_addr);
                    end else begin
                        // 3-buffer mode: use rotating buffer indices
                        if (current_is_ecat) begin
                            mem_addr <= buffer_base[ecat_buffer] + 
                                       (current_addr - start_addr);
                        end else begin
                            mem_addr <= buffer_base[pdi_buffer] + 
                                       (current_addr - start_addr);
                        end
                    end
                    
                    mem_wr <= current_wr;
                    mem_wdata <= current_wdata;
                    mem_req <= 1'b1;
                    
                    if (mem_ack) begin
                        if (current_is_ecat) begin
                            ecat_rdata <= mem_rdata;
                            if (current_wr) begin
                                buffer_written[ecat_buffer] <= 1'b1;
                                // Track mailbox write progress
                                if (op_mode == MODE_MAILBOX) begin
                                    write_in_progress <= 1'b1;
                                    mailbox_write_count <= mailbox_write_count + 1;
                                end
                            end else begin
                                buffer_read[ecat_buffer] <= 1'b1;
                            end
                        end else begin
                            pdi_rdata <= mem_rdata;
                            if (current_wr) begin
                                buffer_written[pdi_buffer] <= 1'b1;
                                // Track mailbox write progress
                                if (op_mode == MODE_MAILBOX) begin
                                    write_in_progress <= 1'b1;
                                    mailbox_write_count <= mailbox_write_count + 1;
                                end
                            end else begin
                                buffer_read[pdi_buffer] <= 1'b1;
                            end
                        end
                    end
                end
                
                SM_COMPLETE: begin
                    mem_req <= 1'b0;
                    
                    if (op_mode == MODE_MAILBOX) begin
                        // === MAILBOX MODE ===
                        if (current_is_ecat) begin
                            ecat_ack <= 1'b1;
                            watchdog_reload <= 1'b1;  // Reload watchdog on ECAT access
                            // EtherCAT side write completes mailbox (direction=0: ECAT writes)
                            if (current_wr && direction == 1'b0) begin
                                mailbox_full <= 1'b1;
                                write_in_progress <= 1'b0;
                                status[STAT_MAILBOX_FULL] <= 1'b1;
                                status[STAT_IRQ_WRITE] <= 1'b1;
                                if (irq_pdi_en)
                                    sm_irq <= 1'b1;  // Notify PDI side
                            end
                            // EtherCAT side read clears mailbox (direction=1: PDI writes)
                            if (!current_wr && direction == 1'b1 && mailbox_full) begin
                                mailbox_full <= 1'b0;
                                mailbox_write_count <= 16'h0000;
                                status[STAT_MAILBOX_FULL] <= 1'b0;
                                status[STAT_IRQ_READ] <= 1'b1;
                                if (irq_ecat_en)
                                    sm_irq <= 1'b1;
                            end
                        end else begin
                            pdi_ack <= 1'b1;
                            // PDI side write completes mailbox (direction=1: PDI writes)
                            if (current_wr && direction == 1'b1) begin
                                mailbox_full <= 1'b1;
                                write_in_progress <= 1'b0;
                                status[STAT_MAILBOX_FULL] <= 1'b1;
                                status[STAT_IRQ_WRITE] <= 1'b1;
                                if (irq_ecat_en)
                                    sm_irq <= 1'b1;  // Notify EtherCAT side
                            end
                            // PDI side read clears mailbox (direction=0: ECAT writes)
                            if (!current_wr && direction == 1'b0 && mailbox_full) begin
                                mailbox_full <= 1'b0;
                                mailbox_write_count <= 16'h0000;
                                status[STAT_MAILBOX_FULL] <= 1'b0;
                                status[STAT_IRQ_READ] <= 1'b1;
                                if (irq_pdi_en)
                                    sm_irq <= 1'b1;
                            end
                        end
                    end else begin
                        // === 3-BUFFER MODE ===
                        if (current_is_ecat) begin
                            ecat_ack <= 1'b1;
                            watchdog_reload <= 1'b1;  // Reload watchdog on ECAT access
                            // Check if buffer is complete and should be swapped
                            if (buffer_written[ecat_buffer] && direction == 1'b0) begin
                                buffer_swap_pending <= 1'b1;
                                status[STAT_IRQ_WRITE] <= 1'b1;
                                status[STAT_BUFFER_WRITTEN] <= 1'b1;
                                if (irq_ecat_en)
                                    sm_irq <= 1'b1;
                            end
                        end else begin
                            pdi_ack <= 1'b1;
                            // Check if buffer is complete and should be swapped
                            if (buffer_written[pdi_buffer] && direction == 1'b1) begin
                                buffer_swap_pending <= 1'b1;
                                status[STAT_IRQ_WRITE] <= 1'b1;
                                status[STAT_BUFFER_WRITTEN] <= 1'b1;
                                if (irq_pdi_en)
                                    sm_irq <= 1'b1;
                            end
                        end
                    end
                end
                
                SM_SWAP_BUFFERS: begin
                    // Swap buffers: exchange temp buffer with the buffer that was written
                    if (direction == 1'b0) begin  // Read mode: ECAT writes
                        temp_buffer <= ecat_buffer;
                        ecat_buffer <= temp_buffer;
                        buffer_written[ecat_buffer] <= 1'b0;
                    end else begin  // Write mode: PDI writes
                        temp_buffer <= pdi_buffer;
                        pdi_buffer <= temp_buffer;
                        buffer_written[pdi_buffer] <= 1'b0;
                    end
                    buffer_swap_pending <= 1'b0;
                end
                
                default: ;
            endcase
        end
    end
    
    // Status output
    always_comb begin
        sm_status = status;
    end

endmodule

// ============================================================================
// Sync Manager Array - Multiple SMs
// ============================================================================

module ecat_sync_manager_array #(
    parameter NUM_SM = 8,
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 8
)(
    input  wire                     rst_n,
    input  wire                     clk,
    input  wire                     pdi_clk,
    input  wire [255:0]             feature_vector,
    
    // Configuration interface
    input  wire                     cfg_wr,
    input  wire [3:0]               cfg_sm_sel,       // SM select (0-7)
    input  wire [7:0]               cfg_addr,
    input  wire [15:0]              cfg_wdata,
    output reg  [15:0]              cfg_rdata,
    
    // EtherCAT interface
    input  wire                     ecat_req,
    input  wire                     ecat_wr,
    input  wire [ADDR_WIDTH-1:0]    ecat_addr,
    input  wire [DATA_WIDTH-1:0]    ecat_wdata,
    output wire                     ecat_ack,
    output reg  [DATA_WIDTH-1:0]    ecat_rdata,
    
    // PDI interface
    input  wire                     pdi_req,
    input  wire                     pdi_wr,
    input  wire [ADDR_WIDTH-1:0]    pdi_addr,
    input  wire [DATA_WIDTH-1:0]    pdi_wdata,
    input  wire [2:0]               pdi_sm_sel,
    output wire                     pdi_ack,
    output reg  [DATA_WIDTH-1:0]    pdi_rdata,
    
    // Memory interface
    output wire                     mem_req,
    output wire                     mem_wr,
    output wire [ADDR_WIDTH-1:0]    mem_addr,
    output wire [DATA_WIDTH-1:0]    mem_wdata,
    input  wire                     mem_ack,
    input  wire [DATA_WIDTH-1:0]    mem_rdata,
    
    // Interrupt outputs
    output wire [NUM_SM-1:0]        sm_irq,
    output wire [NUM_SM*8-1:0]      sm_status_packed,
    output wire [NUM_SM-1:0]        sm_active_bits,
    input  wire [2:0]               ecat_sm_sel
);

    // SM instance signals
    wire [NUM_SM-1:0] sm_ecat_ack;
    wire [NUM_SM-1:0] sm_pdi_ack;
    wire [NUM_SM-1:0] sm_mem_req;
    wire [NUM_SM-1:0] sm_mem_wr;
    wire [NUM_SM-1:0] sm_active;
    wire [ADDR_WIDTH-1:0] sm_mem_addr [NUM_SM-1:0];
    wire [DATA_WIDTH-1:0] sm_mem_wdata [NUM_SM-1:0];
    wire [DATA_WIDTH-1:0] sm_ecat_rdata [NUM_SM-1:0];
    wire [DATA_WIDTH-1:0] sm_pdi_rdata [NUM_SM-1:0];
    wire [15:0] sm_cfg_rdata [NUM_SM-1:0];
    wire [7:0] sm_status [NUM_SM-1:0];
    
    // Determine which SM should handle the request
    reg [3:0] active_sm_ecat, active_sm_pdi, active_sm_mem;
    
    // Generate SM instances
    generate
        for (genvar i = 0; i < NUM_SM; i++) begin : gen_sm
            ecat_sync_manager #(
                .SM_ID(i),
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH)
            ) sm_inst (
                .rst_n(rst_n),
                .clk(clk),
                .pdi_clk(pdi_clk),
                .feature_vector(feature_vector),
                .cfg_wr(cfg_wr && (cfg_sm_sel == i)),
                .cfg_addr(cfg_addr),
                .cfg_wdata(cfg_wdata),
                .cfg_rdata(sm_cfg_rdata[i]),
                .ecat_req(ecat_req && (active_sm_ecat == i)),
                .ecat_wr(ecat_wr),
                .ecat_addr(ecat_addr),
                .ecat_wdata(ecat_wdata),
                .ecat_ack(sm_ecat_ack[i]),
                .ecat_rdata(sm_ecat_rdata[i]),
                .pdi_req(pdi_req && (active_sm_pdi == i)),
                .pdi_wr(pdi_wr),
                .pdi_addr(pdi_addr),
                .pdi_wdata(pdi_wdata),
                .pdi_ack(sm_pdi_ack[i]),
                .pdi_rdata(sm_pdi_rdata[i]),
                .mem_req(sm_mem_req[i]),
                .mem_wr(sm_mem_wr[i]),
                .mem_addr(sm_mem_addr[i]),
                .mem_wdata(sm_mem_wdata[i]),
                .mem_ack(mem_ack && (active_sm_mem == i)),
                .mem_rdata(mem_rdata),
                .sm_active(sm_active[i]),
                .sm_irq(sm_irq[i]),
                .sm_status(sm_status[i])
            );
        end
    endgenerate
    
    // SM selection logic (priority-based)
    always_comb begin
        active_sm_ecat = ecat_sm_sel;
        active_sm_pdi = pdi_sm_sel;
    end

    // Memory port arbitration (first SM with mem_req)
    reg found_active;
    always_comb begin
        active_sm_mem = 0;
        found_active = 1'b0;
        for (int i = 0; i < NUM_SM; i++) begin
            if (sm_mem_req[i] && !found_active) begin
                active_sm_mem = i;
                found_active = 1'b1;
            end
        end
    end
    
    // Output aggregation
    assign ecat_ack = |sm_ecat_ack;
    assign pdi_ack = |sm_pdi_ack;
    assign mem_req = |sm_mem_req;
    
    always_comb begin
        if (active_sm_mem < NUM_SM) begin
            mem_wr = sm_mem_wr[active_sm_mem];
            mem_addr = sm_mem_addr[active_sm_mem];
            mem_wdata = sm_mem_wdata[active_sm_mem];
        end else begin
            mem_wr = 1'b0;
            mem_addr = '0;
            mem_wdata = '0;
        end
        
        // Data output multiplexing
        ecat_rdata = '0;
        pdi_rdata = '0;
        for (int i = 0; i < NUM_SM; i++) begin
            if (sm_ecat_ack[i])
                ecat_rdata = sm_ecat_rdata[i];
            if (sm_pdi_ack[i])
                pdi_rdata = sm_pdi_rdata[i];
        end
        
        cfg_rdata = sm_cfg_rdata[cfg_sm_sel];
    end

    // Status packing
    generate
        for (genvar s = 0; s < NUM_SM; s++) begin : gen_sm_status
            assign sm_status_packed[s*8 +: 8] = sm_status[s];
            assign sm_active_bits[s] = sm_active[s];
        end
    endgenerate

endmodule
