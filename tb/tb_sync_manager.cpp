// ============================================================================
// Verilator Testbench for Sync Manager
// Tests mailbox mode and 3-buffer mode operations
// ============================================================================

#include <verilated.h>
#include "Vecat_sync_manager.h"
#include <iostream>
#include <iomanip>

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// SM Control Register bits
#define CTRL_MODE_BIT0     0
#define CTRL_MODE_BIT1     1
#define CTRL_DIRECTION     2
#define CTRL_IRQ_ECAT      3
#define CTRL_IRQ_PDI       4

// SM Status Register bits (ETG.1000 compliant)
#define STAT_IRQ_WRITE       0
#define STAT_IRQ_READ        1
#define STAT_BUFFER_WRITTEN  2
#define STAT_MAILBOX_FULL    3

// Operating modes
#define MODE_3BUFFER   0x00
#define MODE_MAILBOX   0x02

// Register offsets
#define REG_START_ADDR   0x00
#define REG_LENGTH       0x02
#define REG_CONTROL      0x04
#define REG_STATUS       0x05
#define REG_ACTIVATE     0x06

class SyncManagerTB {
private:
    Vecat_sync_manager* dut;
    int test_pass_count;
    int test_fail_count;
    
public:
    SyncManagerTB() {
        dut = new Vecat_sync_manager;
        test_pass_count = 0;
        test_fail_count = 0;
        
        // Initialize all inputs
        dut->rst_n = 0;
        dut->clk = 0;
        dut->pdi_clk = 0;
        // feature_vector is a wide signal (256 bits), initialize each word
        for (int i = 0; i < 8; i++) dut->feature_vector[i] = 0;
        dut->cfg_wr = 0;
        dut->cfg_addr = 0;
        dut->cfg_wdata = 0;
        dut->ecat_req = 0;
        dut->ecat_wr = 0;
        dut->ecat_addr = 0;
        dut->ecat_wdata = 0;
        dut->pdi_req = 0;
        dut->pdi_wr = 0;
        dut->pdi_addr = 0;
        dut->pdi_wdata = 0;
        dut->mem_ack = 0;
        dut->mem_rdata = 0;
    }
    
    ~SyncManagerTB() {
        dut->final();
        delete dut;
    }
    
    void clock() {
        dut->clk = 0;
        dut->pdi_clk = 0;
        dut->eval();
        main_time++;
        dut->clk = 1;
        dut->pdi_clk = 1;
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
    
    // Write to SM configuration register
    void cfg_write(uint8_t addr, uint16_t data) {
        dut->cfg_wr = 1;
        dut->cfg_addr = addr;
        dut->cfg_wdata = data;
        clock();
        dut->cfg_wr = 0;
        clock();
    }
    
    // Read from SM configuration register
    uint16_t cfg_read(uint8_t addr) {
        dut->cfg_addr = addr;
        clock();
        return dut->cfg_rdata;
    }
    
    // Simulate EtherCAT write to SM
    void ecat_write(uint16_t addr, uint8_t data) {
        dut->ecat_req = 1;
        dut->ecat_wr = 1;
        dut->ecat_addr = addr;
        dut->ecat_wdata = data;
        clock();
        
        // Wait for memory access
        int timeout = 20;
        while (!dut->mem_req && timeout > 0) {
            clock();
            timeout--;
        }
        
        if (dut->mem_req) {
            // Provide memory ack
            dut->mem_ack = 1;
            clock();
            dut->mem_ack = 0;
        }
        
        // Wait for ack
        timeout = 20;
        while (!dut->ecat_ack && timeout > 0) {
            clock();
            timeout--;
        }
        
        dut->ecat_req = 0;
        clock();
    }
    
    // Simulate PDI read from SM
    uint8_t pdi_read(uint16_t addr) {
        dut->pdi_req = 1;
        dut->pdi_wr = 0;
        dut->pdi_addr = addr;
        clock();
        
        // Wait for memory access
        int timeout = 20;
        while (!dut->mem_req && timeout > 0) {
            clock();
            timeout--;
        }
        
        if (dut->mem_req) {
            // Provide memory ack with data
            dut->mem_ack = 1;
            dut->mem_rdata = 0xAB;  // Test data
            clock();
            dut->mem_ack = 0;
        }
        
        // Wait for ack
        timeout = 20;
        while (!dut->pdi_ack && timeout > 0) {
            clock();
            timeout--;
        }
        
        uint8_t data = dut->pdi_rdata;
        dut->pdi_req = 0;
        clock();
        
        return data;
    }
    
    // Configure SM for mailbox mode
    void configure_mailbox(uint16_t start, uint16_t len, bool ecat_writes) {
        std::cout << "  Configuring SM for mailbox mode\n";
        std::cout << "    Start: 0x" << std::hex << start << std::dec << "\n";
        std::cout << "    Length: " << len << " bytes\n";
        std::cout << "    Direction: " << (ecat_writes ? "ECAT writes" : "PDI writes") << "\n";
        
        cfg_write(REG_START_ADDR, start);
        cfg_write(REG_LENGTH, len);
        
        // Control: mailbox mode (0x02), direction, IRQ enable
        uint8_t ctrl = MODE_MAILBOX;
        if (!ecat_writes) ctrl |= (1 << CTRL_DIRECTION);
        ctrl |= (1 << CTRL_IRQ_ECAT) | (1 << CTRL_IRQ_PDI);
        cfg_write(REG_CONTROL, ctrl);
        
        // Activate SM
        cfg_write(REG_ACTIVATE, 0x01);
        
        for (int i = 0; i < 5; i++) clock();
    }
    
    // Configure SM for 3-buffer mode
    void configure_3buffer(uint16_t start, uint16_t len, bool ecat_writes) {
        std::cout << "  Configuring SM for 3-buffer mode\n";
        std::cout << "    Start: 0x" << std::hex << start << std::dec << "\n";
        std::cout << "    Length: " << len << " bytes\n";
        
        cfg_write(REG_START_ADDR, start);
        cfg_write(REG_LENGTH, len);
        
        // Control: 3-buffer mode (0x00), direction, IRQ enable
        uint8_t ctrl = MODE_3BUFFER;
        if (!ecat_writes) ctrl |= (1 << CTRL_DIRECTION);
        ctrl |= (1 << CTRL_IRQ_ECAT) | (1 << CTRL_IRQ_PDI);
        cfg_write(REG_CONTROL, ctrl);
        
        // Activate SM
        cfg_write(REG_ACTIVATE, 0x01);
        
        for (int i = 0; i < 5; i++) clock();
    }
    
    void check_pass(const char* msg, bool condition) {
        if (condition) {
            std::cout << "    [PASS] " << msg << "\n";
            test_pass_count++;
        } else {
            std::cout << "    [FAIL] " << msg << "\n";
            test_fail_count++;
        }
    }
    
    // Test 1: Mailbox mode write-read sequence
    void test_mailbox_write_read() {
        std::cout << "\n=== TEST 1: Mailbox Write-Read Sequence ===\n";
        
        reset();
        configure_mailbox(0x1000, 128, true);  // ECAT writes mailbox
        
        // Initial status should have mailbox_full = 0
        uint16_t status = cfg_read(REG_STATUS);
        std::cout << "  Initial status: 0x" << std::hex << status << std::dec << "\n";
        check_pass("Initial mailbox not full", (status & (1 << STAT_MAILBOX_FULL)) == 0);
        
        // EtherCAT writes to mailbox
        std::cout << "  EtherCAT writing to mailbox...\n";
        ecat_write(0x1000, 0x42);
        
        // Check that mailbox_full is set
        status = cfg_read(REG_STATUS);
        std::cout << "  Status after write: 0x" << std::hex << status << std::dec << "\n";
        check_pass("Mailbox full after write (bit 3)", (status & (1 << STAT_MAILBOX_FULL)) != 0);
        check_pass("Write event occurred (bit 0)", (status & (1 << STAT_IRQ_WRITE)) != 0);
        
        // Check that IRQ was generated
        check_pass("SM IRQ asserted", dut->sm_irq != 0);
        
        // Clear IRQ for next test
        for (int i = 0; i < 5; i++) clock();
        
        // PDI reads from mailbox
        std::cout << "  PDI reading from mailbox...\n";
        pdi_read(0x1000);
        
        // Check that mailbox_full is cleared
        status = cfg_read(REG_STATUS);
        std::cout << "  Status after read: 0x" << std::hex << status << std::dec << "\n";
        check_pass("Mailbox cleared after read (bit 3 = 0)", (status & (1 << STAT_MAILBOX_FULL)) == 0);
        check_pass("Read event occurred (bit 1)", (status & (1 << STAT_IRQ_READ)) != 0);
    }
    
    // Test 2: 3-buffer mode regression
    void test_3buffer_mode() {
        std::cout << "\n=== TEST 2: 3-Buffer Mode Regression ===\n";
        
        reset();
        configure_3buffer(0x2000, 64, true);  // ECAT writes
        
        // Initial status
        uint16_t status = cfg_read(REG_STATUS);
        std::cout << "  Initial status: 0x" << std::hex << status << std::dec << "\n";
        
        // Write from ECAT
        std::cout << "  EtherCAT writing to buffer...\n";
        ecat_write(0x2000, 0x55);
        
        // Check status - should have buffer_written set (bit 2)
        status = cfg_read(REG_STATUS);
        std::cout << "  Status after write: 0x" << std::hex << status << std::dec << "\n";
        check_pass("Write event in 3-buffer mode (bit 0)", (status & (1 << STAT_IRQ_WRITE)) != 0);
        
        // Note: In 3-buffer mode, bit 3 is "buffer full", not mailbox full
        // The buffer_written flag (bit 2) should be set
        check_pass("Buffer written flag (bit 2)", (status & (1 << STAT_BUFFER_WRITTEN)) != 0);
    }
    
    // Test 3: Status bit verification
    void test_status_bits() {
        std::cout << "\n=== TEST 3: Status Register Bit Positions ===\n";
        
        reset();
        
        std::cout << "  Verifying ETG.1000 compliant bit positions:\n";
        std::cout << "    Bit 0: IRQ Write\n";
        std::cout << "    Bit 1: IRQ Read\n";
        std::cout << "    Bit 2: Buffer Written (3-buffer mode)\n";
        std::cout << "    Bit 3: Mailbox Full (mailbox mode) / Buffer Full (3-buffer)\n";
        
        // Test mailbox mode bit 3
        configure_mailbox(0x3000, 32, true);
        ecat_write(0x3000, 0xAA);
        
        uint16_t status = cfg_read(REG_STATUS);
        check_pass("Bit 3 set in mailbox mode", (status & 0x08) != 0);
        
        // Reset and test 3-buffer mode bit 2
        reset();
        configure_3buffer(0x4000, 32, true);
        ecat_write(0x4000, 0xBB);
        
        status = cfg_read(REG_STATUS);
        check_pass("Bit 2 set in 3-buffer mode", (status & 0x04) != 0);
    }
    
    // Test 4: Mailbox direction (PDI writes)
    void test_mailbox_pdi_writes() {
        std::cout << "\n=== TEST 4: Mailbox Mode - PDI Writes ===\n";
        
        reset();
        configure_mailbox(0x5000, 64, false);  // PDI writes mailbox
        
        // Initial status
        uint16_t status = cfg_read(REG_STATUS);
        check_pass("Initial mailbox not full", (status & (1 << STAT_MAILBOX_FULL)) == 0);
        
        // PDI writes to mailbox
        std::cout << "  PDI writing to mailbox...\n";
        dut->pdi_req = 1;
        dut->pdi_wr = 1;
        dut->pdi_addr = 0x5000;
        dut->pdi_wdata = 0x77;
        clock();
        
        // Wait for memory access
        int timeout = 20;
        while (!dut->mem_req && timeout > 0) {
            clock();
            timeout--;
        }
        
        if (dut->mem_req) {
            dut->mem_ack = 1;
            clock();
            dut->mem_ack = 0;
        }
        
        // Wait for ack
        timeout = 20;
        while (!dut->pdi_ack && timeout > 0) {
            clock();
            timeout--;
        }
        
        dut->pdi_req = 0;
        clock();
        
        // Check mailbox full
        status = cfg_read(REG_STATUS);
        std::cout << "  Status after PDI write: 0x" << std::hex << status << std::dec << "\n";
        check_pass("Mailbox full after PDI write", (status & (1 << STAT_MAILBOX_FULL)) != 0);
    }
    
    void run_all_tests() {
        std::cout << "==========================================\n";
        std::cout << "Sync Manager Testbench\n";
        std::cout << "==========================================\n";
        
        test_mailbox_write_read();
        test_3buffer_mode();
        test_status_bits();
        test_mailbox_pdi_writes();
        
        std::cout << "\n==========================================\n";
        std::cout << "Test Summary:\n";
        std::cout << "  PASSED: " << test_pass_count << "\n";
        std::cout << "  FAILED: " << test_fail_count << "\n";
        std::cout << "==========================================\n";
        
        if (test_fail_count > 0) {
            std::cout << "SOME TESTS FAILED!\n";
        } else {
            std::cout << "All tests passed!\n";
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    SyncManagerTB* tb = new SyncManagerTB();
    tb->run_all_tests();
    
    delete tb;
    return 0;
}
