// ============================================================================
// Verilator Testbench for SII/EEPROM Controller
// Tests I2C master functionality for EEPROM access
// ============================================================================

#include <verilated.h>
#include "Vecat_sii_controller.h"
#include <iostream>
#include <iomanip>
#include <queue>

vluint64_t main_time = 0;

double sc_time_stamp() {
    return main_time;
}

// Simple I2C EEPROM model
class I2CEEPROMModel {
private:
    uint8_t memory[256];  // 24C02 = 256 bytes
    uint8_t device_addr;
    uint8_t word_addr;
    int bit_count;
    uint8_t shift_reg;
    bool ack_pending;
    bool address_set;
    
    enum State {
        IDLE,
        DEVICE_ADDR,
        WORD_ADDR,
        READ_DATA,
        WRITE_DATA
    } state;
    
public:
    I2CEEPROMModel() {
        device_addr = 0xA0;  // Default I2C address
        reset();
        // Initialize with test pattern
        for (int i = 0; i < 256; i++) {
            memory[i] = i;
        }
    }
    
    void reset() {
        state = IDLE;
        bit_count = 0;
        shift_reg = 0;
        ack_pending = false;
        address_set = false;
        word_addr = 0;
    }
    
    // Returns SDA value (1 = released/high, 0 = pulled low)
    bool process(bool scl, bool sda_out, bool sda_oe) {
        static bool prev_scl = true;
        static bool prev_sda = true;
        
        bool sda_in = sda_oe ? sda_out : true;
        bool sda_drive = true;  // Default: release line
        
        // Detect START condition (SDA falling while SCL high)
        if (prev_scl && scl && prev_sda && !sda_in) {
            state = DEVICE_ADDR;
            bit_count = 0;
            shift_reg = 0;
            ack_pending = false;
        }
        
        // Detect STOP condition (SDA rising while SCL high)
        if (prev_scl && scl && !prev_sda && sda_in) {
            state = IDLE;
        }
        
        // Process on SCL edges
        if (!prev_scl && scl) {
            // Rising edge - sample data
            switch (state) {
                case DEVICE_ADDR:
                case WORD_ADDR:
                case WRITE_DATA:
                    if (bit_count < 8) {
                        shift_reg = (shift_reg << 1) | (sda_in ? 1 : 0);
                        bit_count++;
                    }
                    break;
                    
                case READ_DATA:
                    bit_count++;
                    if (bit_count >= 9) {
                        // Master sent ACK/NACK
                        if (!sda_in) {
                            // ACK - continue reading
                            word_addr++;
                            shift_reg = memory[word_addr];
                            bit_count = 0;
                        } else {
                            // NACK - stop
                            state = IDLE;
                        }
                    }
                    break;
                    
                default:
                    break;
            }
        }
        
        if (prev_scl && !scl) {
            // Falling edge - change data / send ACK
            switch (state) {
                case DEVICE_ADDR:
                    if (bit_count == 8) {
                        // Check device address (ignore R/W bit for now)
                        if ((shift_reg & 0xFE) == device_addr) {
                            ack_pending = true;
                            if (shift_reg & 0x01) {
                                // Read operation
                                state = READ_DATA;
                                shift_reg = memory[word_addr];
                                bit_count = 0;
                            } else {
                                // Write operation
                                state = WORD_ADDR;
                                bit_count = 0;
                            }
                        } else {
                            state = IDLE;
                        }
                    }
                    break;
                    
                case WORD_ADDR:
                    if (bit_count == 8) {
                        word_addr = shift_reg;
                        address_set = true;
                        ack_pending = true;
                        state = WRITE_DATA;
                        bit_count = 0;
                    }
                    break;
                    
                case WRITE_DATA:
                    if (bit_count == 8) {
                        memory[word_addr] = shift_reg;
                        word_addr++;
                        ack_pending = true;
                        bit_count = 0;
                    }
                    break;
                    
                default:
                    break;
            }
        }
        
        // Drive SDA for ACK or read data
        if (ack_pending && !scl) {
            sda_drive = false;  // Pull low for ACK
            ack_pending = false;
        } else if (state == READ_DATA && bit_count < 8) {
            sda_drive = (shift_reg & 0x80) ? true : false;
            shift_reg <<= 1;
        }
        
        prev_scl = scl;
        prev_sda = sda_in;
        
        return sda_drive;
    }
};

class SIIControllerTB {
private:
    Vecat_sii_controller* dut;
    I2CEEPROMModel eeprom;
    int test_count;
    int pass_count;
    
public:
    SIIControllerTB() : test_count(0), pass_count(0) {
        dut = new Vecat_sii_controller;
        dut->rst_n = 0;
        dut->clk = 0;
        dut->reg_req = 0;
        dut->reg_wr = 0;
        dut->reg_addr = 0;
        dut->reg_wdata = 0;
        dut->i2c_scl_i = 1;
        dut->i2c_sda_i = 1;
    }
    
    ~SIIControllerTB() {
        dut->final();
        delete dut;
    }
    
    void clock() {
        // Update EEPROM model
        bool sda_from_eeprom = eeprom.process(
            dut->i2c_scl_o,
            dut->i2c_sda_o,
            dut->i2c_sda_oe
        );
        
        // Feed SDA back (if EEPROM is driving)
        dut->i2c_sda_i = dut->i2c_sda_oe ? dut->i2c_sda_o : sda_from_eeprom;
        dut->i2c_scl_i = dut->i2c_scl_oe ? dut->i2c_scl_o : 1;
        
        dut->clk = 0;
        dut->eval();
        main_time++;
        
        dut->clk = 1;
        dut->eval();
        main_time++;
    }
    
    void reset() {
        dut->rst_n = 0;
        eeprom.reset();
        for (int i = 0; i < 10; i++) {
            clock();
        }
        dut->rst_n = 1;
        clock();
        std::cout << "[INFO] Reset complete\n";
    }
    
    void write_reg(uint16_t addr, uint32_t data) {
        dut->reg_req = 1;
        dut->reg_wr = 1;
        dut->reg_addr = addr;
        dut->reg_wdata = data;
        clock();
        while (!dut->reg_ack) clock();
        dut->reg_req = 0;
        dut->reg_wr = 0;
        clock();
    }
    
    uint32_t read_reg(uint16_t addr) {
        dut->reg_req = 1;
        dut->reg_wr = 0;
        dut->reg_addr = addr;
        clock();
        while (!dut->reg_ack) clock();
        uint32_t data = dut->reg_rdata;
        dut->reg_req = 0;
        clock();
        return data;
    }
    
    void wait_not_busy(int max_cycles = 100000) {
        for (int i = 0; i < max_cycles && dut->eeprom_busy; i++) {
            clock();
        }
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
    
    void test_register_access() {
        std::cout << "\n=== Test: Register Access ===\n";
        reset();
        
        // Write and read back address registers
        write_reg(0x0502, 0x0012);  // SII_ADDR_LO
        write_reg(0x0503, 0x0034);  // SII_ADDR_HI
        
        uint32_t addr_lo = read_reg(0x0502);
        uint32_t addr_hi = read_reg(0x0503);
        
        check_test("Address register write/read", 
                   (addr_lo == 0x12) && (addr_hi == 0x34));
    }
    
    void test_eeprom_read() {
        std::cout << "\n=== Test: EEPROM Read ===\n";
        reset();
        
        // Set address to read from
        write_reg(0x0502, 0x0010);  // Address low = 0x10
        write_reg(0x0503, 0x0000);  // Address high = 0x00
        
        // Start read operation (bit 0 = start, bit 2 = 0 for read)
        write_reg(0x0500, 0x0001);
        
        // Wait for completion
        wait_not_busy();
        
        // Check if operation completed
        check_test("EEPROM read completed", !dut->eeprom_busy);
        check_test("No EEPROM error", !dut->eeprom_error);
        
        // Read back data (should be test pattern)
        uint32_t data0 = read_reg(0x0504);
        std::cout << "[INFO] Read data byte 0: 0x" << std::hex << data0 << std::dec << "\n";
        
        check_test("EEPROM data correct", data0 == 0x10);  // Should match address
    }
    
    void test_eeprom_loaded_flag() {
        std::cout << "\n=== Test: EEPROM Loaded Flag ===\n";
        reset();
        
        check_test("Initially not loaded", !dut->eeprom_loaded);
        
        // Perform a read operation
        write_reg(0x0502, 0x0000);
        write_reg(0x0503, 0x0000);
        write_reg(0x0500, 0x0001);
        wait_not_busy();
        
        check_test("Loaded after read", dut->eeprom_loaded);
    }
    
    void run_all_tests() {
        std::cout << "========================================\n";
        std::cout << "SII/EEPROM Controller Testbench\n";
        std::cout << "========================================\n";
        
        test_register_access();
        test_eeprom_read();
        test_eeprom_loaded_flag();
        
        std::cout << "\n========================================\n";
        std::cout << "Test Summary: " << pass_count << "/" << test_count << " passed\n";
        std::cout << "========================================\n";
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    SIIControllerTB tb;
    tb.run_all_tests();
    
    return 0;
}
