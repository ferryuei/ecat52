// ============================================================================
// EtherCAT Distributed Clock (DC) Module
// Implements ETG.1000 compliant DC functionality:
// - 64-bit System Time Counter
// - System Time Offset and Delay
// - SYNC0/SYNC1 Pulse Generation
// - Latch Input Capture
// - Port Receive Time Capture
// - Speed Counter for Drift Compensation
// ============================================================================

`include "ecat_pkg.vh"

module ecat_dc #(
    parameter CLK_PERIOD_NS = 40,     // Clock period in ns (40ns = 25MHz)
    parameter NUM_PORTS = 2           // Number of ports for receive time capture
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Register interface
    input  wire                     reg_req,
    input  wire                     reg_wr,
    input  wire [15:0]              reg_addr,
    input  wire [15:0]              reg_wdata,
    output reg  [15:0]              reg_rdata,
    output reg                      reg_ack,
    
    // Port receive time capture
    input  wire [NUM_PORTS-1:0]     port_rx_sof,      // Start of frame per port
    
    // SYNC I/O
    output wire                     sync0_out,
    output wire                     sync1_out,
    
    // Latch I/O
    input  wire                     latch0_in,
    input  wire                     latch1_in,
    
    // Status outputs
    output wire [63:0]              system_time,
    output wire                     dc_active,
    output wire                     sync0_active,
    output wire                     sync1_active
);

    // ========================================================================
    // DC Register Addresses (ETG.1000)
    // ========================================================================
    
    // Port Receive Time (0x0900-0x090F)
    localparam ADDR_PORT0_RECV_TIME   = 16'h0900;  // 64-bit
    localparam ADDR_PORT1_RECV_TIME   = 16'h0908;  // 64-bit
    
    // System Time (0x0910-0x092F)
    localparam ADDR_SYSTEM_TIME       = 16'h0910;  // 64-bit, read-only
    localparam ADDR_SYSTEM_OFFSET     = 16'h0920;  // 64-bit, R/W
    localparam ADDR_SYSTEM_DELAY      = 16'h0928;  // 32-bit, R/W
    
    // Speed Counter (0x0930-0x093F)
    localparam ADDR_SPEED_START       = 16'h0930;  // 32-bit
    localparam ADDR_SPEED_DIFF        = 16'h0934;  // 16-bit signed
    
    // DC Control (0x0980-0x098F)
    localparam ADDR_DC_CTRL_STATUS    = 16'h0980;  // 16-bit
    localparam ADDR_DC_ACTIVATION     = 16'h0981;  // 8-bit
    localparam ADDR_SYNC_IMPULSE_LEN  = 16'h0982;  // 16-bit
    
    // SYNC0 Configuration (0x0990-0x09A3)
    localparam ADDR_SYNC0_START_TIME  = 16'h0990;  // 64-bit
    localparam ADDR_SYNC0_CYCLE_TIME  = 16'h09A0;  // 32-bit
    
    // SYNC1 Configuration (0x09A4-0x09AF)
    localparam ADDR_SYNC1_CYCLE_TIME  = 16'h09A4;  // 32-bit
    localparam ADDR_SYNC1_START_SHIFT = 16'h09A8;  // 32-bit (start time or shift)
    
    // Latch Registers (0x09AE-0x09CF)
    localparam ADDR_LATCH_CTRL_STATUS = 16'h09AE;  // 16-bit
    localparam ADDR_LATCH0_POS_TIME   = 16'h09B0;  // 64-bit
    localparam ADDR_LATCH0_NEG_TIME   = 16'h09B8;  // 64-bit
    localparam ADDR_LATCH1_POS_TIME   = 16'h09C0;  // 64-bit
    localparam ADDR_LATCH1_NEG_TIME   = 16'h09C8;  // 64-bit
    
    // ========================================================================
    // DC Activation Bits
    // ========================================================================
    localparam DC_ACT_CYCLIC_OP      = 0;  // Cyclic operation enable
    localparam DC_ACT_SYNC0_EN       = 1;  // SYNC0 enable
    localparam DC_ACT_SYNC1_EN       = 2;  // SYNC1 enable
    
    // Latch Control Bits
    localparam LATCH_CTRL_POS_EN     = 0;  // Positive edge enable
    localparam LATCH_CTRL_NEG_EN     = 1;  // Negative edge enable
    localparam LATCH_CTRL_SINGLE     = 8;  // Single-shot mode (vs continuous)
    localparam LATCH_STAT_POS_EVT    = 0;  // Positive edge event occurred
    localparam LATCH_STAT_NEG_EVT    = 1;  // Negative edge event occurred
    
    // ========================================================================
    // Internal Registers
    // ========================================================================
    
    // Local Time Counter (64-bit, increments each clock cycle)
    reg [63:0]  local_time;
    
    // System Time Offset and Delay
    reg [63:0]  system_time_offset;
    reg [31:0]  system_time_delay;
    
    // Port Receive Time Registers
    reg [63:0]  port_recv_time [0:NUM_PORTS-1];
    reg [NUM_PORTS-1:0] port_rx_sof_prev;
    
    // Speed Counter Registers
    reg [31:0]  speed_counter_start;
    reg signed [15:0] speed_counter_diff;
    reg [31:0]  speed_counter_remaining;
    reg signed [31:0] speed_accumulator;      // Fractional accumulator
    
    // DC Activation and Control
    reg [7:0]   dc_activation;
    reg [15:0]  sync_impulse_length;
    
    // SYNC0 Registers
    reg [63:0]  sync0_start_time;
    reg [31:0]  sync0_cycle_time;
    reg [63:0]  sync0_next_time;
    reg [15:0]  sync0_pulse_counter;
    reg         sync0_pulse;
    reg         sync0_armed;
    reg         sync0_prev_pulse;  // For SYNC1 associated mode edge detection
    
    // SYNC1 Registers
    reg [31:0]  sync1_cycle_time;
    reg [31:0]  sync1_start_shift;
    reg [63:0]  sync1_next_time;
    reg [15:0]  sync1_pulse_counter;
    reg         sync1_pulse;
    reg         sync1_armed;
    
    // Latch Registers
    reg [15:0]  latch_ctrl_status;
    reg [63:0]  latch0_pos_time;
    reg [63:0]  latch0_neg_time;
    reg [63:0]  latch1_pos_time;
    reg [63:0]  latch1_neg_time;
    reg         latch0_captured;
    reg         latch1_captured;
    
    // Latch input synchronizers (3-stage for metastability)
    reg [2:0]   latch0_sync;
    reg [2:0]   latch1_sync;
    reg         latch0_prev;
    reg         latch1_prev;
    
    // ========================================================================
    // System Time Calculation
    // ========================================================================
    
    // System time = local_time + offset + delay
    assign system_time = local_time + system_time_offset + {32'b0, system_time_delay};
    
    // Status outputs
    assign dc_active = dc_activation[DC_ACT_CYCLIC_OP];
    assign sync0_active = dc_activation[DC_ACT_SYNC0_EN] && sync0_armed;
    assign sync1_active = dc_activation[DC_ACT_SYNC1_EN] && sync1_armed;
    
    // SYNC outputs (active high pulse)
    assign sync0_out = sync0_pulse && dc_activation[DC_ACT_SYNC0_EN];
    assign sync1_out = sync1_pulse && dc_activation[DC_ACT_SYNC1_EN];
    
    // ========================================================================
    // Local Time Counter with Speed Adjustment
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            local_time <= 64'h0;
            speed_accumulator <= 32'h0;
            speed_counter_remaining <= 32'h0;
        end else begin
            // Calculate increment with speed adjustment
            if (speed_counter_remaining > 0) begin
                // Apply fractional speed adjustment
                speed_accumulator <= speed_accumulator + {{16{speed_counter_diff[15]}}, speed_counter_diff};
                
                // Add integer portion to local time
                local_time <= local_time + CLK_PERIOD_NS + speed_accumulator[31:16];
                speed_accumulator[31:16] <= 16'h0;  // Clear integer portion
                
                speed_counter_remaining <= speed_counter_remaining - 1;
            end else begin
                // Normal increment
                local_time <= local_time + CLK_PERIOD_NS;
            end
        end
    end
    
    // ========================================================================
    // Port Receive Time Capture
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                port_recv_time[i] <= 64'h0;
            end
            port_rx_sof_prev <= '0;
        end else begin
            port_rx_sof_prev <= port_rx_sof;
            
            // Capture local time on rising edge of SOF
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (port_rx_sof[i] && !port_rx_sof_prev[i]) begin
                    port_recv_time[i] <= local_time;
                end
            end
        end
    end
    
    // ========================================================================
    // SYNC0 Pulse Generation
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0_armed <= 1'b0;
            sync0_pulse <= 1'b0;
            sync0_pulse_counter <= 16'h0;
            sync0_next_time <= 64'h0;
            sync0_prev_pulse <= 1'b0;
        end else begin
            // Check if SYNC0 is enabled
            if (dc_activation[DC_ACT_SYNC0_EN]) begin
                // Arm when start time is configured and cycle time > 0
                if (!sync0_armed && sync0_cycle_time > 0) begin
                    sync0_armed <= 1'b1;
                    sync0_next_time <= sync0_start_time;
                end
                
                // Generate pulse when system time reaches next time
                if (sync0_armed && system_time >= sync0_next_time) begin
                    if (!sync0_pulse) begin
                        // Start pulse
                        sync0_pulse <= 1'b1;
                        // Load counter with length-1 so pulse is exactly impulse_length cycles
                        sync0_pulse_counter <= (sync_impulse_length > 1) ? (sync_impulse_length - 1) : 16'd9;
                        // Schedule next pulse
                        sync0_next_time <= sync0_next_time + {32'b0, sync0_cycle_time};
                    end
                end
                
                // Pulse width control
                if (sync0_pulse) begin
                    if (sync0_pulse_counter > 0) begin
                        sync0_pulse_counter <= sync0_pulse_counter - 1;
                    end else begin
                        sync0_pulse <= 1'b0;
                    end
                end
            end else begin
                // SYNC0 disabled
                sync0_armed <= 1'b0;
                sync0_pulse <= 1'b0;
            end
            // Update previous pulse state for SYNC1 associated mode
            sync0_prev_pulse <= sync0_pulse;
        end
    end
    
    // ========================================================================
    // SYNC1 Pulse Generation
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync1_armed <= 1'b0;
            sync1_pulse <= 1'b0;
            sync1_pulse_counter <= 16'h0;
            sync1_next_time <= 64'h0;
        end else begin
            // Check if SYNC1 is enabled
            if (dc_activation[DC_ACT_SYNC1_EN]) begin
                if (sync1_cycle_time > 0) begin
                    // Independent mode: SYNC1 has its own cycle time
                    if (!sync1_armed) begin
                        sync1_armed <= 1'b1;
                        sync1_next_time <= sync0_start_time + {32'b0, sync1_start_shift};
                    end
                    
                    // Generate pulse
                    if (sync1_armed && system_time >= sync1_next_time) begin
                        if (!sync1_pulse) begin
                            sync1_pulse <= 1'b1;
                            sync1_pulse_counter <= (sync_impulse_length > 1) ? (sync_impulse_length - 1) : 16'd9;
                            sync1_next_time <= sync1_next_time + {32'b0, sync1_cycle_time};
                        end
                    end
                end else begin
                    // Associated mode: SYNC1 follows SYNC0 with phase shift
                    if (sync0_armed) begin
                        sync1_armed <= 1'b1;
                        
                        // Detect sync0_pulse start to schedule sync1
                        if (sync0_pulse && !sync0_prev_pulse) begin
                            // Schedule SYNC1 after shift from SYNC0 activation
                            sync1_next_time <= system_time + {32'b0, sync1_start_shift};
                        end
                        
                        // Generate SYNC1 pulse at calculated time
                        if (sync1_armed && system_time >= sync1_next_time && sync1_next_time > 0) begin
                            if (!sync1_pulse) begin
                                sync1_pulse <= 1'b1;
                                sync1_pulse_counter <= (sync_impulse_length > 1) ? (sync_impulse_length - 1) : 16'd9;
                            end
                        end
                    end
                end
                
                // Pulse width control
                if (sync1_pulse) begin
                    if (sync1_pulse_counter > 0) begin
                        sync1_pulse_counter <= sync1_pulse_counter - 1;
                    end else begin
                        sync1_pulse <= 1'b0;
                    end
                end
            end else begin
                sync1_armed <= 1'b0;
                sync1_pulse <= 1'b0;
            end
        end
    end
    
    // ========================================================================
    // Latch Input Synchronization and Edge Detection
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latch0_sync <= 3'b000;
            latch1_sync <= 3'b000;
            latch0_prev <= 1'b0;
            latch1_prev <= 1'b0;
        end else begin
            // 3-stage synchronizer
            latch0_sync <= {latch0_sync[1:0], latch0_in};
            latch1_sync <= {latch1_sync[1:0], latch1_in};
            
            // Store previous synchronized value for edge detection
            latch0_prev <= latch0_sync[2];
            latch1_prev <= latch1_sync[2];
        end
    end
    
    // ========================================================================
    // Latch Capture Logic
    // ========================================================================
    
    wire latch0_pos_edge = latch0_sync[2] && !latch0_prev;
    wire latch0_neg_edge = !latch0_sync[2] && latch0_prev;
    wire latch1_pos_edge = latch1_sync[2] && !latch1_prev;
    wire latch1_neg_edge = !latch1_sync[2] && latch1_prev;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latch0_pos_time <= 64'h0;
            latch0_neg_time <= 64'h0;
            latch1_pos_time <= 64'h0;
            latch1_neg_time <= 64'h0;
            latch0_captured <= 1'b0;
            latch1_captured <= 1'b0;
            latch_ctrl_status[15:8] <= 8'h0;  // Clear status bits
        end else begin
            // Latch0 positive edge capture
            if (latch_ctrl_status[LATCH_CTRL_POS_EN] && latch0_pos_edge) begin
                // Check single-shot mode
                if (!latch_ctrl_status[LATCH_CTRL_SINGLE] || !latch0_captured) begin
                    latch0_pos_time <= system_time;
                    latch_ctrl_status[8 + LATCH_STAT_POS_EVT] <= 1'b1;
                    latch0_captured <= 1'b1;
                end
            end
            
            // Latch0 negative edge capture
            if (latch_ctrl_status[LATCH_CTRL_NEG_EN] && latch0_neg_edge) begin
                if (!latch_ctrl_status[LATCH_CTRL_SINGLE] || !latch0_captured) begin
                    latch0_neg_time <= system_time;
                    latch_ctrl_status[8 + LATCH_STAT_NEG_EVT] <= 1'b1;
                    latch0_captured <= 1'b1;
                end
            end
            
            // Latch1 positive edge capture (uses bits 2,3 for enable, 10,11 for status)
            if (latch_ctrl_status[LATCH_CTRL_POS_EN + 2] && latch1_pos_edge) begin
                if (!latch_ctrl_status[LATCH_CTRL_SINGLE + 1] || !latch1_captured) begin
                    latch1_pos_time <= system_time;
                    latch_ctrl_status[10] <= 1'b1;
                    latch1_captured <= 1'b1;
                end
            end
            
            // Latch1 negative edge capture
            if (latch_ctrl_status[LATCH_CTRL_NEG_EN + 2] && latch1_neg_edge) begin
                if (!latch_ctrl_status[LATCH_CTRL_SINGLE + 1] || !latch1_captured) begin
                    latch1_neg_time <= system_time;
                    latch_ctrl_status[11] <= 1'b1;
                    latch1_captured <= 1'b1;
                end
            end
        end
    end
    
    // ========================================================================
    // Register Read/Write Logic
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_rdata <= 16'h0000;
            reg_ack <= 1'b0;
            system_time_offset <= 64'h0;
            system_time_delay <= 32'h0;
            speed_counter_start <= 32'h0;
            speed_counter_diff <= 16'h0;
            dc_activation <= 8'h0;
            sync_impulse_length <= 16'd10;
            sync0_start_time <= 64'h0;
            sync0_cycle_time <= 32'h0;
            sync1_cycle_time <= 32'h0;
            sync1_start_shift <= 32'h0;
            latch_ctrl_status[7:0] <= 8'h0;
        end else begin
            reg_ack <= 1'b0;
            
            if (reg_req) begin
                reg_ack <= 1'b1;
                
                if (reg_wr) begin
                    // Write operations
                    case (reg_addr)
                        // System Time Offset (64-bit)
                        ADDR_SYSTEM_OFFSET:     system_time_offset[15:0] <= reg_wdata;
                        ADDR_SYSTEM_OFFSET+2:   system_time_offset[31:16] <= reg_wdata;
                        ADDR_SYSTEM_OFFSET+4:   system_time_offset[47:32] <= reg_wdata;
                        ADDR_SYSTEM_OFFSET+6:   system_time_offset[63:48] <= reg_wdata;
                        
                        // System Time Delay (32-bit)
                        ADDR_SYSTEM_DELAY:      system_time_delay[15:0] <= reg_wdata;
                        ADDR_SYSTEM_DELAY+2:    system_time_delay[31:16] <= reg_wdata;
                        
                        // Speed Counter
                        ADDR_SPEED_START:       begin
                            speed_counter_start[15:0] <= reg_wdata;
                        end
                        ADDR_SPEED_START+2:     begin
                            speed_counter_start[31:16] <= reg_wdata;
                            // Start speed adjustment when upper word written
                            speed_counter_remaining <= {reg_wdata, speed_counter_start[15:0]};
                        end
                        ADDR_SPEED_DIFF:        speed_counter_diff <= reg_wdata[15:0];
                        
                        // DC Activation
                        ADDR_DC_ACTIVATION:     dc_activation <= reg_wdata[7:0];
                        
                        // Sync Impulse Length
                        ADDR_SYNC_IMPULSE_LEN:  sync_impulse_length <= reg_wdata;
                        
                        // SYNC0 Start Time (64-bit)
                        ADDR_SYNC0_START_TIME:    sync0_start_time[15:0] <= reg_wdata;
                        ADDR_SYNC0_START_TIME+2:  sync0_start_time[31:16] <= reg_wdata;
                        ADDR_SYNC0_START_TIME+4:  sync0_start_time[47:32] <= reg_wdata;
                        ADDR_SYNC0_START_TIME+6:  sync0_start_time[63:48] <= reg_wdata;
                        
                        // SYNC0 Cycle Time (32-bit)
                        ADDR_SYNC0_CYCLE_TIME:    sync0_cycle_time[15:0] <= reg_wdata;
                        ADDR_SYNC0_CYCLE_TIME+2:  sync0_cycle_time[31:16] <= reg_wdata;
                        
                        // SYNC1 Cycle Time (32-bit)
                        ADDR_SYNC1_CYCLE_TIME:    sync1_cycle_time[15:0] <= reg_wdata;
                        ADDR_SYNC1_CYCLE_TIME+2:  sync1_cycle_time[31:16] <= reg_wdata;
                        
                        // SYNC1 Start/Shift (32-bit)
                        ADDR_SYNC1_START_SHIFT:   sync1_start_shift[15:0] <= reg_wdata;
                        ADDR_SYNC1_START_SHIFT+2: sync1_start_shift[31:16] <= reg_wdata;
                        
                        // Latch Control (write clears status bits when writing 1)
                        ADDR_LATCH_CTRL_STATUS: begin
                            latch_ctrl_status[7:0] <= reg_wdata[7:0];
                            // Clear event flags if written with 1
                            if (reg_wdata[8]) begin
                                latch_ctrl_status[8] <= 1'b0;
                                latch0_captured <= 1'b0;
                            end
                            if (reg_wdata[9]) begin
                                latch_ctrl_status[9] <= 1'b0;
                                latch0_captured <= 1'b0;
                            end
                            if (reg_wdata[10]) begin
                                latch_ctrl_status[10] <= 1'b0;
                                latch1_captured <= 1'b0;
                            end
                            if (reg_wdata[11]) begin
                                latch_ctrl_status[11] <= 1'b0;
                                latch1_captured <= 1'b0;
                            end
                        end
                        
                        default: ;
                    endcase
                end else begin
                    // Read operations
                    case (reg_addr)
                        // Port Receive Time (64-bit each)
                        ADDR_PORT0_RECV_TIME:     reg_rdata <= port_recv_time[0][15:0];
                        ADDR_PORT0_RECV_TIME+2:   reg_rdata <= port_recv_time[0][31:16];
                        ADDR_PORT0_RECV_TIME+4:   reg_rdata <= port_recv_time[0][47:32];
                        ADDR_PORT0_RECV_TIME+6:   reg_rdata <= port_recv_time[0][63:48];
                        
                        ADDR_PORT1_RECV_TIME:     reg_rdata <= (NUM_PORTS > 1) ? port_recv_time[1][15:0] : 16'h0;
                        ADDR_PORT1_RECV_TIME+2:   reg_rdata <= (NUM_PORTS > 1) ? port_recv_time[1][31:16] : 16'h0;
                        ADDR_PORT1_RECV_TIME+4:   reg_rdata <= (NUM_PORTS > 1) ? port_recv_time[1][47:32] : 16'h0;
                        ADDR_PORT1_RECV_TIME+6:   reg_rdata <= (NUM_PORTS > 1) ? port_recv_time[1][63:48] : 16'h0;
                        
                        // System Time (64-bit, read-only)
                        ADDR_SYSTEM_TIME:         reg_rdata <= system_time[15:0];
                        ADDR_SYSTEM_TIME+2:       reg_rdata <= system_time[31:16];
                        ADDR_SYSTEM_TIME+4:       reg_rdata <= system_time[47:32];
                        ADDR_SYSTEM_TIME+6:       reg_rdata <= system_time[63:48];
                        
                        // System Time Offset
                        ADDR_SYSTEM_OFFSET:       reg_rdata <= system_time_offset[15:0];
                        ADDR_SYSTEM_OFFSET+2:     reg_rdata <= system_time_offset[31:16];
                        ADDR_SYSTEM_OFFSET+4:     reg_rdata <= system_time_offset[47:32];
                        ADDR_SYSTEM_OFFSET+6:     reg_rdata <= system_time_offset[63:48];
                        
                        // System Time Delay
                        ADDR_SYSTEM_DELAY:        reg_rdata <= system_time_delay[15:0];
                        ADDR_SYSTEM_DELAY+2:      reg_rdata <= system_time_delay[31:16];
                        
                        // Speed Counter
                        ADDR_SPEED_START:         reg_rdata <= speed_counter_start[15:0];
                        ADDR_SPEED_START+2:       reg_rdata <= speed_counter_start[31:16];
                        ADDR_SPEED_DIFF:          reg_rdata <= speed_counter_diff;
                        
                        // DC Activation
                        ADDR_DC_ACTIVATION:       reg_rdata <= {8'h00, dc_activation};
                        
                        // Sync Impulse Length
                        ADDR_SYNC_IMPULSE_LEN:    reg_rdata <= sync_impulse_length;
                        
                        // SYNC0 Start Time
                        ADDR_SYNC0_START_TIME:    reg_rdata <= sync0_start_time[15:0];
                        ADDR_SYNC0_START_TIME+2:  reg_rdata <= sync0_start_time[31:16];
                        ADDR_SYNC0_START_TIME+4:  reg_rdata <= sync0_start_time[47:32];
                        ADDR_SYNC0_START_TIME+6:  reg_rdata <= sync0_start_time[63:48];
                        
                        // SYNC0 Cycle Time
                        ADDR_SYNC0_CYCLE_TIME:    reg_rdata <= sync0_cycle_time[15:0];
                        ADDR_SYNC0_CYCLE_TIME+2:  reg_rdata <= sync0_cycle_time[31:16];
                        
                        // SYNC1 Cycle Time
                        ADDR_SYNC1_CYCLE_TIME:    reg_rdata <= sync1_cycle_time[15:0];
                        ADDR_SYNC1_CYCLE_TIME+2:  reg_rdata <= sync1_cycle_time[31:16];
                        
                        // SYNC1 Start/Shift
                        ADDR_SYNC1_START_SHIFT:   reg_rdata <= sync1_start_shift[15:0];
                        ADDR_SYNC1_START_SHIFT+2: reg_rdata <= sync1_start_shift[31:16];
                        
                        // Latch Control/Status
                        ADDR_LATCH_CTRL_STATUS:   reg_rdata <= latch_ctrl_status;
                        
                        // Latch0 Positive Edge Time
                        ADDR_LATCH0_POS_TIME:     reg_rdata <= latch0_pos_time[15:0];
                        ADDR_LATCH0_POS_TIME+2:   reg_rdata <= latch0_pos_time[31:16];
                        ADDR_LATCH0_POS_TIME+4:   reg_rdata <= latch0_pos_time[47:32];
                        ADDR_LATCH0_POS_TIME+6:   reg_rdata <= latch0_pos_time[63:48];
                        
                        // Latch0 Negative Edge Time
                        ADDR_LATCH0_NEG_TIME:     reg_rdata <= latch0_neg_time[15:0];
                        ADDR_LATCH0_NEG_TIME+2:   reg_rdata <= latch0_neg_time[31:16];
                        ADDR_LATCH0_NEG_TIME+4:   reg_rdata <= latch0_neg_time[47:32];
                        ADDR_LATCH0_NEG_TIME+6:   reg_rdata <= latch0_neg_time[63:48];
                        
                        // Latch1 Positive Edge Time
                        ADDR_LATCH1_POS_TIME:     reg_rdata <= latch1_pos_time[15:0];
                        ADDR_LATCH1_POS_TIME+2:   reg_rdata <= latch1_pos_time[31:16];
                        ADDR_LATCH1_POS_TIME+4:   reg_rdata <= latch1_pos_time[47:32];
                        ADDR_LATCH1_POS_TIME+6:   reg_rdata <= latch1_pos_time[63:48];
                        
                        // Latch1 Negative Edge Time
                        ADDR_LATCH1_NEG_TIME:     reg_rdata <= latch1_neg_time[15:0];
                        ADDR_LATCH1_NEG_TIME+2:   reg_rdata <= latch1_neg_time[31:16];
                        ADDR_LATCH1_NEG_TIME+4:   reg_rdata <= latch1_neg_time[47:32];
                        ADDR_LATCH1_NEG_TIME+6:   reg_rdata <= latch1_neg_time[63:48];
                        
                        default: reg_rdata <= 16'h0000;
                    endcase
                end
            end
        end
    end

endmodule
