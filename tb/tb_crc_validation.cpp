// ============================================================================
// Verilator Testbench for CRC32 Validation
// Tests CRC validation in frame receiver
// ============================================================================

#include <verilated.h>
#include "Vecat_frame_receiver.h"
#include <iostream>
#include <iomanip>
#include <vector>
#include <cstdint>

// Simulation time
vluint64_t main_time = 0;

double sc_time_stamp() {
    return main_time;
}

// CRC32 calculation (same polynomial as in RTL)
uint32_t crc32_byte(uint32_t crc, uint8_t data) {
    uint32_t temp = crc;
    uint8_t xor_val = data ^ (crc & 0xFF);
    
    temp = temp >> 8;
    
    if (xor_val & 0x01) temp ^= 0x77073096;
    if (xor_val & 0x02) temp ^= 0xEE0E612C;
    if (xor_val & 0x04) temp ^= 0x076DC419;
    if (xor_val & 0x08) temp ^= 0x0EDB8832;
    if (xor_val & 0x10) temp ^= 0x1DB71064;
    if (xor_val & 0x20) temp ^= 0x3B6E20C8;
    if (xor_val & 0x40) temp ^= 0x76DC4190;
    if (xor_val & 0x80) temp ^= 0xEDB88320;
    
    return temp;
}

uint32_t calculate_frame_crc(const std::vector<uint8_t>& frame) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < frame.size(); i++) {
        crc = crc32_byte(crc, frame[i]);
    }
    return ~crc;  // Invert for FCS
}

class CRCValidationTB {
private:
    Vecat_frame_receiver* dut;
    int test_count;
    int pass_count;
    
public:
    CRCValidationTB() : test_count(0), pass_count(0) {
        dut = new Vecat_frame_receiver;
        dut->rst_n = 0;
        dut->clk = 0;
        dut->port_id = 0;
        dut->rx_valid = 0;
        dut->rx_data = 0;
        dut->rx_sof = 0;
        dut->rx_eof = 0;
        dut->rx_error = 0;
        dut->station_address = 0x1000;
        dut->station_alias = 0x0000;
        dut->mem_ready = 1;
        dut->mem_rdata = 0;
    }
    
    ~CRCValidationTB() {
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
    
    // Send frame with FCS (4-byte CRC appended)
    void send_frame_with_fcs(const std::vector<uint8_t>& payload, bool corrupt_crc = false) {
        // Calculate CRC for payload
        uint32_t crc = calculate_frame_crc(payload);
        
        if (corrupt_crc) {
            crc ^= 0x12345678;  // Corrupt the CRC
        }
        
        // Build frame with FCS (little-endian)
        std::vector<uint8_t> frame = payload;
        frame.push_back(crc & 0xFF);
        frame.push_back((crc >> 8) & 0xFF);
        frame.push_back((crc >> 16) & 0xFF);
        frame.push_back((crc >> 24) & 0xFF);
        
        std::cout << "[INFO] Sending frame (" << frame.size() << " bytes, CRC="
                  << std::hex << crc << std::dec << ")\n";
        
        for (size_t i = 0; i < frame.size(); i++) {
            bool sof = (i == 0);
            bool eof = (i == frame.size() - 1);
            send_byte(frame[i], sof, eof);
        }
        
        // Wait for processing
        for (int i = 0; i < 10; i++) {
            clock();
        }
    }
    
    // Create a simple EtherCAT frame
    std::vector<uint8_t> create_ecat_frame(uint8_t cmd, uint16_t adp, uint16_t ado, 
                                           const std::vector<uint8_t>& data) {
        std::vector<uint8_t> frame;
        
        // Ethernet header (14 bytes)
        // Destination MAC (broadcast)
        frame.push_back(0xFF); frame.push_back(0xFF); frame.push_back(0xFF);
        frame.push_back(0xFF); frame.push_back(0xFF); frame.push_back(0xFF);
        // Source MAC
        frame.push_back(0x00); frame.push_back(0x01); frame.push_back(0x02);
        frame.push_back(0x03); frame.push_back(0x04); frame.push_back(0x05);
        // EtherType (0x88A4 = EtherCAT)
        frame.push_back(0x88);
        frame.push_back(0xA4);
        
        // EtherCAT header (2 bytes)
        uint16_t ecat_len = 10 + data.size() + 2;  // DG header + data + WKC
        frame.push_back(ecat_len & 0xFF);
        frame.push_back((ecat_len >> 8) & 0x0F);
        
        // Datagram header (10 bytes)
        frame.push_back(cmd);           // Command
        frame.push_back(0);             // Index
        frame.push_back(adp & 0xFF);    // ADP low
        frame.push_back((adp >> 8) & 0xFF);  // ADP high
        frame.push_back(ado & 0xFF);    // ADO low
        frame.push_back((ado >> 8) & 0xFF);  // ADO high
        uint16_t len_field = data.size() & 0x7FF;  // Length (no more bit)
        frame.push_back(len_field & 0xFF);
        frame.push_back((len_field >> 8) & 0xFF);
        frame.push_back(0);             // IRQ
        frame.push_back(0);
        
        // Data
        for (auto b : data) {
            frame.push_back(b);
        }
        
        // WKC (2 bytes)
        frame.push_back(0);
        frame.push_back(0);
        
        return frame;
    }
    
    bool check_test(const std::string& name, bool condition) {
        test_count++;
        if (condition) {
            pass_count++;
            std::cout << "[PASS] " << name << "\n";
            return true;
        } else {
            std::cout << "[FAIL] " << name << "\n";
            return false;
        }
    }
    
    // ========================================================================
    // Test Cases
    // ========================================================================
    
    void test_valid_crc() {
        std::cout << "\n=== Test: Valid CRC ===\n";
        reset();
        
        uint16_t initial_crc_errors = dut->rx_crc_error_count;
        
        // Create and send a valid EtherCAT frame
        std::vector<uint8_t> data = {0x01, 0x02, 0x03, 0x04};
        std::vector<uint8_t> frame = create_ecat_frame(0x01, 0x0000, 0x0010, data);
        
        send_frame_with_fcs(frame, false);  // Valid CRC
        
        check_test("CRC error count unchanged", 
                   dut->rx_crc_error_count == initial_crc_errors);
        check_test("Frame count incremented",
                   dut->rx_frame_count > 0);
    }
    
    void test_invalid_crc() {
        std::cout << "\n=== Test: Invalid CRC ===\n";
        reset();
        
        uint16_t initial_crc_errors = dut->rx_crc_error_count;
        
        // Create and send a frame with corrupted CRC
        std::vector<uint8_t> data = {0x01, 0x02, 0x03, 0x04};
        std::vector<uint8_t> frame = create_ecat_frame(0x01, 0x0000, 0x0010, data);
        
        send_frame_with_fcs(frame, true);  // Corrupted CRC
        
        check_test("CRC error count incremented", 
                   dut->rx_crc_error_count > initial_crc_errors);
    }
    
    void test_multiple_frames() {
        std::cout << "\n=== Test: Multiple Frames ===\n";
        reset();
        
        // Send multiple valid frames
        for (int i = 0; i < 5; i++) {
            std::vector<uint8_t> data = {(uint8_t)(0x10 + i), 0x20, 0x30, 0x40};
            std::vector<uint8_t> frame = create_ecat_frame(0x01, 0x0000, 0x0010 + i, data);
            send_frame_with_fcs(frame, false);
        }
        
        check_test("Multiple frames processed",
                   dut->rx_frame_count >= 5);
        check_test("No CRC errors",
                   dut->rx_crc_error_count == 0);
    }
    
    void test_mixed_valid_invalid() {
        std::cout << "\n=== Test: Mixed Valid/Invalid Frames ===\n";
        reset();
        
        // Send mix of valid and invalid frames
        std::vector<uint8_t> data = {0x01, 0x02, 0x03, 0x04};
        
        // Valid
        std::vector<uint8_t> frame1 = create_ecat_frame(0x01, 0x0000, 0x0010, data);
        send_frame_with_fcs(frame1, false);
        
        // Invalid
        std::vector<uint8_t> frame2 = create_ecat_frame(0x01, 0x0000, 0x0020, data);
        send_frame_with_fcs(frame2, true);
        
        // Valid
        std::vector<uint8_t> frame3 = create_ecat_frame(0x01, 0x0000, 0x0030, data);
        send_frame_with_fcs(frame3, false);
        
        check_test("Frame count is 3",
                   dut->rx_frame_count == 3);
        check_test("CRC error count is 1",
                   dut->rx_crc_error_count == 1);
    }
    
    void run_all_tests() {
        std::cout << "========================================\n";
        std::cout << "CRC32 Validation Testbench\n";
        std::cout << "========================================\n";
        
        test_valid_crc();
        test_invalid_crc();
        test_multiple_frames();
        test_mixed_valid_invalid();
        
        std::cout << "\n========================================\n";
        std::cout << "Test Summary: " << pass_count << "/" << test_count << " passed\n";
        std::cout << "========================================\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    CRCValidationTB tb;
    tb.run_all_tests();
    
    return 0;
}
