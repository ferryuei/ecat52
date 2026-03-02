// ============================================================================
// FMMU Testbench
// Tests FMMU-01~04: Basic Mapping, Bit-Level, Multi-FMMU, Disabled
// ============================================================================

#include <iostream>
#include <iomanip>
#include <cstdint>
#include <cstring>
#include "Vecat_fmmu.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

class FMMUTestbench {
private:
    Vecat_fmmu* dut;
    VerilatedVcdC* trace;
    uint64_t sim_time;
    int pass_count;
    int fail_count;
    
    // Simulated physical memory
    uint8_t phy_memory[65536];
    
public:
    FMMUTestbench() {
        dut = new Vecat_fmmu;
        trace = new VerilatedVcdC;
        sim_time = 0;
        pass_count = 0;
        fail_count = 0;
        
        Verilated::traceEverOn(true);
        dut->trace(trace, 99);
        trace->open("waves/tb_fmmu.vcd");
        
        memset(phy_memory, 0, sizeof(phy_memory));
    }
    
    ~FMMUTestbench() {
        trace->close();
        delete trace;
        delete dut;
    }
    
    void clock() {
        dut->clk = 0;
        dut->cfg_clk = 0;
        dut->eval();
        trace->dump(sim_time++);
        
        dut->clk = 1;
        dut->cfg_clk = 1;
        dut->eval();
        trace->dump(sim_time++);
        
        // Handle physical memory interface
        if (dut->phy_req) {
            if (dut->phy_wr) {
                phy_memory[dut->phy_addr] = dut->phy_wdata & 0xFF;
            }
            dut->phy_rdata = phy_memory[dut->phy_addr];
            dut->phy_ack = 1;
        } else {
            dut->phy_ack = 0;
        }
    }
    
    void reset() {
        dut->rst_n = 0;
        dut->cfg_wr = 0;
        dut->cfg_addr = 0;
        dut->cfg_wdata = 0;
        dut->log_req = 0;
        dut->log_addr = 0;
        dut->log_len = 0;
        dut->log_wr = 0;
        dut->log_wdata = 0;
        dut->phy_ack = 0;
        dut->phy_rdata = 0;
        for (int i = 0; i < 8; i++) dut->feature_vector[i] = 0;
        
        for (int i = 0; i < 10; i++) clock();
        
        dut->rst_n = 1;
        for (int i = 0; i < 5; i++) clock();
        
        memset(phy_memory, 0, sizeof(phy_memory));
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
    
    // Configure FMMU register
    void cfg_write(uint8_t addr, uint32_t data) {
        dut->cfg_wr = 1;
        dut->cfg_addr = addr;
        dut->cfg_wdata = data;
        clock();
        dut->cfg_wr = 0;
        clock();
    }
    
    // Logical write operation
    bool log_write(uint32_t addr, uint32_t data) {
        dut->log_req = 1;
        dut->log_addr = addr;
        dut->log_wr = 1;
        dut->log_wdata = data;
        dut->log_len = 1;
        
        int timeout = 100;
        while (!dut->log_ack && !dut->log_err && timeout > 0) {
            clock();
            timeout--;
        }
        
        bool success = dut->log_ack && !dut->log_err;
        dut->log_req = 0;
        clock();
        return success;
    }
    
    // ========================================================================
    // FMMU-01: Basic Logical Mapping
    // ========================================================================
    void test_fmmu01_basic_mapping() {
        std::cout << "\n=== FMMU-01: Basic Logical Mapping ===\n";
        reset();
        
        // Configure FMMU: logical 0x10000 -> physical 0x1000
        std::cout << "  Configuring FMMU: logical 0x10000 -> physical 0x1000...\n";
        cfg_write(0x00, 0x00010000);  // Logical start addr
        cfg_write(0x04, 0x0010);       // Length = 16 bytes
        cfg_write(0x08, 0x1000);       // Physical start addr
        cfg_write(0x0B, 0x02);         // Type = write
        cfg_write(0x0C, 0x01);         // Activate
        
        clock(); clock();
        
        // Write to logical address
        std::cout << "  Writing 0xAB to logical 0x10000...\n";
        bool success = log_write(0x10000, 0xAB);
        
        std::cout << "  Physical memory[0x1000] = 0x" << std::hex 
                  << (int)phy_memory[0x1000] << std::dec << "\n";
        
        check_pass("Logical write succeeded", success);
        check_pass("Physical RAM 0x1000 updated", phy_memory[0x1000] == 0xAB);
    }
    
    // ========================================================================
    // FMMU-02: Bit-Level Mapping
    // ========================================================================
    void test_fmmu02_bit_mapping() {
        std::cout << "\n=== FMMU-02: Bit-Level Mapping ===\n";
        reset();
        
        // Configure FMMU with bit mask (only bit 0)
        std::cout << "  Configuring FMMU with bit mask (bit 0 only)...\n";
        cfg_write(0x00, 0x00020000);  // Logical start addr
        cfg_write(0x04, 0x0001);       // Length = 1 byte
        cfg_write(0x06, 0x00);         // Logical start bit = 0
        cfg_write(0x07, 0x00);         // Logical stop bit = 0 (only bit 0)
        cfg_write(0x08, 0x2000);       // Physical start addr
        cfg_write(0x0A, 0x00);         // Physical start bit = 0
        cfg_write(0x0B, 0x02);         // Type = write
        cfg_write(0x0C, 0x01);         // Activate
        
        clock(); clock();
        
        // Physical RAM original value = 0x00
        phy_memory[0x2000] = 0x00;
        
        // Write 0xFF to logical address (all 1s)
        std::cout << "  Writing 0xFF to logical 0x20000...\n";
        bool success = log_write(0x20000, 0xFF);
        
        std::cout << "  Physical value: 0x" << std::hex 
                  << (int)phy_memory[0x2000] << std::dec << "\n";
        
        check_pass("Logical write succeeded", success);
        // With bit mask, only bit 0 should be modified
        check_pass("Only bit 0 modified (value=0x01)", phy_memory[0x2000] == 0x01);
    }
    
    // ========================================================================
    // FMMU-03: Multi-FMMU / Sequential Mapping
    // ========================================================================
    void test_fmmu03_multi_fmmu() {
        std::cout << "\n=== FMMU-03: Multi-FMMU / Sequential Mapping ===\n";
        reset();
        
        // Configure FMMU for sequential address mapping
        cfg_write(0x00, 0x00030000);  // Logical start addr
        cfg_write(0x04, 0x0010);       // Length = 16 bytes
        cfg_write(0x08, 0x3000);       // Physical start addr
        cfg_write(0x0B, 0x02);         // Type = write
        cfg_write(0x0C, 0x01);         // Activate
        
        clock(); clock();
        
        // Write to multiple sequential addresses
        std::cout << "  Writing to sequential logical addresses...\n";
        log_write(0x30000, 0x11);
        log_write(0x30001, 0x22);
        log_write(0x30002, 0x33);
        log_write(0x30003, 0x44);
        
        std::cout << "  Physical memory: [0x3000]=0x" << std::hex 
                  << (int)phy_memory[0x3000]
                  << " [0x3001]=0x" << (int)phy_memory[0x3001]
                  << " [0x3002]=0x" << (int)phy_memory[0x3002]
                  << " [0x3003]=0x" << (int)phy_memory[0x3003] << std::dec << "\n";
        
        check_pass("Sequential addr 0 mapped", phy_memory[0x3000] == 0x11);
        check_pass("Sequential addr 1 mapped", phy_memory[0x3001] == 0x22);
        check_pass("Sequential addr 2 mapped", phy_memory[0x3002] == 0x33);
        check_pass("Sequential addr 3 mapped", phy_memory[0x3003] == 0x44);
    }
    
    // ========================================================================
    // FMMU-04: Disabled FMMU Access
    // ========================================================================
    void test_fmmu04_disabled() {
        std::cout << "\n=== FMMU-04: Disabled FMMU Access ===\n";
        reset();
        
        // Configure but don't activate
        std::cout << "  Configuring FMMU but NOT activating...\n";
        cfg_write(0x00, 0x00040000);  // Logical start addr
        cfg_write(0x04, 0x0010);       // Length
        cfg_write(0x08, 0x4000);       // Physical start addr
        cfg_write(0x0B, 0x02);         // Type = write
        cfg_write(0x0C, 0x00);         // NOT activated!
        
        clock(); clock();
        
        // Set physical memory to known value
        phy_memory[0x4000] = 0xBB;
        
        // Try to write
        std::cout << "  Attempting logical write to disabled FMMU...\n";
        
        dut->log_req = 1;
        dut->log_addr = 0x40000;
        dut->log_wr = 1;
        dut->log_wdata = 0xCC;
        dut->log_len = 1;
        
        // Should not get ack (FMMU disabled)
        for (int i = 0; i < 20; i++) clock();
        
        bool no_ack = !dut->log_ack;
        dut->log_req = 0;
        clock();
        
        std::cout << "  Physical memory[0x4000] = 0x" << std::hex 
                  << (int)phy_memory[0x4000] << std::dec << "\n";
        
        check_pass("No ACK for disabled FMMU", no_ack);
        check_pass("Physical RAM unchanged", phy_memory[0x4000] == 0xBB);
    }
    
    void run_all() {
        test_fmmu01_basic_mapping();
        test_fmmu02_bit_mapping();
        test_fmmu03_multi_fmmu();
        test_fmmu04_disabled();
        
        std::cout << "\n==========================================\n";
        std::cout << "FMMU Test Summary:\n";
        std::cout << "  PASSED: " << pass_count << "\n";
        std::cout << "  FAILED: " << fail_count << "\n";
        std::cout << "==========================================\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    std::cout << "==========================================\n";
    std::cout << "FMMU Testbench (FMMU-01 to FMMU-04)\n";
    std::cout << "==========================================\n";
    
    FMMUTestbench tb;
    tb.run_all();
    
    return 0;
}
