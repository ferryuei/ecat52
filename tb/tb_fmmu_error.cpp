// ============================================================================
// EtherCAT FMMU Error Detection Testbench
// Tests FMMU error codes per ETG.1000 Section 6.7.6
// ============================================================================

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vecat_fmmu.h"
#include <iostream>
#include <iomanip>
#include <cstring>

class FMMUErrorTB {
public:
    Vecat_fmmu* dut;
    VerilatedVcdC* trace;
    uint64_t sim_time;
    int test_passed;
    int test_failed;
    
    FMMUErrorTB() {
        dut = new Vecat_fmmu;
        trace = nullptr;
        sim_time = 0;
        test_passed = 0;
        test_failed = 0;
    }
    
    ~FMMUErrorTB() {
        if (trace) {
            trace->close();
            delete trace;
        }
        delete dut;
    }
    
    void enable_trace(const char* filename) {
        Verilated::traceEverOn(true);
        trace = new VerilatedVcdC;
        dut->trace(trace, 99);
        trace->open(filename);
    }
    
    void tick() {
        dut->clk = 0;
        dut->cfg_clk = 0;
        dut->eval();
        if (trace) trace->dump(sim_time++);
        
        dut->clk = 1;
        dut->cfg_clk = 1;
        dut->eval();
        if (trace) trace->dump(sim_time++);
    }
    
    void reset() {
        dut->rst_n = 0;
        dut->cfg_clk = 0;
        // feature_vector is 256-bit (VlWide<8>), zero each 32-bit chunk
        for (int i = 0; i < 8; i++) dut->feature_vector[i] = 0;
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
        
        for (int i = 0; i < 10; i++) tick();
        
        dut->rst_n = 1;
        tick();
    }
    
    // Configure FMMU
    void configure_fmmu(uint32_t log_start, uint16_t length, uint16_t phy_start, uint8_t type) {
        // Write logical start address
        dut->cfg_wr = 1;
        dut->cfg_addr = 0x00;
        dut->cfg_wdata = log_start;
        tick();
        
        // Write length
        dut->cfg_addr = 0x04;
        dut->cfg_wdata = length;
        tick();
        
        // Write physical start address
        dut->cfg_addr = 0x08;
        dut->cfg_wdata = phy_start;
        tick();
        
        // Write type (01=read, 02=write, 03=rw)
        dut->cfg_addr = 0x0B;
        dut->cfg_wdata = type;
        tick();
        
        // Activate FMMU
        dut->cfg_addr = 0x0C;
        dut->cfg_wdata = 0x01;
        tick();
        
        dut->cfg_wr = 0;
        tick();
    }
    
    // Attempt logical access
    bool logical_access(uint32_t addr, bool write, bool debug = false) {
        dut->log_req = 1;
        dut->log_addr = addr;
        dut->log_wr = write ? 1 : 0;
        dut->log_wdata = 0xDEADBEEF;
        tick();
        dut->log_req = 0;
        
        if (debug) {
            std::cout << "  After req: log_ack=" << (int)dut->log_ack 
                      << " log_err=" << (int)dut->log_err
                      << " fmmu_error=" << (int)dut->fmmu_error
                      << " error_code=0x" << std::hex << (int)dut->fmmu_error_code << std::dec << std::endl;
        }
        
        // Wait for ack or error
        int timeout = 50;
        while (!dut->log_ack && !dut->log_err && timeout-- > 0) {
            // Simulate physical memory ack
            if (dut->phy_req) {
                dut->phy_ack = 1;
                dut->phy_rdata = 0x12345678;
            }
            tick();
            dut->phy_ack = 0;
            
            if (debug) {
                std::cout << "  Wait loop: log_ack=" << (int)dut->log_ack 
                          << " log_err=" << (int)dut->log_err
                          << " phy_req=" << (int)dut->phy_req
                          << " fmmu_error=" << (int)dut->fmmu_error
                          << " error_code=0x" << std::hex << (int)dut->fmmu_error_code << std::dec << std::endl;
            }
        }
        
        return dut->log_ack && !dut->log_err;
    }
    
    void check(bool condition, const char* test_name) {
        if (condition) {
            std::cout << "[PASS] " << test_name << std::endl;
            test_passed++;
        } else {
            std::cout << "[FAIL] " << test_name << std::endl;
            test_failed++;
        }
    }
    
    // ========================================================================
    // Test Cases
    // ========================================================================
    
    void test_no_error_on_valid_access() {
        std::cout << "\n=== Test: No Error on Valid Access ===" << std::endl;
        reset();
        
        // Configure FMMU: log 0x1000-0x10FF -> phy 0x0000, read/write
        configure_fmmu(0x00001000, 0x0100, 0x0000, 0x03);
        
        // Access within range
        bool success = logical_access(0x00001050, false);
        
        check(success, "Valid read access succeeds");
        check(dut->fmmu_error == 0, "No error flag");
        check(dut->fmmu_error_code == 0, "Error code is zero");
        
        std::cout << "  Error code: 0x" << std::hex << (int)dut->fmmu_error_code << std::dec << std::endl;
    }
    
    void test_type_mismatch_write_to_readonly() {
        std::cout << "\n=== Test: Type Mismatch - Write to Read-Only ===" << std::endl;
        reset();
        
        // Configure FMMU: log 0x1000-0x10FF -> phy 0x0000, read-only (type=01)
        configure_fmmu(0x00001000, 0x0100, 0x0000, 0x01);
        
        // Attempt write (should fail)
        bool success = logical_access(0x00001050, true);
        
        check(!success, "Write to read-only FMMU fails");
        check(dut->fmmu_error == 1, "Error flag set");
        check((dut->fmmu_error_code & 0x10) != 0, "Type mismatch error (bit 4)");
        
        std::cout << "  Error code: 0x" << std::hex << (int)dut->fmmu_error_code << std::dec << std::endl;
    }
    
    void test_type_mismatch_read_from_writeonly() {
        std::cout << "\n=== Test: Type Mismatch - Read from Write-Only ===" << std::endl;
        reset();
        
        // Configure FMMU: log 0x2000-0x20FF -> phy 0x0100, write-only (type=02)
        configure_fmmu(0x00002000, 0x0100, 0x0100, 0x02);
        
        // Attempt read (should fail)
        bool success = logical_access(0x00002050, false);
        
        check(!success, "Read from write-only FMMU fails");
        check(dut->fmmu_error == 1, "Error flag set");
        check((dut->fmmu_error_code & 0x10) != 0, "Type mismatch error (bit 4)");
        
        std::cout << "  Error code: 0x" << std::hex << (int)dut->fmmu_error_code << std::dec << std::endl;
    }
    
    void test_address_out_of_range() {
        std::cout << "\n=== Test: Address Out of Range ===" << std::endl;
        reset();
        
        // Configure FMMU: log 0x3000-0x30FF -> phy 0x0200, read/write
        configure_fmmu(0x00003000, 0x0100, 0x0200, 0x03);
        
        // Access outside FMMU range (should not hit this FMMU)
        dut->log_req = 1;
        dut->log_addr = 0x00005000;  // Way outside range
        dut->log_wr = 0;
        tick();
        dut->log_req = 0;
        
        // Should not get ack from this FMMU (no hit)
        for (int i = 0; i < 10; i++) tick();
        
        check(dut->log_ack == 0, "No ack for out-of-range address");
        std::cout << "  (No FMMU hit for address 0x5000)" << std::endl;
    }
    
    void test_error_code_clears_on_new_access() {
        std::cout << "\n=== Test: Error Code Clears on New Access ===" << std::endl;
        reset();
        
        // Configure read-only FMMU
        configure_fmmu(0x00004000, 0x0100, 0x0300, 0x01);
        
        // Cause an error (write to read-only)
        logical_access(0x00004050, true);
        check(dut->fmmu_error_code != 0, "Error code set after bad access");
        
        // Do a valid read
        bool success = logical_access(0x00004050, false);
        check(success, "Valid access succeeds");
        check(dut->fmmu_error_code == 0, "Error code cleared after valid access");
        
        std::cout << "  Error code after valid access: 0x" << std::hex << (int)dut->fmmu_error_code << std::dec << std::endl;
    }
    
    void run_all_tests() {
        test_no_error_on_valid_access();
        test_type_mismatch_write_to_readonly();
        test_type_mismatch_read_from_writeonly();
        test_address_out_of_range();
        test_error_code_clears_on_new_access();
        
        std::cout << "\n========================================" << std::endl;
        std::cout << "FMMU Error Detection Test Summary:" << std::endl;
        std::cout << "  Passed: " << test_passed << std::endl;
        std::cout << "  Failed: " << test_failed << std::endl;
        std::cout << "========================================" << std::endl;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    FMMUErrorTB tb;
    tb.enable_trace("tb_fmmu_error.vcd");
    
    tb.run_all_tests();
    
    return tb.test_failed > 0 ? 1 : 0;
}
