// ============================================================================
// Verilator Testbench for Register Map
// Tests ESC register read/write operations
// ============================================================================

#include <verilated.h>
#include "Vecat_register_map.h"
#include <iostream>
#include <iomanip>

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

class RegisterMapTB {
private:
    Vecat_register_map* dut;
    
public:
    RegisterMapTB() {
        dut = new Vecat_register_map;
        dut->rst_n = 0;
        dut->clk = 0;
        dut->reg_req = 0;
        dut->reg_wr = 0;
        dut->reg_addr = 0;
        dut->reg_wdata = 0;
        dut->reg_be = 0;
        dut->al_status = 0x01;  // Init
        dut->al_status_code = 0;
        dut->dl_status = 0;
        dut->port_link_status = 0x03;
        dut->port_loop_status = 0;
        dut->irq_request = 0;
        dut->sm_status = 0;
        dut->fmmu_status = 0;
        dut->dc_system_time = 0;
        for (int i = 0; i < 4; i++) {
            dut->rx_error_counter[i] = 0;
            dut->lost_link_counter[i] = 0;
        }
    }
    
    ~RegisterMapTB() {
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
        std::cout << "[INFO] Reset complete\n";
    }
    
    uint16_t read_reg(uint16_t addr) {
        dut->reg_req = 1;
        dut->reg_wr = 0;
        dut->reg_addr = addr;
        clock();
        
        int timeout = 100;
        while (!dut->reg_ack && timeout > 0) {
            clock();
            timeout--;
        }
        
        if (timeout == 0) {
            std::cout << "  ERROR: Read timeout at address 0x" << std::hex << addr << std::dec << "\n";
            return 0xFFFF;
        }
        
        uint16_t data = dut->reg_rdata;
        dut->reg_req = 0;
        clock();
        
        std::cout << "  READ  [0x" << std::hex << std::setw(4) << std::setfill('0') 
                  << addr << "] = 0x" << std::setw(4) << data << std::dec << "\n";
        return data;
    }
    
    void write_reg(uint16_t addr, uint16_t data, uint8_t be = 0x03) {
        std::cout << "  WRITE [0x" << std::hex << std::setw(4) << std::setfill('0') 
                  << addr << "] = 0x" << std::setw(4) << data << std::dec << "\n";
        
        dut->reg_req = 1;
        dut->reg_wr = 1;
        dut->reg_addr = addr;
        dut->reg_wdata = data;
        dut->reg_be = be;
        clock();
        
        int timeout = 100;
        while (!dut->reg_ack && timeout > 0) {
            clock();
            timeout--;
        }
        
        if (timeout == 0) {
            std::cout << "  ERROR: Write timeout at address 0x" << std::hex << addr << std::dec << "\n";
        }
        
        dut->reg_req = 0;
        clock();
    }
    
    void test_device_info() {
        std::cout << "\n=== TEST: Device Information (Read-Only) ===\n";
        
        uint16_t type = read_reg(0x0000);
        std::cout << "    Device Type/Revision: 0x" << std::hex << type << std::dec << "\n";
        
        uint16_t build = read_reg(0x0002);
        std::cout << "    Build: " << build << "\n";
        
        uint16_t fmmu_sm = read_reg(0x0004);
        std::cout << "    FMMU count: " << (fmmu_sm & 0xFF) 
                  << ", SM count: " << (fmmu_sm >> 8) << "\n";
        
        uint16_t ram_port = read_reg(0x0006);
        std::cout << "    RAM size: " << (ram_port & 0xFF) << " KB\n";
        std::cout << "    Port desc: 0x" << std::hex << (ram_port >> 8) << std::dec << "\n";
    }
    
    void test_station_address() {
        std::cout << "\n=== TEST: Station Address Configuration ===\n";
        
        // Write station address
        write_reg(0x0010, 0x1234);
        
        // Read back
        uint16_t addr = read_reg(0x0010);
        if (addr == 0x1234) {
            std::cout << "    [PASS] Station address set correctly\n";
        } else {
            std::cout << "    [FAIL] Expected 0x1234, got 0x" 
                      << std::hex << addr << std::dec << "\n";
        }
        
        // Write station alias
        write_reg(0x0012, 0x5678);
        uint16_t alias = read_reg(0x0012);
        if (alias == 0x5678) {
            std::cout << "    [PASS] Station alias set correctly\n";
        } else {
            std::cout << "    [FAIL] Station alias mismatch\n";
        }
    }
    
    void test_al_control() {
        std::cout << "\n=== TEST: AL Control/Status ===\n";
        
        // Read AL status
        uint16_t status = read_reg(0x0130);
        std::cout << "    Initial AL Status: 0x" << std::hex << status << std::dec << "\n";
        
        // Write AL control (request Pre-Op)
        write_reg(0x0120, 0x0002);
        clock();
        
        std::cout << "    AL Control Changed: " << (int)dut->al_control_changed << "\n";
        std::cout << "    AL Control Value: 0x" << std::hex << (int)dut->al_control << std::dec << "\n";
        
        // Read AL status code
        uint16_t code = read_reg(0x0134);
        std::cout << "    AL Status Code: 0x" << std::hex << code << std::dec << "\n";
    }
    
    void test_dl_control() {
        std::cout << "\n=== TEST: DL Control ===\n";
        
        // Write DL control
        write_reg(0x0100, 0x0047);  // Enable forwarding, ECAT, etc.
        
        // Check outputs
        std::cout << "    DL Control - Forwarding Enable: " << (int)dut->dl_control_fwd_en << "\n";
        
        // Read DL status
        uint16_t status = read_reg(0x0110);
        std::cout << "    DL Status: 0x" << std::hex << status << std::dec << "\n";
    }
    
    void test_irq_registers() {
        std::cout << "\n=== TEST: IRQ Registers ===\n";
        
        // Write IRQ mask
        write_reg(0x0200, 0x00FF);
        uint16_t mask = read_reg(0x0200);
        std::cout << "    IRQ Mask: 0x" << std::hex << mask << std::dec << "\n";
        
        // Simulate IRQ
        dut->irq_request = 0x0001;
        for (int i = 0; i < 5; i++) clock();
        
        // Read IRQ request (should clear after read)
        uint16_t req = read_reg(0x0220);
        std::cout << "    IRQ Request: 0x" << std::hex << req << std::dec << "\n";
        
        // Read again (should be cleared)
        req = read_reg(0x0220);
        if (req == 0) {
            std::cout << "    [PASS] IRQ cleared after read\n";
        }
    }
    
    void run_all_tests() {
        std::cout << "========================================\n";
        std::cout << "Register Map Testbench\n";
        std::cout << "========================================\n";
        
        reset();
        
        test_device_info();
        test_station_address();
        test_al_control();
        test_dl_control();
        test_irq_registers();
        
        std::cout << "\n========================================\n";
        std::cout << "All tests complete!\n";
        std::cout << "========================================\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    RegisterMapTB* tb = new RegisterMapTB();
    tb->run_all_tests();
    
    delete tb;
    return 0;
}
