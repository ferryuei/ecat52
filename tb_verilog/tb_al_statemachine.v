// ============================================================================
// AL State Machine Testbench (Pure Verilog-2001)
// Tests state transitions and error handling
// Compatible with: iverilog, VCS, Verilator
// ============================================================================

`timescale 1ns/1ps

module tb_al_statemachine;

// ============================================================================
// Parameters
// ============================================================================
parameter CLK_PERIOD = 10;

// AL State definitions
parameter AL_STATE_INIT   = 5'h01;
parameter AL_STATE_PREOP  = 5'h02;
parameter AL_STATE_BOOT   = 5'h03;
parameter AL_STATE_SAFEOP = 5'h04;
parameter AL_STATE_OP     = 5'h08;
// Error states
parameter AL_STATE_INIT_ERR   = 5'h11;
parameter AL_STATE_PREOP_ERR  = 5'h12;
parameter AL_STATE_SAFEOP_ERR = 5'h14;
// AL Status codes
parameter AL_STATUS_NO_ERROR        = 16'h0000;
parameter AL_STATUS_INVALID_SETUP   = 16'h0004;
parameter AL_STATUS_DC_NOT_SYNC     = 16'h0030;

// ============================================================================
// Test Signals
// ============================================================================
reg                     clk;
reg                     rst_n;

// AL Control
reg  [4:0]              al_control_req;
reg                     al_control_changed;

// AL Status
wire [4:0]              al_status;
wire [15:0]             al_status_code;

// SM/FMMU status
reg  [7:0]              sm_activate;
reg  [7:0]              sm_error;
reg  [7:0]              fmmu_activate;

// PDI status
reg                     pdi_operational;
reg                     pdi_watchdog_timeout;

// DC status
reg                     dc_sync_active;
reg                     dc_sync_error;

// EEPROM status
reg                     eeprom_loaded;
reg                     eeprom_error;

// Link status
reg  [3:0]              port_link_status;

// Control outputs
wire                    sm_enable;
wire                    fmmu_enable;
wire                    pdi_enable;
wire                    watchdog_enable;

// IRQ
wire                    al_event_irq;

// Test counters
integer pass_count;
integer fail_count;
integer i;

// ============================================================================
// DUT Instantiation
// ============================================================================
ecat_al_statemachine dut (
    .clk(clk),
    .rst_n(rst_n),
    .al_control_req(al_control_req),
    .al_control_changed(al_control_changed),
    .al_status(al_status),
    .al_status_code(al_status_code),
    .sm_activate(sm_activate),
    .sm_error(sm_error),
    .fmmu_activate(fmmu_activate),
    .pdi_operational(pdi_operational),
    .pdi_watchdog_timeout(pdi_watchdog_timeout),
    .dc_sync_active(dc_sync_active),
    .dc_sync_error(dc_sync_error),
    .eeprom_loaded(eeprom_loaded),
    .eeprom_error(eeprom_error),
    .port_link_status(port_link_status),
    .sm_enable(sm_enable),
    .fmmu_enable(fmmu_enable),
    .pdi_enable(pdi_enable),
    .watchdog_enable(watchdog_enable),
    .al_event_irq(al_event_irq)
);

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// ============================================================================
// VCD Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_al_statemachine.vcd");
    $dumpvars(0, tb_al_statemachine);
end

// ============================================================================
// Tasks: Check Pass/Fail
// ============================================================================
task check_pass;
    input [255:0] name;
    input condition;
    begin
        if (condition) begin
            $display("    [PASS] %0s", name);
            pass_count = pass_count + 1;
        end else begin
            $display("    [FAIL] %0s", name);
            fail_count = fail_count + 1;
        end
    end
endtask

// ============================================================================
// Tasks: Reset
// ============================================================================
task reset_dut;
    begin
        rst_n = 0;
        al_control_req = AL_STATE_INIT;
        al_control_changed = 0;
        sm_activate = 0;
        sm_error = 0;
        fmmu_activate = 0;
        pdi_operational = 1;
        pdi_watchdog_timeout = 0;
        dc_sync_active = 0;
        dc_sync_error = 0;
        eeprom_loaded = 1;
        eeprom_error = 0;
        port_link_status = 4'h3;
        
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[INFO] Reset complete, AL State = 0x%02x", al_status);
    end
endtask

// ============================================================================
// Tasks: Request State
// ============================================================================
task request_state;
    input [4:0] state;
    input [127:0] name;
    begin
        $display("\n[TEST] Requesting %0s state (0x%02x)", name, state);
        al_control_req = state;
        al_control_changed = 1;
        @(posedge clk);
        al_control_changed = 0;
        
        // Wait for transition and check for IRQ
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            if (al_event_irq) begin
                $display("  [IRQ] State changed to 0x%02x", al_status);
                if (al_status_code != 16'h0000)
                    $display("        Error code: 0x%04x", al_status_code);
            end
        end
        
        $display("  Current state: 0x%02x", al_status);
        $display("  SM enable: %0d, FMMU enable: %0d, PDI enable: %0d", 
                 sm_enable, fmmu_enable, pdi_enable);
    end
endtask

// ============================================================================
// Test: BOOT State Transition
// ============================================================================
task test_boot_state;
    begin
        $display("\n=== TEST: BOOT State Transition ===");
        reset_dut;

        // INIT -> BOOT (always allowed per spec)
        request_state(AL_STATE_BOOT, "Boot");
        $display("  AL status after BOOT request: 0x%02x", al_status);
        check_pass("INIT -> BOOT transition", al_status == AL_STATE_BOOT);

        // BOOT -> INIT
        request_state(AL_STATE_INIT, "Init (from Boot)");
        check_pass("BOOT -> INIT transition", al_status == AL_STATE_INIT);
    end
endtask

// ============================================================================
// Test: DC Sync Error in OP
// ============================================================================
task test_dc_sync_error;
    begin
        $display("\n=== TEST: DC Sync Error in OP State ===");
        reset_dut;

        // Reach OP state
        request_state(AL_STATE_PREOP, "Pre-Op");
        sm_activate = 8'h0F;
        request_state(AL_STATE_SAFEOP, "Safe-Op");
        request_state(AL_STATE_OP, "Op");
        check_pass("Reached OP", al_status == AL_STATE_OP);

        // Inject DC sync error
        $display("  Injecting DC sync error...");
        dc_sync_active = 1;
        dc_sync_error  = 1;
        repeat(5) @(posedge clk);

        $display("  AL status code: 0x%04x (expected 0x0030)", al_status_code);
        check_pass("DC sync error code set", al_status_code == AL_STATUS_DC_NOT_SYNC);

        dc_sync_active = 0;
        dc_sync_error  = 0;
        request_state(AL_STATE_INIT, "Init (recover)");
    end
endtask

// ============================================================================
// Test: EEPROM Error Detection
// ============================================================================
task test_eeprom_error;
    begin
        $display("\n=== TEST: EEPROM Error Detection ===");
        reset_dut;

        // Reach PREOP
        request_state(AL_STATE_PREOP, "Pre-Op");
        check_pass("Reached PREOP", al_status == AL_STATE_PREOP);

        // Inject EEPROM error while in PREOP
        $display("  Injecting EEPROM error...");
        eeprom_loaded = 0;
        eeprom_error  = 1;
        repeat(5) @(posedge clk);

        $display("  AL status code: 0x%04x (expected 0x0004)", al_status_code);
        check_pass("EEPROM error code set", al_status_code == AL_STATUS_INVALID_SETUP);

        // Recover
        eeprom_loaded = 1;
        eeprom_error  = 0;
        request_state(AL_STATE_INIT, "Init (recover)");
    end
endtask

// ============================================================================
// Test: PREOP_ERR / SAFEOP_ERR via SM error during transition
// ============================================================================
task test_error_states;
    begin
        $display("\n=== TEST: Error State Entry (SAFEOP_ERR) ===");
        reset_dut;

        request_state(AL_STATE_PREOP, "Pre-Op");

        // SM error present during SAFEOP attempt
        sm_activate = 8'h0F;
        sm_error    = 8'h01;
        request_state(AL_STATE_SAFEOP, "Safe-Op (with SM error)");

        $display("  AL status after error transition: 0x%02x", al_status);
        $display("  AL status code: 0x%04x", al_status_code);
        check_pass("Error state entered or rejected",
                   al_status != AL_STATE_SAFEOP || al_status_code != AL_STATUS_NO_ERROR);

        // Check for SAFEOP_ERR or PREOP_ERR
        check_pass("Error code non-zero on SM error",
                   al_status_code != AL_STATUS_NO_ERROR ||
                   al_status == AL_STATE_SAFEOP_ERR || al_status == AL_STATE_PREOP_ERR ||
                   al_status == AL_STATE_INIT_ERR);

        sm_error = 8'h00;
        request_state(AL_STATE_INIT, "Init (recover)");
        check_pass("Recovery to INIT", al_status == AL_STATE_INIT);
    end
endtask

// ============================================================================
// Test: Normal State Transitions
// ============================================================================
task test_normal_transitions;
    begin
        $display("\n=== TEST: Normal State Transitions ===");
        
        // Init -> Pre-Op
        request_state(AL_STATE_PREOP, "Pre-Op");
        check_pass("Init -> Pre-Op", al_status == AL_STATE_PREOP);
        
        // Pre-Op -> Safe-Op (need SM configured)
        sm_activate = 8'h0F;  // Enable SM 0-3
        @(posedge clk);
        request_state(AL_STATE_SAFEOP, "Safe-Op");
        check_pass("Pre-Op -> Safe-Op", al_status == AL_STATE_SAFEOP);
        
        // Safe-Op -> Op
        request_state(AL_STATE_OP, "Op");
        check_pass("Safe-Op -> Op", al_status == AL_STATE_OP);
        
        // Op -> Safe-Op
        request_state(AL_STATE_SAFEOP, "Safe-Op (back)");
        check_pass("Op -> Safe-Op", al_status == AL_STATE_SAFEOP);
        
        // Safe-Op -> Init
        request_state(AL_STATE_INIT, "Init");
        check_pass("Safe-Op -> Init", al_status == AL_STATE_INIT);
    end
endtask

// ============================================================================
// Test: Error Conditions
// ============================================================================
task test_error_conditions;
    begin
        $display("\n=== TEST: Error Conditions ===");
        
        // Try to go to Safe-Op without SM configured
        sm_activate = 8'h00;
        request_state(AL_STATE_PREOP, "Pre-Op");
        request_state(AL_STATE_SAFEOP, "Safe-Op (no SM)");
        // Should fail or enter error state
        check_pass("Reject Safe-Op without SM", 
                   al_status != AL_STATE_SAFEOP || al_status_code != 16'h0000);
        
        // Try with SM error
        sm_activate = 8'h0F;
        sm_error = 8'h01;
        request_state(AL_STATE_SAFEOP, "Safe-Op (SM error)");
        
        // Clear error and retry
        sm_error = 8'h00;
        request_state(AL_STATE_INIT, "Init (recover)");
        request_state(AL_STATE_PREOP, "Pre-Op");
        request_state(AL_STATE_SAFEOP, "Safe-Op (retry)");
        check_pass("Recovery after error", al_status == AL_STATE_SAFEOP);
    end
endtask

// ============================================================================
// Test: Watchdog Timeout
// ============================================================================
task test_watchdog_timeout;
    begin
        $display("\n=== TEST: Watchdog Timeout ===");
        
        request_state(AL_STATE_PREOP, "Pre-Op");
        sm_activate = 8'h0F;
        request_state(AL_STATE_SAFEOP, "Safe-Op");
        
        // Trigger watchdog timeout
        $display("  Triggering watchdog timeout...");
        pdi_watchdog_timeout = 1;
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            if (al_event_irq) begin
                $display("  [IRQ] Watchdog error detected!");
                $display("        AL Status Code: 0x%04x", al_status_code);
            end
        end
        
        check_pass("Watchdog handled", al_status_code != 16'h0000 || al_status != AL_STATE_SAFEOP);
        
        pdi_watchdog_timeout = 0;
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    pass_count = 0;
    fail_count = 0;
    
    $display("========================================");
    $display("AL State Machine Testbench");
    $display("========================================");
    
    reset_dut;
    test_normal_transitions;
    
    reset_dut;
    test_error_conditions;
    
    reset_dut;
    test_watchdog_timeout;

    reset_dut;
    test_boot_state;

    reset_dut;
    test_dc_sync_error;

    reset_dut;
    test_eeprom_error;

    reset_dut;
    test_error_states;
    
    // Summary
    $display("\n========================================");
    $display("AL State Machine Test Summary:");
    $display("  PASSED: %0d", pass_count);
    $display("  FAILED: %0d", fail_count);
    $display("========================================");
    
    if (fail_count > 0)
        $display("TEST FAILED");
    else
        $display("TEST PASSED");
    
    $finish;
end

endmodule
