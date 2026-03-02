// ============================================================================
// EtherCAT AL (Application Layer) State Machine
// Implements ETG.1000 state transitions: Init→Pre-Op→Safe-Op→Op
// P0 Critical Function
// ============================================================================

`include "ecat_pkg.vh"

module ecat_al_statemachine (
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // AL Control from register map (master command)
    input  wire [4:0]               al_control_req,    // Requested state (5-bit for error states)
    input  wire                     al_control_changed,
    
    // AL Status to register map
    output reg  [4:0]               al_status,         // Current state (5-bit for error states)
    output reg  [15:0]              al_status_code,    // Error code
    
    // Sync Manager status
    input  wire [7:0]               sm_activate,       // SM activation status
    input  wire [7:0]               sm_error,          // SM error flags
    
    // FMMU status
    input  wire [7:0]               fmmu_activate,     // FMMU activation status
    
    // PDI status
    input  wire                     pdi_operational,   // PDI is ready
    input  wire                     pdi_watchdog_timeout,
    
    // DC (Distributed Clock) status
    input  wire                     dc_sync_active,
    input  wire                     dc_sync_error,
    
    // EEPROM status
    input  wire                     eeprom_loaded,     // Configuration loaded
    input  wire                     eeprom_error,
    
    // Link status
    input  wire [3:0]               port_link_status,
    
    // Control outputs
    output reg                      sm_enable,         // Enable Sync Managers
    output reg                      fmmu_enable,       // Enable FMMUs
    output reg                      pdi_enable,        // Enable PDI
    output reg                      watchdog_enable,   // Enable watchdog
    
    // IRQ
    output reg                      al_event_irq       // AL state change interrupt
);

    // ========================================================================
    // AL State Definitions (ETG.1000 Section 6.4)
    // ========================================================================
    typedef enum logic [4:0] {
        AL_STATE_INIT       = 5'h01,  // Init state
        AL_STATE_PREOP      = 5'h02,  // Pre-Operational
        AL_STATE_BOOT       = 5'h03,  // Bootstrap (firmware update)
        AL_STATE_SAFEOP     = 5'h04,  // Safe-Operational
        AL_STATE_OP         = 5'h08,  // Operational
        
        // Error states (bit 4 set)
        AL_STATE_INIT_ERR   = 5'h11,  // Init + Error
        AL_STATE_PREOP_ERR  = 5'h12,  // Pre-Op + Error
        AL_STATE_SAFEOP_ERR = 5'h14   // Safe-Op + Error
    } al_state_t;
    
    al_state_t current_state, next_state, target_state;
    
    // ========================================================================
    // AL Status Code Definitions (ETG.1000 Table 21)
    // ========================================================================
    localparam AL_STATUS_NO_ERROR           = 16'h0000;
    localparam AL_STATUS_UNSPEC_ERROR       = 16'h0001;
    localparam AL_STATUS_NO_MEMORY          = 16'h0002;
    localparam AL_STATUS_INVALID_SETUP      = 16'h0004;
    localparam AL_STATUS_INVALID_MAILBOX    = 16'h0006;
    localparam AL_STATUS_INVALID_SM_CONFIG  = 16'h0007;
    localparam AL_STATUS_NO_INPUTS          = 16'h000B;
    localparam AL_STATUS_NO_OUTPUTS         = 16'h000C;
    localparam AL_STATUS_SYNC_ERROR         = 16'h001B;
    localparam AL_STATUS_SM_WATCHDOG        = 16'h001C;
    localparam AL_STATUS_INVALID_SM_TYPES   = 16'h001D;
    localparam AL_STATUS_INVALID_OUTPUT_CFG = 16'h001E;
    localparam AL_STATUS_INVALID_INPUT_CFG  = 16'h001F;
    localparam AL_STATUS_INVALID_WATCHDOG   = 16'h0020;
    localparam AL_STATUS_COLD_START         = 16'h0022;
    localparam AL_STATUS_INIT_NOT_FINISHED  = 16'h0023;
    localparam AL_STATUS_DC_NOT_SYNC        = 16'h0030;
    localparam AL_STATUS_DC_INVALID_SYNC    = 16'h0031;
    localparam AL_STATUS_DC_SYNC0_CYCLE     = 16'h0032;
    localparam AL_STATUS_DC_SYNC1_CYCLE     = 16'h0033;
    
    // ========================================================================
    // Internal Signals
    // ========================================================================
    reg         transition_allowed;
    reg         error_detected;
    reg [15:0]  error_code;
    reg [3:0]   state_timer;         // Delay counter for state transitions
    
    // ========================================================================
    // State Machine
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= AL_STATE_INIT;
            al_status <= AL_STATE_INIT;
            al_status_code <= AL_STATUS_NO_ERROR;
            target_state <= AL_STATE_INIT;
            state_timer <= '0;
            al_event_irq <= 1'b0;
        end else begin
            al_event_irq <= 1'b0;
            
            // Capture new target state from master
            if (al_control_changed) begin
                /* verilator lint_off ENUMVALUE */
                target_state <= al_control_req;  // Direct assign (iverilog/Verilator compatible)
                /* verilator lint_on ENUMVALUE */
            end
            
            // State transition logic
            if (state_timer > 0) begin
                state_timer <= state_timer - 1;
            end else if (current_state != target_state) begin
                // Check if transition is allowed
                if (check_transition_allowed(current_state, target_state)) begin
                    if (!error_detected) begin
                        current_state <= next_state;
                        al_status <= next_state;
                        al_status_code <= AL_STATUS_NO_ERROR;
                        state_timer <= 4'd3;  // Small delay for state stabilization
                        al_event_irq <= 1'b1;
                    end else begin
                        // Transition failed, enter error state
                        /* verilator lint_off ENUMVALUE */
                        current_state <= get_error_state(current_state);
                        /* verilator lint_on ENUMVALUE */
                        al_status <= get_error_state(current_state);
                        al_status_code <= error_code;
                        al_event_irq <= 1'b1;
                    end
                end
            end
            
            // Monitor for errors in current state
            if (error_detected && al_status_code == AL_STATUS_NO_ERROR) begin
                al_status_code <= error_code;
                al_event_irq <= 1'b1;
            end
        end
    end
    
    // ========================================================================
    // Next State Logic
    // ========================================================================
    
    always_comb begin
        next_state = current_state;
        
        case (current_state)
            AL_STATE_INIT: begin
                if (target_state == AL_STATE_PREOP || target_state == AL_STATE_BOOT)
                    next_state = target_state;
            end
            
            AL_STATE_PREOP: begin
                if (target_state == AL_STATE_INIT)
                    next_state = AL_STATE_INIT;
                else if (target_state == AL_STATE_SAFEOP)
                    next_state = AL_STATE_SAFEOP;
                else if (target_state == AL_STATE_BOOT)
                    next_state = AL_STATE_BOOT;
            end
            
            AL_STATE_BOOT: begin
                if (target_state == AL_STATE_INIT)
                    next_state = AL_STATE_INIT;
            end
            
            AL_STATE_SAFEOP: begin
                if (target_state == AL_STATE_INIT)
                    next_state = AL_STATE_INIT;
                else if (target_state == AL_STATE_PREOP)
                    next_state = AL_STATE_PREOP;
                else if (target_state == AL_STATE_OP)
                    next_state = AL_STATE_OP;
            end
            
            AL_STATE_OP: begin
                if (target_state == AL_STATE_INIT)
                    next_state = AL_STATE_INIT;
                else if (target_state == AL_STATE_PREOP)
                    next_state = AL_STATE_PREOP;
                else if (target_state == AL_STATE_SAFEOP)
                    next_state = AL_STATE_SAFEOP;
            end
            
            // Error states can only transition back to Init
            AL_STATE_INIT_ERR,
            AL_STATE_PREOP_ERR,
            AL_STATE_SAFEOP_ERR: begin
                if (target_state == AL_STATE_INIT)
                    next_state = AL_STATE_INIT;
            end
            
            default: next_state = AL_STATE_INIT;
        endcase
    end
    
    // ========================================================================
    // Transition Condition Checking
    // ========================================================================
    
    function check_transition_allowed;
        input [3:0] from_state;
        input [3:0] to_state;
        reg allowed;
        begin
            allowed = 1'b1;
            
            case (to_state)
                AL_STATE_INIT: begin
                    // Always allowed to return to Init
                    allowed = 1'b1;
                end
                
                AL_STATE_PREOP: begin
                    // Requires EEPROM loaded (or emulated)
                    allowed = eeprom_loaded || (from_state == AL_STATE_SAFEOP || from_state == AL_STATE_OP);
                end
                
                AL_STATE_BOOT: begin
                    // Bootstrap mode for firmware update
                    allowed = 1'b1;
                end
                
                AL_STATE_SAFEOP: begin
                    // Requires:
                    // - Valid Sync Manager configuration
                    // - FMMUs configured if needed
                    // - PDI ready
                    allowed = (|sm_activate) && !pdi_watchdog_timeout;
                end
                
                AL_STATE_OP: begin
                    // Requires:
                    // - All Safe-Op requirements met
                    // - Outputs valid (if any)
                    // - DC synchronized (if used)
                    allowed = (from_state == AL_STATE_SAFEOP) &&
                             pdi_operational &&
                             (!dc_sync_active || !dc_sync_error);
                end
                
                default: allowed = 1'b0;
            endcase
            
            check_transition_allowed = allowed;
        end
    endfunction
    
    // ========================================================================
    // Error Detection Logic
    // ========================================================================
    
    always_comb begin
        error_detected = 1'b0;
        error_code = AL_STATUS_NO_ERROR;
        
        // Check for Sync Manager errors
        if (|sm_error) begin
            error_detected = 1'b1;
            error_code = AL_STATUS_INVALID_SM_CONFIG;
        end
        
        // Check for PDI watchdog timeout
        else if (pdi_watchdog_timeout && (current_state == AL_STATE_SAFEOP || current_state == AL_STATE_OP)) begin
            error_detected = 1'b1;
            error_code = AL_STATUS_SM_WATCHDOG;
        end
        
        // Check for DC sync errors
        else if (dc_sync_active && dc_sync_error && current_state == AL_STATE_OP) begin
            error_detected = 1'b1;
            error_code = AL_STATUS_DC_NOT_SYNC;
        end
        
        // Check for EEPROM errors
        else if (eeprom_error) begin
            error_detected = 1'b1;
            error_code = AL_STATUS_INVALID_SETUP;
        end
        
        // Check for missing configuration
        else if (current_state == AL_STATE_SAFEOP && sm_activate == 8'h00) begin
            error_detected = 1'b1;
            error_code = AL_STATUS_INVALID_SM_CONFIG;
        end
    end
    
    // ========================================================================
    // Control Output Logic
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_enable <= 1'b0;
            fmmu_enable <= 1'b0;
            pdi_enable <= 1'b0;
            watchdog_enable <= 1'b0;
        end else begin
            case (current_state)
                AL_STATE_INIT: begin
                    sm_enable <= 1'b0;
                    fmmu_enable <= 1'b0;
                    pdi_enable <= 1'b0;
                    watchdog_enable <= 1'b0;
                end
                
                AL_STATE_PREOP,
                AL_STATE_BOOT: begin
                    sm_enable <= 1'b0;
                    fmmu_enable <= 1'b0;
                    pdi_enable <= 1'b1;      // Allow configuration
                    watchdog_enable <= 1'b0;
                end
                
                AL_STATE_SAFEOP: begin
                    sm_enable <= 1'b1;
                    fmmu_enable <= 1'b1;
                    pdi_enable <= 1'b1;
                    watchdog_enable <= 1'b1;  // Start watchdog
                end
                
                AL_STATE_OP: begin
                    sm_enable <= 1'b1;
                    fmmu_enable <= 1'b1;
                    pdi_enable <= 1'b1;
                    watchdog_enable <= 1'b1;
                end
                
                default: begin
                    sm_enable <= 1'b0;
                    fmmu_enable <= 1'b0;
                    pdi_enable <= 1'b0;
                    watchdog_enable <= 1'b0;
                end
            endcase
        end
    end
    
    // ========================================================================
    // Helper Functions
    // ========================================================================
    
    function [4:0] get_error_state;
        input [4:0] state;
        begin
            case (state)
                AL_STATE_INIT:   get_error_state = AL_STATE_INIT_ERR;
                AL_STATE_PREOP:  get_error_state = AL_STATE_PREOP_ERR;
                AL_STATE_SAFEOP: get_error_state = AL_STATE_SAFEOP_ERR;
                default:         get_error_state = AL_STATE_INIT_ERR;
            endcase
        end
    endfunction

    // ========================================================================
    // SVA Formal Assertions (ETG.1000 Compliance)
    // ========================================================================
    `ifdef FORMAL
    
    // Valid states only
    property valid_state;
        @(posedge clk) disable iff (!rst_n)
        (current_state inside {AL_STATE_INIT, AL_STATE_PREOP, AL_STATE_BOOT,
                               AL_STATE_SAFEOP, AL_STATE_OP,
                               AL_STATE_INIT_ERR, AL_STATE_PREOP_ERR, AL_STATE_SAFEOP_ERR});
    endproperty
    assert property (valid_state) else $error("Invalid AL state detected");
    
    // After reset, state must be INIT
    property reset_to_init;
        @(posedge clk)
        (!rst_n) |=> (current_state == AL_STATE_INIT);
    endproperty
    assert property (reset_to_init) else $error("State not INIT after reset");
    
    // Valid transition: INIT can only go to PREOP or BOOT
    property init_transition;
        @(posedge clk) disable iff (!rst_n)
        (current_state == AL_STATE_INIT && current_state != $past(current_state)) |->
        ($past(current_state) == AL_STATE_PREOP || $past(current_state) == AL_STATE_BOOT ||
         $past(current_state) == AL_STATE_INIT_ERR);
    endproperty
    
    // OP state requires SAFEOP to be passed first
    property op_requires_safeop;
        @(posedge clk) disable iff (!rst_n)
        (current_state == AL_STATE_OP && $past(current_state) != AL_STATE_OP) |->
        ($past(current_state) == AL_STATE_SAFEOP);
    endproperty
    assert property (op_requires_safeop) else $error("OP entered without SAFEOP");
    
    // Error state must have non-zero status code
    property error_has_code;
        @(posedge clk) disable iff (!rst_n)
        (current_state[4] == 1'b1) |-> (al_status_code != AL_STATUS_NO_ERROR);
    endproperty
    assert property (error_has_code) else $error("Error state without status code");
    
    // SM/FMMU enable only in SAFEOP or OP
    property sm_enable_states;
        @(posedge clk) disable iff (!rst_n)
        (sm_enable) |-> (current_state inside {AL_STATE_SAFEOP, AL_STATE_OP});
    endproperty
    assert property (sm_enable_states) else $error("SM enabled in wrong state");
    
    // PDI disabled in INIT
    property pdi_disabled_init;
        @(posedge clk) disable iff (!rst_n)
        (current_state == AL_STATE_INIT) |-> (!pdi_enable);
    endproperty
    assert property (pdi_disabled_init) else $error("PDI enabled in INIT state");
    
    // Watchdog only in SAFEOP or OP
    property watchdog_states;
        @(posedge clk) disable iff (!rst_n)
        (watchdog_enable) |-> (current_state inside {AL_STATE_SAFEOP, AL_STATE_OP});
    endproperty
    assert property (watchdog_states) else $error("Watchdog enabled in wrong state");
    
    // Cover property: Reach OP state
    cover property (@(posedge clk) disable iff (!rst_n)
        (current_state == AL_STATE_OP));
    
    // Cover property: Full state sequence
    cover property (@(posedge clk) disable iff (!rst_n)
        (current_state == AL_STATE_INIT) ##[1:100]
        (current_state == AL_STATE_PREOP) ##[1:100]
        (current_state == AL_STATE_SAFEOP) ##[1:100]
        (current_state == AL_STATE_OP));
    
    `endif

endmodule
