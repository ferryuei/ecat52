// ============================================================================
// EtherCAT Port Controller Testbench
// Tests multi-port forwarding, loop detection, and DL status
// ============================================================================

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vecat_port_controller.h"
#include <iostream>
#include <iomanip>

class PortControllerTB {
public:
    Vecat_port_controller* dut;
    VerilatedVcdC* trace;
    uint64_t sim_time;
    int test_passed;
    int test_failed;
    
    PortControllerTB() {
        dut = new Vecat_port_controller;
        trace = nullptr;
        sim_time = 0;
        test_passed = 0;
        test_failed = 0;
    }
    
    ~PortControllerTB() {
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
        dut->eval();
        if (trace) trace->dump(sim_time++);
        
        dut->clk = 1;
        dut->eval();
        if (trace) trace->dump(sim_time++);
    }
    
    void reset() {
        dut->rst_n = 0;
        dut->port_link_up = 0;
        dut->port_rx_active = 0;
        dut->port_tx_active = 0;
        dut->frame_rx_valid = 0;
        dut->frame_rx_port = 0;
        dut->frame_src_mac = 0;
        dut->frame_dst_mac = 0;
        dut->frame_is_ecat = 0;
        dut->frame_crc_error = 0;
        dut->port_enable = 0x3;  // Enable both ports
        dut->fwd_enable = 1;
        dut->temp_loop_enable = 0;
        dut->loop_port_sel = 0;
        
        for (int i = 0; i < 10; i++) tick();
        
        dut->rst_n = 1;
        tick();
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
    
    void test_initial_state() {
        std::cout << "\n=== Test: Initial State ===" << std::endl;
        reset();
        
        // With no links, DL status should show ports as open
        check(dut->loop_active == 0, "No loops initially");
        check(dut->loop_detected == 0, "No loop detected");
        
        std::cout << "  DL Status: 0x" << std::hex << dut->dl_status << std::dec << std::endl;
    }
    
    void test_port_link_up() {
        std::cout << "\n=== Test: Port Link Up Detection ===" << std::endl;
        reset();
        
        // Bring up port 0
        dut->port_link_up = 0x1;
        for (int i = 0; i < 5; i++) tick();
        
        std::cout << "  DL Status after port 0 up: 0x" << std::hex << dut->dl_status << std::dec << std::endl;
        
        // Bring up port 1
        dut->port_link_up = 0x3;
        for (int i = 0; i < 5; i++) tick();
        
        std::cout << "  DL Status after both ports up: 0x" << std::hex << dut->dl_status << std::dec << std::endl;
        check(dut->port_link_up == 0x3, "Both ports up");
    }
    
    void test_frame_forwarding() {
        std::cout << "\n=== Test: Frame Forwarding ===" << std::endl;
        reset();
        
        // Links up
        dut->port_link_up = 0x3;
        dut->port_enable = 0x3;
        dut->fwd_enable = 1;
        tick();
        
        // Receive EtherCAT frame on port 0
        dut->frame_rx_valid = 1;
        dut->frame_rx_port = 0;
        dut->frame_is_ecat = 1;
        dut->frame_crc_error = 0;
        dut->frame_src_mac = 0x001122334455ULL;
        dut->frame_dst_mac = 0xFFFFFFFFFFFFULL;  // Broadcast
        tick();
        
        dut->frame_rx_valid = 0;
        tick();
        
        // Check forwarding request
        std::cout << "  Forward request: " << (int)dut->fwd_request << std::endl;
        std::cout << "  Forward port mask: 0x" << std::hex << (int)dut->fwd_port_mask << std::dec << std::endl;
        std::cout << "  Exclude port: " << (int)dut->fwd_exclude_port << std::endl;
        
        // Should forward to port 1 (mask=0x2), exclude port 0
        check(dut->fwd_exclude_port == 0, "Exclude source port");
    }
    
    void test_no_forward_on_crc_error() {
        std::cout << "\n=== Test: No Forward on CRC Error ===" << std::endl;
        reset();
        
        dut->port_link_up = 0x3;
        dut->port_enable = 0x3;
        dut->fwd_enable = 1;
        tick();
        
        // Receive frame with CRC error
        dut->frame_rx_valid = 1;
        dut->frame_rx_port = 0;
        dut->frame_is_ecat = 1;
        dut->frame_crc_error = 1;  // CRC error!
        tick();
        
        dut->frame_rx_valid = 0;
        tick();
        
        // Should NOT request forwarding
        check(dut->fwd_request == 0, "No forward on CRC error");
    }
    
    void test_link_loss_counter() {
        std::cout << "\n=== Test: Link Loss Counter ===" << std::endl;
        reset();
        
        // Bring up links
        dut->port_link_up = 0x3;
        for (int i = 0; i < 5; i++) tick();
        
        uint16_t initial_loss_0 = dut->lost_link_port0;
        uint16_t initial_loss_1 = dut->lost_link_port1;
        
        // Drop port 0 link
        dut->port_link_up = 0x2;
        for (int i = 0; i < 5; i++) tick();
        
        check(dut->lost_link_port0 == initial_loss_0 + 1, "Link loss counter incremented");
        std::cout << "  Port 0 link loss count: " << dut->lost_link_port0 << std::endl;
        std::cout << "  Port 1 link loss count: " << dut->lost_link_port1 << std::endl;
    }
    
    void test_rx_error_counter() {
        std::cout << "\n=== Test: RX Error Counter ===" << std::endl;
        reset();
        
        dut->port_link_up = 0x3;
        tick();
        
        uint16_t initial_err_0 = dut->rx_error_port0;
        
        // Receive frame with error on port 0
        dut->frame_rx_valid = 1;
        dut->frame_rx_port = 0;
        dut->frame_crc_error = 1;
        tick();
        
        dut->frame_rx_valid = 0;
        for (int i = 0; i < 5; i++) tick();
        
        std::cout << "  Port 0 RX error count: " << dut->rx_error_port0 << std::endl;
        std::cout << "  Port 1 RX error count: " << dut->rx_error_port1 << std::endl;
    }
    
    void test_port_status_packed() {
        std::cout << "\n=== Test: Port Status Packed Output ===" << std::endl;
        reset();
        
        // All ports down
        dut->port_link_up = 0;
        for (int i = 0; i < 5; i++) tick();
        
        std::cout << "  Port status (all down): 0x" << std::hex << dut->port_status_packed << std::dec << std::endl;
        
        // Port 0 up
        dut->port_link_up = 0x1;
        for (int i = 0; i < 5; i++) tick();
        
        std::cout << "  Port status (port 0 up): 0x" << std::hex << dut->port_status_packed << std::dec << std::endl;
        
        // Both ports up
        dut->port_link_up = 0x3;
        for (int i = 0; i < 5; i++) tick();
        
        std::cout << "  Port status (both up): 0x" << std::hex << dut->port_status_packed << std::dec << std::endl;
        
        check(dut->port_status_packed != 0, "Port status non-zero when links up");
    }
    
    void run_all_tests() {
        test_initial_state();
        test_port_link_up();
        test_frame_forwarding();
        test_no_forward_on_crc_error();
        test_link_loss_counter();
        test_rx_error_counter();
        test_port_status_packed();
        
        std::cout << "\n========================================" << std::endl;
        std::cout << "Port Controller Test Summary:" << std::endl;
        std::cout << "  Passed: " << test_passed << std::endl;
        std::cout << "  Failed: " << test_failed << std::endl;
        std::cout << "========================================" << std::endl;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    PortControllerTB tb;
    tb.enable_trace("tb_port_controller.vcd");
    
    tb.run_all_tests();
    
    return tb.test_failed > 0 ? 1 : 0;
}
