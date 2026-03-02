// ============================================================================
// EtherCAT FMMU (Field bus Memory Management Unit)
// Provides address translation between logical and physical address spaces
// Complete implementation based on VHDL original
// ============================================================================

`include "ecat_pkg.vh"
`include "ecat_core_defines.vh"

module ecat_fmmu #(
    parameter FMMU_ID = 0,                    // FMMU instance ID (0-7)
    parameter ADDR_WIDTH = 16,                // Physical address width
    parameter DATA_WIDTH = 32                 // Data width
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    input  wire                     cfg_clk,          // Configuration clock
    input  wire [255:0]             feature_vector,
    
    // Configuration interface (from ESC registers)
    input  wire                     cfg_wr,
    input  wire [7:0]               cfg_addr,
    input  wire [DATA_WIDTH-1:0]    cfg_wdata,
    output reg  [DATA_WIDTH-1:0]    cfg_rdata,
    
    // Logical address input (from EtherCAT frame)
    input  wire                     log_req,          // Logical address request
    input  wire [31:0]              log_addr,         // Logical address
    input  wire [15:0]              log_len,          // Transfer length
    input  wire                     log_wr,           // Write enable
    input  wire [DATA_WIDTH-1:0]    log_wdata,        // Write data
    output reg                      log_ack,          // Acknowledge
    output reg  [DATA_WIDTH-1:0]    log_rdata,        // Read data
    output reg                      log_err,          // Error
    
    // Physical address output (to process RAM)
    output reg                      phy_req,          // Physical request
    output reg  [ADDR_WIDTH-1:0]    phy_addr,         // Physical address
    output reg                      phy_wr,           // Write enable
    output reg  [DATA_WIDTH-1:0]    phy_wdata,        // Write data
    input  wire                     phy_ack,          // Acknowledge
    input  wire [DATA_WIDTH-1:0]    phy_rdata,        // Read data
    
    // Status outputs
    output reg                      fmmu_active,      // FMMU is active
    output reg                      fmmu_error,       // FMMU error
    output reg  [7:0]               fmmu_error_code   // Detailed error code (ETG.1000)
    // Error code bits:
    //   [0] = Logical address out of range
    //   [1] = Physical address out of range
    //   [2] = Length error (access exceeds FMMU length)
    //   [3] = Bit alignment error
    //   [4] = Type mismatch (read/write permission)
    //   [5] = FMMU not enabled
    //   [6] = Reserved
    //   [7] = Reserved
);

    // ========================================================================
    // FMMU Configuration Registers (per EtherCAT specification)
    // ========================================================================
    
    // Register offsets (relative to FMMU base)
    localparam REG_LOG_START_ADDR   = 8'h00;  // Logical start address [31:0]
    localparam REG_LENGTH           = 8'h04;  // Length [15:0]
    localparam REG_LOG_START_BIT    = 8'h06;  // Logical start bit [2:0]
    localparam REG_LOG_STOP_BIT     = 8'h07;  // Logical stop bit [2:0]
    localparam REG_PHY_START_ADDR   = 8'h08;  // Physical start address [15:0]
    localparam REG_PHY_START_BIT    = 8'h0A;  // Physical start bit [2:0]
    localparam REG_TYPE             = 8'h0B;  // Type (read=01, write=02, readwrite=03)
    localparam REG_ACTIVATE         = 8'h0C;  // Activate (01=active)
    localparam REG_STATUS           = 8'h0D;  // Status (reserved)
    
    // Configuration registers
    reg [31:0]  log_start_addr;               // Logical start address
    reg [15:0]  length;                       // FMMU length
    reg [2:0]   log_start_bit;                // Logical start bit
    reg [2:0]   log_stop_bit;                 // Logical end bit
    reg [15:0]  phy_start_addr;               // Physical start address
    reg [2:0]   phy_start_bit;                // Physical start bit
    reg [1:0]   fmmu_type;                    // 00=unused, 01=read, 10=write, 11=readwrite
    reg         fmmu_enable;                  // FMMU enabled
    
    // ========================================================================
    // Address Translation Logic
    // ========================================================================
    
    // Address hit detection
    wire addr_hit;
    wire [31:0] log_end_addr;
    wire [31:0] offset_addr;
    wire [15:0] translated_addr;
    
    assign log_end_addr = log_start_addr + {16'h0000, length};
    assign addr_hit = fmmu_enable && 
                     (log_addr >= log_start_addr) && 
                     (log_addr < log_end_addr);
    
    // Calculate offset and translate
    assign offset_addr = log_addr - log_start_addr;
    assign translated_addr = phy_start_addr + offset_addr[15:0];
    
    // ========================================================================
    // Bit-Level Mapping (FMMU-02: Bit-wise masking)
    // ========================================================================
    
    // Generate bit mask based on start/stop bits
    // Mask defines which bits are valid for this FMMU
    wire [7:0] bit_mask;
    reg [DATA_WIDTH-1:0] masked_wdata;
    reg [DATA_WIDTH-1:0] masked_rdata;
    
    // Calculate mask: bits from log_start_bit to log_stop_bit are valid
    assign bit_mask = ((8'hFF >> (7 - log_stop_bit)) & (8'hFF << log_start_bit));
    
    // Apply bit shifting for physical alignment
    // Logical bit position maps to physical bit position
    wire [2:0] bit_shift = (phy_start_bit >= log_start_bit) ? 
                           (phy_start_bit - log_start_bit) :
                           (log_start_bit - phy_start_bit);
    wire shift_left = (phy_start_bit >= log_start_bit);
    
    // ========================================================================
    // Configuration Register Access
    // ========================================================================
    
    always_ff @(posedge cfg_clk or negedge rst_n) begin
        if (!rst_n) begin
            log_start_addr <= 32'h0000_0000;
            length <= 16'h0000;
            log_start_bit <= 3'b000;
            log_stop_bit <= 3'b111;
            phy_start_addr <= 16'h0000;
            phy_start_bit <= 3'b000;
            fmmu_type <= 2'b00;
            fmmu_enable <= 1'b0;
            cfg_rdata <= '0;
        end else begin
            // Write access
            if (cfg_wr) begin
                case (cfg_addr)
                    REG_LOG_START_ADDR: log_start_addr <= cfg_wdata;
                    REG_LENGTH: length <= cfg_wdata[15:0];
                    REG_LOG_START_BIT: log_start_bit <= cfg_wdata[2:0];
                    REG_LOG_STOP_BIT: log_stop_bit <= cfg_wdata[2:0];
                    REG_PHY_START_ADDR: phy_start_addr <= cfg_wdata[15:0];
                    REG_PHY_START_BIT: phy_start_bit <= cfg_wdata[2:0];
                    REG_TYPE: fmmu_type <= cfg_wdata[1:0];
                    REG_ACTIVATE: fmmu_enable <= (cfg_wdata[0] == 1'b1);
                    default: ;
                endcase
            end
            
            // Read access
            case (cfg_addr)
                REG_LOG_START_ADDR: cfg_rdata <= log_start_addr;
                REG_LENGTH: cfg_rdata <= {16'h0000, length};
                REG_LOG_START_BIT: cfg_rdata <= {29'h0, log_start_bit};
                REG_LOG_STOP_BIT: cfg_rdata <= {29'h0, log_stop_bit};
                REG_PHY_START_ADDR: cfg_rdata <= {16'h0000, phy_start_addr};
                REG_PHY_START_BIT: cfg_rdata <= {29'h0, phy_start_bit};
                REG_TYPE: cfg_rdata <= {30'h0, fmmu_type};
                REG_ACTIVATE: cfg_rdata <= {31'h0, fmmu_enable};
                REG_STATUS: cfg_rdata <= {31'h0, fmmu_active};
                default: cfg_rdata <= 32'h0000_0000;
            endcase
        end
    end
    
    // ========================================================================
    // Address Translation State Machine
    // ========================================================================
    
    typedef enum logic [2:0] {
        IDLE,
        CHECK_ACCESS,
        TRANSLATE,
        PHY_REQUEST,
        PHY_WAIT,
        COMPLETE,
        ERROR
    } fmmu_state_t;
    
    fmmu_state_t state, next_state;
    
    // State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end
    
    // Next state logic
    always_comb begin
        next_state = state;
        
        case (state)
            IDLE: begin
                if (log_req && fmmu_enable)
                    next_state = CHECK_ACCESS;
            end
            
            CHECK_ACCESS: begin
                if (addr_hit) begin
                    // Check if access type is allowed
                    if ((log_wr && fmmu_type[1]) || (!log_wr && fmmu_type[0]))
                        next_state = TRANSLATE;
                    else
                        next_state = ERROR;
                end else begin
                    next_state = IDLE;  // No hit, ignore
                end
            end
            
            TRANSLATE: begin
                next_state = PHY_REQUEST;
            end
            
            PHY_REQUEST: begin
                next_state = PHY_WAIT;
            end
            
            PHY_WAIT: begin
                if (phy_ack)
                    next_state = COMPLETE;
            end
            
            COMPLETE: begin
                next_state = IDLE;
            end
            
            ERROR: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Output logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phy_req <= 1'b0;
            phy_addr <= '0;
            phy_wr <= 1'b0;
            phy_wdata <= '0;
            log_ack <= 1'b0;
            log_rdata <= '0;
            log_err <= 1'b0;
            fmmu_active <= 1'b0;
            fmmu_error <= 1'b0;
            fmmu_error_code <= 8'h00;
        end else begin
            case (state)
                IDLE: begin
                    phy_req <= 1'b0;
                    log_ack <= 1'b0;
                    log_err <= 1'b0;
                    fmmu_active <= 1'b0;
                    // Don't clear error code here - keep it latched for diagnostic read
                end
                
                CHECK_ACCESS: begin
                    fmmu_active <= 1'b1;
                    // Clear previous error on new access attempt
                    fmmu_error <= 1'b0;
                    fmmu_error_code <= 8'h00;
                end
                
                TRANSLATE: begin
                    phy_addr <= translated_addr[ADDR_WIDTH-1:0];
                    phy_wr <= log_wr;
                    // Apply bit mask for write operations
                    // Only modify bits within the mask range
                    if (log_wr) begin
                        // Shift and mask logical data to physical position
                        if (shift_left)
                            phy_wdata <= (log_wdata << bit_shift) & {24'h0, bit_mask};
                        else
                            phy_wdata <= (log_wdata >> bit_shift) & {24'h0, bit_mask};
                    end else begin
                        phy_wdata <= log_wdata;
                    end
                    
                    // Check for physical address overflow
                    if (translated_addr[ADDR_WIDTH-1:0] != translated_addr[15:0]) begin
                        // Physical address truncated - overflow error
                        fmmu_error_code[1] <= 1'b1;  // Physical address out of range
                    end
                end
                
                PHY_REQUEST: begin
                    phy_req <= 1'b1;
                end
                
                PHY_WAIT: begin
                    if (phy_ack) begin
                        if (!log_wr)
                            log_rdata <= phy_rdata;
                    end
                end
                
                COMPLETE: begin
                    phy_req <= 1'b0;
                    log_ack <= 1'b1;
                    fmmu_active <= 1'b0;
                end
                
                ERROR: begin
                    phy_req <= 1'b0;
                    log_ack <= 1'b0;
                    log_err <= 1'b1;
                    fmmu_error <= 1'b1;
                    fmmu_active <= 1'b0;
                    
                    // Set specific error code bits based on error type
                    // Check type mismatch (read/write permission denied)
                    if (addr_hit) begin
                        if (log_wr && !fmmu_type[1])
                            fmmu_error_code[4] <= 1'b1;  // Write not allowed
                        else if (!log_wr && !fmmu_type[0])
                            fmmu_error_code[4] <= 1'b1;  // Read not allowed
                    end else begin
                        fmmu_error_code[0] <= 1'b1;  // Logical address out of range
                    end
                end
                
                default: ;
            endcase
        end
    end
    
endmodule

// ============================================================================
// FMMU Array - Multiple FMMUs with priority arbitration
// ============================================================================

module ecat_fmmu_array #(
    parameter NUM_FMMU = 8,
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 32
)(
    input  wire                     rst_n,
    input  wire                     clk,
    input  wire                     cfg_clk,
    input  wire [255:0]             feature_vector,
    
    // Configuration interface
    input  wire                     cfg_wr,
    input  wire [7:0]               cfg_fmmu_sel,     // FMMU select (0-7)
    input  wire [7:0]               cfg_addr,
    input  wire [DATA_WIDTH-1:0]    cfg_wdata,
    output reg  [DATA_WIDTH-1:0]    cfg_rdata,
    
    // Logical address interface
    input  wire                     log_req,
    input  wire [31:0]              log_addr,
    input  wire [15:0]              log_len,
    input  wire                     log_wr,
    input  wire [DATA_WIDTH-1:0]    log_wdata,
    output wire                     log_ack,
    output reg  [DATA_WIDTH-1:0]    log_rdata,
    output wire                     log_err,
    
    // Physical address interface
    output wire                     phy_req,
    output wire [ADDR_WIDTH-1:0]    phy_addr,
    output wire                     phy_wr,
    output wire [DATA_WIDTH-1:0]    phy_wdata,
    input  wire                     phy_ack,
    input  wire [DATA_WIDTH-1:0]    phy_rdata,
    
    // FMMU Error outputs (for register 0x0F00-0x0F07)
    output wire [NUM_FMMU*8-1:0]    fmmu_error_codes  // 8 bytes, one per FMMU
);

    // FMMU instances
    wire [NUM_FMMU-1:0] fmmu_log_ack;
    wire [NUM_FMMU-1:0] fmmu_log_err;
    wire [NUM_FMMU-1:0] fmmu_phy_req;
    wire [NUM_FMMU-1:0] fmmu_active;
    wire [NUM_FMMU-1:0] fmmu_error;
    wire [7:0]          fmmu_error_code [NUM_FMMU-1:0];
    wire [ADDR_WIDTH-1:0] fmmu_phy_addr [NUM_FMMU-1:0];
    wire [NUM_FMMU-1:0] fmmu_phy_wr;
    wire [DATA_WIDTH-1:0] fmmu_phy_wdata [NUM_FMMU-1:0];
    wire [DATA_WIDTH-1:0] fmmu_log_rdata [NUM_FMMU-1:0];
    wire [DATA_WIDTH-1:0] fmmu_cfg_rdata [NUM_FMMU-1:0];
    
    // Generate FMMU instances
    generate
        for (genvar i = 0; i < NUM_FMMU; i++) begin : gen_fmmu
            ecat_fmmu #(
                .FMMU_ID(i),
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH)
            ) fmmu_inst (
                .rst_n(rst_n),
                .clk(clk),
                .cfg_clk(cfg_clk),
                .feature_vector(feature_vector),
                .cfg_wr(cfg_wr && (cfg_fmmu_sel == i)),
                .cfg_addr(cfg_addr),
                .cfg_wdata(cfg_wdata),
                .cfg_rdata(fmmu_cfg_rdata[i]),
                .log_req(log_req),
                .log_addr(log_addr),
                .log_len(log_len),
                .log_wr(log_wr),
                .log_wdata(log_wdata),
                .log_ack(fmmu_log_ack[i]),
                .log_rdata(fmmu_log_rdata[i]),
                .log_err(fmmu_log_err[i]),
                .phy_req(fmmu_phy_req[i]),
                .phy_addr(fmmu_phy_addr[i]),
                .phy_wr(fmmu_phy_wr[i]),
                .phy_wdata(fmmu_phy_wdata[i]),
                .phy_ack(phy_ack && fmmu_active[i]),
                .phy_rdata(phy_rdata),
                .fmmu_active(fmmu_active[i]),
                .fmmu_error(fmmu_error[i]),
                .fmmu_error_code(fmmu_error_code[i])
            );
            
            // Pack error codes for output
            assign fmmu_error_codes[i*8 +: 8] = fmmu_error_code[i];
        end
    endgenerate
    
    // Priority arbiter (FMMU 0 has highest priority)
    integer active_fmmu;
    
    always_comb begin
        active_fmmu = -1;
        for (int i = 0; i < NUM_FMMU; i++) begin
            if (fmmu_active[i] && active_fmmu < 0) begin
                active_fmmu = i;  // First active wins
            end
        end
    end
    
    // Output multiplexing
    assign log_ack = |fmmu_log_ack;
    assign log_err = |fmmu_log_err;
    assign phy_req = |fmmu_phy_req;
    
    always_comb begin
        if (active_fmmu >= 0) begin
            phy_addr = fmmu_phy_addr[active_fmmu];
            phy_wr = fmmu_phy_wr[active_fmmu];
            phy_wdata = fmmu_phy_wdata[active_fmmu];
            log_rdata = fmmu_log_rdata[active_fmmu];
        end else begin
            phy_addr = '0;
            phy_wr = 1'b0;
            phy_wdata = '0;
            log_rdata = '0;
        end
        
        cfg_rdata = fmmu_cfg_rdata[cfg_fmmu_sel];
    end

endmodule
