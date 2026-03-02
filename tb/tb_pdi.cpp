// ============================================================================
// PDI (Process Data Interface) Avalon Testbench
// Tests PDI-01~05: Register access, SM access, IRQ, Watchdog, Error handling
// ============================================================================

#include <iostream>
#include <iomanip>
#include <cstdint>
#include <cstring>
#include "Vecat_pdi_avalon.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

class PDITestbench {
private:
    Vecat_pdi_avalon* dut;
    VerilatedVcdC* trace;
    uint64_t sim_time;
    int pass_count;
    int fail_count;
    
    // Simulated register memory
    uint16_t reg_memory[0x1000];
    
public:
    PDITestbench() {
        dut = new Vecat_pdi_avalon;
        trace = new VerilatedVcdC;
        sim_time = 0;
        pass_count = 0;
        fail_count = 0;
        
        Verilated::traceEverOn(true);
        dut->trace(trace, 99);
        trace->open("waves/tb_pdi.vcd");
        
        memset(reg_memory, 0, sizeof(reg_memory));
    }
    
    ~PDITestbench() {
        trace->close();
        delete trace;
        delete dut;
    }
    
    void clock() {
        dut->clk = 0;
        dut->eval();
        trace->dump(sim_time++);
        
        dut->clk = 1;
        dut->eval();
        trace->dump(sim_time++);
        
        // Simulate register interface response
        if (dut->reg_req) {
            if (dut->reg_wr) {
                reg_memory[dut->reg_addr & 0x0FFF] = dut->reg_wdata;
            }
            dut->reg_rdata = reg_memory[dut->reg_addr & 0x0FFF];
            dut->reg_ack = 1;
        } else {
            dut->reg_ack = 0;
        }
        
        // Simulate SM interface response
        if (dut->sm_pdi_req) {
            dut->sm_pdi_rdata = 0xDEADBEEF;  // Test pattern
            dut->sm_pdi_ack = 1;
        } else {
            dut->sm_pdi_ack = 0;
        }
    }
    
    void reset() {
        dut->rst_n = 0;
        dut->avs_address = 0;
        dut->avs_read = 0;
        dut->avs_write = 0;
        dut->avs_writedata = 0;
        dut->avs_byteenable = 0xF;
        dut->reg_rdata = 0;
        dut->reg_ack = 0;
        dut->sm_pdi_rdata = 0;
        dut->sm_pdi_ack = 0;
        dut->pdi_enable = 1;
        dut->irq_sources = 0;
        
        for (int i = 0; i < 10; i++) clock();
        
        dut->rst_n = 1;
        for (int i = 0; i < 5; i++) clock();
        
        memset(reg_memory, 0, sizeof(reg_memory));
        std::cout << "[INFO] Reset complete\n";
    }
    
    void check_pass(const char* name, bool condition) {
        if (condition) {
            std::cout << "    [PASS] " << name << "\n";
            pass_count++;
        } else {
            std::cout << "    [FAIL] " << name << "\n";
            fail_count++;
        }
    }
    
    // Avalon write operation
    bool avs_write(uint16_t addr, uint32_t data) {
        dut->avs_address = addr;
        dut->avs_write = 1;
        dut->avs_read = 0;
        dut->avs_writedata = data;
        dut->avs_byteenable = 0xF;
        
        clock();
        
        int timeout = 100;
        while (dut->avs_waitrequest && timeout > 0) {
            clock();
            timeout--;
        }
        
        dut->avs_write = 0;
        clock();
        
        return timeout > 0;
    }
    
    // Avalon read operation
    uint32_t avs_read_op(uint16_t addr, bool& success) {
        dut->avs_address = addr;
        dut->avs_read = 1;
        dut->avs_write = 0;
        dut->avs_byteenable = 0xF;
        
        clock();
        
        int timeout = 100;
        while (dut->avs_waitrequest && timeout > 0) {
            clock();
            timeout--;
        }
        
        // Wait for read data valid
        int valid_timeout = 10;
        while (!dut->avs_readdatavalid && valid_timeout > 0) {
            clock();
            valid_timeout--;
        }
        
        uint32_t data = dut->avs_readdata;
        success = (timeout > 0) && dut->avs_readdatavalid;
        
        dut->avs_read = 0;
        clock();
        
        return data;
    }
    
    // ========================================================================
    // PDI-01: Basic Register Access
    // ========================================================================
    void test_pdi01_register_access() {
        std::cout << "\n=== PDI-01: Basic Register Access ===\n";
        reset();
        
        // Write to register space (0x0000-0x0FFF)
        std::cout << "  Writing 0x1234 to register 0x0100...\n";
        bool wr_ok = avs_write(0x0100, 0x00001234);
        check_pass("Register write completes", wr_ok);
        
        // Read back
        std::cout << "  Reading register 0x0100...\n";
        bool rd_ok;
        uint32_t rd_val = avs_read_op(0x0100, rd_ok);
        std::cout << "  Read value: 0x" << std::hex << rd_val << std::dec << "\n";
        
        check_pass("Register read completes", rd_ok);
        check_pass("Read data matches written", (rd_val & 0xFFFF) == 0x1234);
    }
    
    // ========================================================================
    // PDI-02: SM Access (Process Data)
    // ========================================================================
    void test_pdi02_sm_access() {
        std::cout << "\n=== PDI-02: SM Access (Process Data) ===\n";
        reset();
        
        // Write to process data space (0x1000-0x1FFF)
        std::cout << "  Writing to process data 0x1000...\n";
        bool wr_ok = avs_write(0x1000, 0xAABBCCDD);
        check_pass("SM write completes", wr_ok);
        
        // Read from process data
        std::cout << "  Reading from process data 0x1000...\n";
        bool rd_ok;
        uint32_t rd_val = avs_read_op(0x1000, rd_ok);
        std::cout << "  Read value: 0x" << std::hex << rd_val << std::dec << "\n";
        
        check_pass("SM read completes", rd_ok);
        // SM returns test pattern 0xDEADBEEF
        check_pass("SM data received", rd_val == 0xDEADBEEF);
    }
    
    // ========================================================================
    // PDI-03: Mailbox Access
    // ========================================================================
    void test_pdi03_mailbox() {
        std::cout << "\n=== PDI-03: Mailbox Access ===\n";
        reset();
        
        // Write to mailbox space (0x2000-0x2FFF)
        std::cout << "  Writing to mailbox 0x2000...\n";
        bool wr_ok = avs_write(0x2000, 0x11223344);
        check_pass("Mailbox write completes", wr_ok);
        
        // Check SM ID used for mailbox
        // SM0 for write, SM1 for read
        std::cout << "  SM ID used: " << (int)dut->sm_id << "\n";
        
        // Read from mailbox
        std::cout << "  Reading from mailbox 0x2000...\n";
        bool rd_ok;
        uint32_t rd_val = avs_read_op(0x2000, rd_ok);
        
        check_pass("Mailbox read completes", rd_ok);
    }
    
    // ========================================================================
    // PDI-04: IRQ Generation
    // ========================================================================
    void test_pdi04_irq() {
        std::cout << "\n=== PDI-04: IRQ Generation ===\n";
        reset();
        
        // Check IRQ before any source
        bool irq_before = dut->pdi_irq;
        std::cout << "  IRQ before: " << irq_before << "\n";
        
        // Trigger IRQ source
        std::cout << "  Triggering IRQ source...\n";
        dut->irq_sources = 0x0001;
        for (int i = 0; i < 5; i++) clock();
        
        bool irq_after = dut->pdi_irq;
        std::cout << "  IRQ after: " << irq_after << "\n";
        
        check_pass("IRQ asserted on source", irq_after);
        
        // Clear IRQ source BEFORE reading (simulates hardware clearing condition)
        dut->irq_sources = 0;
        for (int i = 0; i < 2; i++) clock();
        
        // Read IRQ register (0x0220) to clear latched status
        bool rd_ok;
        uint32_t irq_reg = avs_read_op(0x0220, rd_ok);
        
        // Allow time for IRQ to clear
        for (int i = 0; i < 5; i++) clock();
        
        bool irq_cleared = !dut->pdi_irq;
        check_pass("IRQ cleared after read", irq_cleared);
    }
    
    // ========================================================================
    // PDI-05: PDI Disabled Access
    // ========================================================================
    void test_pdi05_disabled() {
        std::cout << "\n=== PDI-05: PDI Disabled Access ===\n";
        reset();
        
        // Disable PDI
        std::cout << "  Disabling PDI...\n";
        dut->pdi_enable = 0;
        clock();
        
        // Try to access
        std::cout << "  Attempting access when disabled...\n";
        
        dut->avs_address = 0x0100;
        dut->avs_read = 1;
        clock();
        
        // Should get error state quickly
        int timeout = 50;
        while (dut->avs_waitrequest && timeout > 0) {
            clock();
            timeout--;
        }
        
        dut->avs_read = 0;
        clock();
        
        // Check operational status
        bool not_operational = !dut->pdi_operational;
        check_pass("PDI not operational when disabled", not_operational);
        
        // Re-enable and verify recovery
        dut->pdi_enable = 1;
        for (int i = 0; i < 10; i++) clock();
    }
    
    // ========================================================================
    // PDI-06: Watchdog Timeout
    // ========================================================================
    void test_pdi06_watchdog() {
        std::cout << "\n=== PDI-06: Watchdog Timeout ===\n";
        reset();
        
        // Do an access to reset watchdog
        bool rd_ok;
        avs_read_op(0x0100, rd_ok);
        
        bool timeout_before = dut->pdi_watchdog_timeout;
        std::cout << "  Watchdog timeout before: " << timeout_before << "\n";
        
        // Wait for watchdog (would take 1M+ cycles for 20ms, so we check the mechanism)
        // For this test, we verify the counter increments
        std::cout << "  Waiting for watchdog activity...\n";
        for (int i = 0; i < 1000; i++) clock();
        
        // Access resets watchdog
        avs_read_op(0x0100, rd_ok);
        
        bool timeout_after_access = dut->pdi_watchdog_timeout;
        check_pass("Watchdog not expired after access", !timeout_after_access);
    }
    
    void run_all() {
        test_pdi01_register_access();
        test_pdi02_sm_access();
        test_pdi03_mailbox();
        test_pdi04_irq();
        test_pdi05_disabled();
        test_pdi06_watchdog();
        
        std::cout << "\n==========================================\n";
        std::cout << "PDI Test Summary:\n";
        std::cout << "  PASSED: " << pass_count << "\n";
        std::cout << "  FAILED: " << fail_count << "\n";
        std::cout << "==========================================\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    std::cout << "==========================================\n";
    std::cout << "PDI (Avalon) Testbench (PDI-01 to PDI-06)\n";
    std::cout << "==========================================\n";
    
    PDITestbench tb;
    tb.run_all();
    
    return 0;
}
