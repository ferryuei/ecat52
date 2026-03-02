// ============================================================================
// Verilator Testbench for EtherCAT Frame Receiver
// Tests frame parsing, command decoding, and address matching
// ============================================================================

#include <verilated.h>
#include "Vecat_frame_receiver.h"
#include <iostream>
#include <iomanip>
#include <vector>

// Simulation time
vluint64_t main_time = 0;

// Called by $time in Verilog
double sc_time_stamp() {
    return main_time;
}

class FrameReceiverTB {
private:
    Vecat_frame_receiver* dut;
    
public:
    FrameReceiverTB() {
        dut = new Vecat_frame_receiver;
        dut->rst_n = 0;
        dut->clk = 0;
        dut->port_id = 0;
        dut->rx_valid = 0;
        dut->rx_data = 0;
        dut->rx_sof = 0;
        dut->rx_eof = 0;
        dut->rx_error = 0;
        dut->station_address = 0x1000;  // Test station address
        dut->station_alias = 0x0000;
        dut->mem_ready = 1;
        dut->mem_rdata = 0;
    }
    
    ~FrameReceiverTB() {
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
        for (int i = 0; i < 10; i++) {
            clock();
        }
        dut->rst_n = 1;
        clock();
        std::cout << "[INFO] Reset complete\n";
    }
    
    void send_byte(uint8_t data, bool sof = false, bool eof = false) {
        dut->rx_valid = 1;
        dut->rx_data = data;
        dut->rx_sof = sof ? 1 : 0;
        dut->rx_eof = eof ? 1 : 0;
        clock();
        dut->rx_valid = 0;
        dut->rx_sof = 0;
        dut->rx_eof = 0;
    }
    
    void send_frame(const std::vector<uint8_t>& frame) {
        std::cout << "[INFO] Sending frame (" << frame.size() << " bytes)\n";
        
        for (size_t i = 0; i < frame.size(); i++) {
            bool sof = (i == 0);
            bool eof = (i == frame.size() - 1);
            
            std::cout << "  Byte " << std::setw(3) << i << ": 0x" 
                      << std::hex << std::setw(2) << std::setfill('0') 
                      << (int)frame[i] << std::dec;
            
            if (sof) std::cout << " [SOF]";
            if (eof) std::cout << " [EOF]";
            std::cout << "\n";
            
            send_byte(frame[i], sof, eof);
        }
        
        // Give some cycles for processing
        for (int i = 0; i < 10; i++) {
            clock();
        }
    }
    
    // Test 1: Simple FPRD (Fixed Physical Read) command
    void test_fprd_frame() {
        std::cout << "\n=== TEST 1: FPRD (Fixed Physical Read) ===\n";
        
        std::vector<uint8_t> frame = {
            // EtherCAT header (2 bytes)
            0x1C, 0x10,  // Length=28, Type=0x1 (EtherCAT)
            
            // Datagram header (10 bytes)
            0x04,        // Command: FPRD
            0x00,        // Index
            0x00, 0x10,  // Address: 0x1000 (station address)
            0x00, 0x00,  // Address high
            0x10, 0x00,  // Length: 16 bytes
            0x00,        // Reserved
            0x00,        // IRQ
            
            // Data (16 bytes) - will be read from memory
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            
            // Working counter (2 bytes)
            0x00, 0x00
        };
        
        send_frame(frame);
        
        std::cout << "[INFO] Frame receiver statistics:\n";
        std::cout << "  RX Frame Count: " << dut->rx_frame_count << "\n";
        std::cout << "  RX Error Count: " << dut->rx_error_count << "\n";
    }
    
    // Test 2: BWR (Broadcast Write) command
    void test_bwr_frame() {
        std::cout << "\n=== TEST 2: BWR (Broadcast Write) ===\n";
        
        std::vector<uint8_t> frame = {
            // EtherCAT header
            0x18, 0x10,  // Length=24
            
            // Datagram header
            0x08,        // Command: BWR
            0x01,        // Index
            0x20, 0x01,  // Address: 0x0120 (AL Control)
            0x00, 0x00,
            0x02, 0x00,  // Length: 2 bytes
            0x00,
            0x00,
            
            // Data (2 bytes)
            0x02, 0x00,  // Request Pre-Op state
            
            // Working counter
            0x00, 0x00
        };
        
        send_frame(frame);
        
        std::cout << "[INFO] Broadcast write complete\n";
    }
    
    // Test 3: LRD (Logical Read) command
    void test_lrd_frame() {
        std::cout << "\n=== TEST 3: LRD (Logical Read) ===\n";
        
        std::vector<uint8_t> frame = {
            // EtherCAT header
            0x14, 0x10,
            
            // Datagram header
            0x0A,        // Command: LRD
            0x02,        // Index
            0x00, 0x00,  // Logical address: 0x00000000
            0x00, 0x00,
            0x04, 0x00,  // Length: 4 bytes
            0x00,
            0x00,
            
            // Data
            0x00, 0x00, 0x00, 0x00,
            
            // Working counter
            0x00, 0x00
        };
        
        send_frame(frame);
        
        std::cout << "[INFO] Logical read complete\n";
    }
    
    void run_all_tests() {
        std::cout << "========================================\n";
        std::cout << "EtherCAT Frame Receiver Testbench\n";
        std::cout << "========================================\n";
        
        reset();
        
        test_fprd_frame();
        test_bwr_frame();
        test_lrd_frame();
        
        std::cout << "\n========================================\n";
        std::cout << "All tests complete!\n";
        std::cout << "========================================\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    
    FrameReceiverTB* tb = new FrameReceiverTB();
    tb->run_all_tests();
    
    delete tb;
    return 0;
}
