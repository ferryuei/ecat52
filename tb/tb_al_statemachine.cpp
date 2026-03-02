
// ============================================================================
// Verilator Testbench for AL State Machine
// Tests state transitions and error handling
// ============================================================================

#include <verilated.h>
#include "Vecat_al_statemachine.h"
#include <iostream>

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

class ALStateMachineTB {
private:
    Vecat_al_statemachine* dut;
    
public:
    ALStateMachineTB() {
        dut = new Vecat_al_statemachine;
        dut->rst_n = 0;
        dut->clk = 0;
        dut->al_control_req = 0x01;  // Init (5-bit)
        dut->al_control_changed = 0;
        dut->sm_activate = 0;
        dut->sm_error = 0;
        dut->fmmu_activate = 0;
        dut->pdi_operational = 1;
        dut->pdi_watchdog_timeout = 0;
        dut->dc_sync_active = 0;
        dut->dc_sync_error = 0;
        dut->eeprom_loaded = 1;
        dut->eeprom_error = 0;
        dut->port_link_status = 0x03;  // Port 0,1 up
    }
    
    ~ALStateMachineTB() {
        dut->final();
        delete dut;
    }
    
    void clock() {
        dut->clk = 0;
        dut->eval();
        main_time++;
        dut->clk = 1;
        dut->eval();
        main_time++;
    }
    
    void reset() {
        dut->rst_n = 0;
        for (int i = 0; i < 10; i++) clock();
        dut->rst_n = 1;
        clock();
        std::cout << "[INFO] Reset complete, AL State = 0x" 
                  << std::hex << (int)dut->al_status << std::dec << "\n";
    }
    
    void request_state(uint8_t state, const char* name) {
        std::cout << "\n[TEST] Requesting " << name << " state (0x" 
                  << std::hex << (int)state << ")\n";
        dut->al_control_req = state;
        dut->al_control_changed = 1;
        clock();
        dut->al_control_changed = 0;
        
        // Wait for transition
        for (int i = 0; i < 20; i++) {
            clock();
            if (dut->al_event_irq) {
                std::cout << "  [IRQ] State changed to 0x" 
                          << std::hex << (int)dut->al_status;
                if (dut->al_status_code != 0) {
                    std::cout << " (Error: 0x" << dut->al_status_code << ")";
                }
                std::cout << std::dec << "\n";
            }
        }
        
        std::cout << "  Current state: 0x" << std::hex << (int)dut->al_status << std::dec << "\n";
        std::cout << "  SM enable: " << (int)dut->sm_enable << "\n";
        std::cout << "  FMMU enable: " << (int)dut->fmmu_enable << "\n";
        std::cout << "  PDI enable: " << (int)dut->pdi_enable << "\n";
    }
    
    void test_normal_transitions() {
        std::cout << "\n=== TEST: Normal State Transitions ===\n";
        
        // Init → Pre-Op
        request_state(0x02, "Pre-Op");
        
        // Pre-Op → Safe-Op (need SM configured)
        dut->sm_activate = 0x0F;  // Enable SM 0-3
        clock();
        request_state(0x04, "Safe-Op");
        
        // Safe-Op → Op
        request_state(0x08, "Op");
        
        // Op → Safe-Op
        request_state(0x04, "Safe-Op (back)");
        
        // Safe-Op → Init
        request_state(0x01, "Init");
    }
    
    void test_error_conditions() {
        std::cout << "\n=== TEST: Error Conditions ===\n";
        
        // Try to go to Safe-Op without SM configured
        dut->sm_activate = 0x00;
        request_state(0x02, "Pre-Op");
        request_state(0x04, "Safe-Op (should fail)");
        
        // Try with SM error
        dut->sm_activate = 0x0F;
        dut->sm_error = 0x01;
        request_state(0x04, "Safe-Op (with SM error)");
        
        // Clear error and retry
        dut->sm_error = 0x00;
        request_state(0x01, "Init (recover)");
        request_state(0x02, "Pre-Op");
        request_state(0x04, "Safe-Op (retry)");
    }
    
    void test_watchdog_timeout() {
        std::cout << "\n=== TEST: Watchdog Timeout ===\n";
        
        request_state(0x02, "Pre-Op");
        dut->sm_activate = 0x0F;
        request_state(0x04, "Safe-Op");
        
        // Trigger watchdog timeout
        std::cout << "  Triggering watchdog timeout...\n";
        dut->pdi_watchdog_timeout = 1;
        for (int i = 0; i < 10; i++) {
            clock();
            if (dut->al_event_irq) {
                std::cout << "  [IRQ] Watchdog error detected!\n";
                std::cout << "  AL Status Code: 0x" << std::hex 
                          << dut->al_status_code << std::dec << "\n";
            }
        }
    }
    
    void run_all_tests() {
        std::cout << "========================================\n";
        std::cout << "AL State Machine Testbench\n";
        std::cout << "========================================\n";
        
        reset();
        test_normal_transitions();
        
        reset();
        test_error_conditions();
        
        reset();
        test_watchdog_timeout();
        
        std::cout << "\n========================================\n";
        std::cout << "All tests complete!\n";
        std::cout << "========================================\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    ALStateMachineTB* tb = new ALStateMachineTB();
    tb->run_all_tests();
    
    delete tb;
    return 0;
}
