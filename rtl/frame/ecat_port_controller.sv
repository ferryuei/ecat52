// ============================================================================
// EtherCAT Port Controller
// Handles multi-port forwarding, loop detection, and DL status
// P1 High Priority Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_port_controller #(
    parameter NUM_PORTS = 2,          // Number of Ethernet ports (2-4)
    parameter LOOP_DETECT_EN = 1,     // Enable loop detection
    parameter REDUNDANCY_EN = 1       // Enable cable redundancy (P0)
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Port status inputs
    input  wire [NUM_PORTS-1:0]     port_link_up,       // Link status per port
    input  wire [NUM_PORTS-1:0]     port_rx_active,     // Frame being received
    input  wire [NUM_PORTS-1:0]     port_tx_active,     // Frame being transmitted
    
    // Frame reception info (from frame receiver)
    input  wire                     frame_rx_valid,     // Frame received
    input  wire [3:0]               frame_rx_port,      // Source port
    input  wire [47:0]              frame_src_mac,      // Source MAC address
    input  wire [47:0]              frame_dst_mac,      // Destination MAC address
    input  wire                     frame_is_ecat,      // EtherCAT frame
    input  wire                     frame_crc_error,    // CRC error detected
    
    // Control inputs (from register map)
    input  wire [NUM_PORTS-1:0]     port_enable,        // Port enable bits
    input  wire                     fwd_enable,         // Forwarding enable
    input  wire                     temp_loop_enable,   // Temporary loop enable
    input  wire [NUM_PORTS-1:0]     loop_port_sel,      // Loop port selection
    
    // Cable Redundancy control (P0)
    input  wire                     redundancy_enable,  // Enable redundancy mode
    input  wire [1:0]               redundancy_mode,    // 0=off, 1=line, 2=ring
    input  wire                     preferred_port,     // 0=port0, 1=port1 preferred
    
    // Forwarding outputs
    output reg  [NUM_PORTS-1:0]     fwd_port_mask,      // Ports to forward to
    output reg                      fwd_request,        // Forward request
    output reg  [3:0]               fwd_exclude_port,   // Exclude source port
    
    // DL Status outputs (for register 0x0110-0x0113)
    output reg  [15:0]              dl_status,          // DL Status register
    output reg  [15:0]              port_status_packed, // Per-port status (4 bits per port)
    
    // Loop detection
    output reg  [NUM_PORTS-1:0]     loop_detected,      // Loop detected per port
    output reg                      loop_active,        // Any loop is active
    
    // Cable Redundancy status (P0)
    output reg                      redundancy_active,  // Redundancy mode is active
    output reg  [1:0]               active_path,        // Currently active path (0=primary, 1=backup)
    output reg                      path_switched,      // Path switch event occurred
    output reg  [15:0]              switch_count,       // Path switch counter
    
    // Error counters
    output reg  [15:0]              rx_error_port0,
    output reg  [15:0]              rx_error_port1,
    output reg  [15:0]              lost_link_port0,
    output reg  [15:0]              lost_link_port1
);

    // ========================================================================
    // DL Status Register Bit Definitions (ETG.1000)
    // ========================================================================
    // Bits 0-3:   Port 0 status (0=open, 1=closed, 2=loop detected)
    // Bits 4-7:   Port 1 status
    // Bits 8-11:  Port 2 status (if present)
    // Bits 12-15: Port 3 status (if present)
    
    localparam PORT_STATUS_OPEN     = 4'h0;  // Port open (no connection)
    localparam PORT_STATUS_CLOSED   = 4'h1;  // Port closed (link up)
    localparam PORT_STATUS_LOOP     = 4'h2;  // Loop detected
    localparam PORT_STATUS_FORWARD  = 4'h4;  // Forwarding active

    // ========================================================================
    // Internal Registers
    // ========================================================================
    reg [NUM_PORTS-1:0] prev_link_up;
    reg [NUM_PORTS-1:0] link_loss_event;
    
    // Loop detection state machine
    typedef enum logic [2:0] {
        LOOP_IDLE,
        LOOP_SEND_TEST,
        LOOP_WAIT,
        LOOP_DETECTED,
        LOOP_CLEARED
    } loop_state_t;
    
    loop_state_t loop_state [0:NUM_PORTS-1];
    reg [15:0] loop_timer [0:NUM_PORTS-1];
    
    // MAC address learning (simple 4-entry table per port)
    reg [47:0] learned_mac [0:NUM_PORTS-1][0:3];
    reg [1:0]  mac_entry_idx [0:NUM_PORTS-1];
    
    // Internal port status (unpacked for logic)
    reg [3:0] port_status_int [0:NUM_PORTS-1];

    // ========================================================================
    // Port Status Generation
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                port_status_int[i] <= PORT_STATUS_OPEN;
            end
            dl_status <= 16'h0000;
            port_status_packed <= 16'h0000;
            prev_link_up <= {NUM_PORTS{1'b0}};
            link_loss_event <= {NUM_PORTS{1'b0}};
        end else begin
            prev_link_up <= port_link_up;
            
            // Detect link loss events
            link_loss_event <= prev_link_up & ~port_link_up;
            
            // Update port status
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (!port_link_up[i]) begin
                    port_status_int[i] <= PORT_STATUS_OPEN;
                end else if (loop_detected[i]) begin
                    port_status_int[i] <= PORT_STATUS_LOOP;
                end else if (port_enable[i]) begin
                    port_status_int[i] <= PORT_STATUS_CLOSED | PORT_STATUS_FORWARD;
                end else begin
                    port_status_int[i] <= PORT_STATUS_CLOSED;
                end
            end
            
            // Pack into DL status register
            dl_status <= {port_status_int[1], port_status_int[0], 8'h00};
            port_status_packed <= {port_status_int[3], port_status_int[2], port_status_int[1], port_status_int[0]};
            if (NUM_PORTS > 2) begin
                dl_status[11:8] <= port_status_int[2];
            end
            if (NUM_PORTS > 3) begin
                dl_status[15:12] <= port_status_int[3];
            end
        end
    end

    // ========================================================================
    // Forwarding Logic
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fwd_port_mask <= {NUM_PORTS{1'b0}};
            fwd_request <= 1'b0;
            fwd_exclude_port <= 4'h0;
        end else begin
            fwd_request <= 1'b0;
            
            if (frame_rx_valid && fwd_enable && !frame_crc_error) begin
                // Forward to all enabled ports except source
                fwd_port_mask <= port_enable & port_link_up;
                fwd_port_mask[frame_rx_port] <= 1'b0;  // Exclude source port
                fwd_exclude_port <= frame_rx_port;
                fwd_request <= 1'b1;
                
                // Handle temporary loop mode
                if (temp_loop_enable) begin
                    fwd_port_mask <= loop_port_sel & port_link_up;
                end
            end
        end
    end

    // ========================================================================
    // Loop Detection (per port)
    // ========================================================================
    generate
        if (LOOP_DETECT_EN) begin : gen_loop_detect
            for (genvar p = 0; p < NUM_PORTS; p++) begin : gen_port_loop
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        loop_state[p] <= LOOP_IDLE;
                        loop_timer[p] <= 16'h0;
                        loop_detected[p] <= 1'b0;
                    end else begin
                        case (loop_state[p])
                            LOOP_IDLE: begin
                                loop_detected[p] <= 1'b0;
                                if (port_link_up[p]) begin
                                    loop_state[p] <= LOOP_WAIT;
                                    loop_timer[p] <= 16'hFFFF;
                                end
                            end
                            
                            LOOP_WAIT: begin
                                if (!port_link_up[p]) begin
                                    loop_state[p] <= LOOP_IDLE;
                                end else if (loop_timer[p] == 0) begin
                                    loop_state[p] <= LOOP_IDLE;
                                end else begin
                                    loop_timer[p] <= loop_timer[p] - 1;
                                    
                                    // Check if we received our own frame back
                                    if (frame_rx_valid && frame_rx_port == p) begin
                                        // Simple loop detection: check if frame came back too fast
                                        // More sophisticated: check MAC address
                                        if (frame_src_mac == 48'hFFFFFFFFFFFF) begin
                                            loop_detected[p] <= 1'b1;
                                            loop_state[p] <= LOOP_DETECTED;
                                        end
                                    end
                                end
                            end
                            
                            LOOP_DETECTED: begin
                                loop_detected[p] <= 1'b1;
                                if (!port_link_up[p]) begin
                                    loop_state[p] <= LOOP_CLEARED;
                                end
                            end
                            
                            LOOP_CLEARED: begin
                                loop_detected[p] <= 1'b0;
                                loop_state[p] <= LOOP_IDLE;
                            end
                            
                            default: loop_state[p] <= LOOP_IDLE;
                        endcase
                    end
                end
            end
        end else begin : gen_no_loop_detect
            always_comb begin
                for (int p = 0; p < NUM_PORTS; p++) begin
                    loop_detected[p] = 1'b0;
                end
            end
        end
    endgenerate
    
    // Aggregate loop status
    always_comb begin
        loop_active = |loop_detected;
    end

    // ========================================================================
    // Error Counters
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_error_port0 <= 16'h0;
            rx_error_port1 <= 16'h0;
            lost_link_port0 <= 16'h0;
            lost_link_port1 <= 16'h0;
        end else begin
            // Count RX errors per port
            if (frame_rx_valid && frame_crc_error) begin
                case (frame_rx_port)
                    0: if (rx_error_port0 < 16'hFFFF) rx_error_port0 <= rx_error_port0 + 1;
                    1: if (rx_error_port1 < 16'hFFFF) rx_error_port1 <= rx_error_port1 + 1;
                endcase
            end
            
            // Count link loss events
            if (link_loss_event[0] && lost_link_port0 < 16'hFFFF) begin
                lost_link_port0 <= lost_link_port0 + 1;
            end
            if (link_loss_event[1] && lost_link_port1 < 16'hFFFF) begin
                lost_link_port1 <= lost_link_port1 + 1;
            end
        end
    end

    // ========================================================================
    // MAC Address Learning (Optional - for filtering)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int p = 0; p < NUM_PORTS; p++) begin
                mac_entry_idx[p] <= 2'b0;
                for (int e = 0; e < 4; e++) begin
                    learned_mac[p][e] <= 48'h0;
                end
            end
        end else begin
            // Learn source MAC addresses
            if (frame_rx_valid && !frame_crc_error && frame_rx_port < NUM_PORTS) begin
                // Simple round-robin entry
                learned_mac[frame_rx_port][mac_entry_idx[frame_rx_port]] <= frame_src_mac;
                mac_entry_idx[frame_rx_port] <= mac_entry_idx[frame_rx_port] + 1;
            end
        end
    end

    // ========================================================================
    // Cable Redundancy (P0 - ETG.1000)
    // Supports line and ring redundancy modes
    // ========================================================================
    
    // Redundancy state machine
    typedef enum logic [2:0] {
        RED_IDLE,
        RED_INIT,
        RED_PRIMARY,
        RED_BACKUP,
        RED_FAILOVER,
        RED_RECOVERY
    } redundancy_state_t;
    
    redundancy_state_t red_state;
    reg [15:0] failover_timer;
    reg [15:0] recovery_timer;
    reg        primary_port_up;
    reg        backup_port_up;
    
    // Redundancy mode constants
    localparam RED_MODE_OFF  = 2'b00;
    localparam RED_MODE_LINE = 2'b01;
    localparam RED_MODE_RING = 2'b10;
    
    // Failover/recovery timing (in clock cycles, ~10ms at 100MHz)
    localparam FAILOVER_TIME = 16'd1000000;
    localparam RECOVERY_TIME = 16'd5000000;  // 50ms
    
    generate
        if (REDUNDANCY_EN && NUM_PORTS >= 2) begin : gen_redundancy
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    red_state <= RED_IDLE;
                    redundancy_active <= 1'b0;
                    active_path <= 2'b00;
                    path_switched <= 1'b0;
                    switch_count <= 16'h0;
                    failover_timer <= 16'h0;
                    recovery_timer <= 16'h0;
                    primary_port_up <= 1'b0;
                    backup_port_up <= 1'b0;
                end else begin
                    // Default: clear one-shot signals
                    path_switched <= 1'b0;
                    
                    // Determine primary/backup port status
                    if (preferred_port == 1'b0) begin
                        primary_port_up <= port_link_up[0];
                        backup_port_up <= port_link_up[1];
                    end else begin
                        primary_port_up <= port_link_up[1];
                        backup_port_up <= port_link_up[0];
                    end
                    
                    case (red_state)
                        RED_IDLE: begin
                            redundancy_active <= 1'b0;
                            if (redundancy_enable && redundancy_mode != RED_MODE_OFF) begin
                                red_state <= RED_INIT;
                            end
                        end
                        
                        RED_INIT: begin
                            redundancy_active <= 1'b1;
                            switch_count <= 16'h0;
                            
                            // Start on preferred/primary path if available
                            if (primary_port_up) begin
                                active_path <= 2'b00;
                                red_state <= RED_PRIMARY;
                            end else if (backup_port_up) begin
                                active_path <= 2'b01;
                                red_state <= RED_BACKUP;
                            end else begin
                                // No link available, stay in init
                                active_path <= 2'b00;
                            end
                        end
                        
                        RED_PRIMARY: begin
                            if (!redundancy_enable) begin
                                red_state <= RED_IDLE;
                            end else if (!primary_port_up) begin
                                // Primary link lost, start failover
                                failover_timer <= FAILOVER_TIME;
                                red_state <= RED_FAILOVER;
                            end
                        end
                        
                        RED_BACKUP: begin
                            if (!redundancy_enable) begin
                                red_state <= RED_IDLE;
                            end else if (!backup_port_up) begin
                                // Backup link lost, try to return to primary
                                failover_timer <= FAILOVER_TIME;
                                red_state <= RED_FAILOVER;
                            end else if (primary_port_up) begin
                                // Primary is back, start recovery
                                recovery_timer <= RECOVERY_TIME;
                                red_state <= RED_RECOVERY;
                            end
                        end
                        
                        RED_FAILOVER: begin
                            if (failover_timer > 0) begin
                                failover_timer <= failover_timer - 1;
                            end else begin
                                // Failover complete, switch to available path
                                if (active_path == 2'b00 && backup_port_up) begin
                                    // Switch from primary to backup
                                    active_path <= 2'b01;
                                    path_switched <= 1'b1;
                                    if (switch_count < 16'hFFFF) switch_count <= switch_count + 1;
                                    red_state <= RED_BACKUP;
                                end else if (active_path == 2'b01 && primary_port_up) begin
                                    // Switch from backup to primary
                                    active_path <= 2'b00;
                                    path_switched <= 1'b1;
                                    if (switch_count < 16'hFFFF) switch_count <= switch_count + 1;
                                    red_state <= RED_PRIMARY;
                                end else if (primary_port_up) begin
                                    active_path <= 2'b00;
                                    path_switched <= 1'b1;
                                    if (switch_count < 16'hFFFF) switch_count <= switch_count + 1;
                                    red_state <= RED_PRIMARY;
                                end else if (backup_port_up) begin
                                    active_path <= 2'b01;
                                    path_switched <= 1'b1;
                                    if (switch_count < 16'hFFFF) switch_count <= switch_count + 1;
                                    red_state <= RED_BACKUP;
                                end else begin
                                    // No path available
                                    red_state <= RED_INIT;
                                end
                            end
                        end
                        
                        RED_RECOVERY: begin
                            // Wait before switching back to primary
                            if (!redundancy_enable) begin
                                red_state <= RED_IDLE;
                            end else if (!backup_port_up) begin
                                // Backup lost during recovery, immediate switch
                                active_path <= 2'b00;
                                path_switched <= 1'b1;
                                if (switch_count < 16'hFFFF) switch_count <= switch_count + 1;
                                red_state <= RED_PRIMARY;
                            end else if (recovery_timer > 0) begin
                                recovery_timer <= recovery_timer - 1;
                            end else if (primary_port_up) begin
                                // Recovery complete, switch back to primary
                                active_path <= 2'b00;
                                path_switched <= 1'b1;
                                if (switch_count < 16'hFFFF) switch_count <= switch_count + 1;
                                red_state <= RED_PRIMARY;
                            end else begin
                                // Primary went down during recovery
                                red_state <= RED_BACKUP;
                            end
                        end
                        
                        default: red_state <= RED_IDLE;
                    endcase
                end
            end
        end else begin : gen_no_redundancy
            always_comb begin
                redundancy_active = 1'b0;
                active_path = 2'b00;
                path_switched = 1'b0;
                switch_count = 16'h0;
            end
        end
    endgenerate

endmodule
