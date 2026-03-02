// ============================================================================
// EtherCAT CoE (CANopen over EtherCAT) Handler Testbench
// Tests SDO Upload/Download operations per ETG.1000
// ============================================================================

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vecat_coe_handler.h"
#include <iostream>
#include <iomanip>

class CoEHandlerTB {
public:
    Vecat_coe_handler* dut;
    VerilatedVcdC* trace;
    uint64_t sim_time;
    int test_passed;
    int test_failed;
    
    CoEHandlerTB() {
        dut = new Vecat_coe_handler;
        trace = nullptr;
        sim_time = 0;
        test_passed = 0;
        test_failed = 0;
    }
    
    ~CoEHandlerTB() {
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
        dut->coe_request = 0;
        dut->coe_service = 0;
        dut->coe_index = 0;
        dut->coe_subindex = 0;
        dut->coe_data_in = 0;
        dut->coe_data_length = 0;
        dut->pdi_obj_rdata = 0;
        dut->pdi_obj_ack = 0;
        dut->pdi_obj_error = 0;
        
        for (int i = 0; i < 10; i++) tick();
        
        dut->rst_n = 1;
        tick();
    }
    
    // Send SDO Upload request (read object)
    void sdo_upload(uint16_t index, uint8_t subindex) {
        dut->coe_request = 1;
        dut->coe_service = 0x40;  // Upload init request
        dut->coe_index = index;
        dut->coe_subindex = subindex;
        tick();
        dut->coe_request = 0;
        
        // Wait for response
        int timeout = 100;
        while (!dut->coe_response_ready && timeout-- > 0) {
            tick();
        }
    }
    
    // Send SDO Download request (write object)
    void sdo_download(uint16_t index, uint8_t subindex, uint32_t data, uint8_t length) {
        dut->coe_request = 1;
        // Select expedited download based on length
        switch (length) {
            case 1: dut->coe_service = 0x2F; break;
            case 2: dut->coe_service = 0x2B; break;
            case 3: dut->coe_service = 0x27; break;
            default: dut->coe_service = 0x23; break;
        }
        dut->coe_index = index;
        dut->coe_subindex = subindex;
        dut->coe_data_in = data;
        dut->coe_data_length = length;
        tick();
        dut->coe_request = 0;
        
        // Wait for response
        int timeout = 100;
        while (!dut->coe_response_ready && timeout-- > 0) {
            tick();
        }
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
    
    void test_device_type_read() {
        std::cout << "\n=== Test: Read Device Type (0x1000) ===" << std::endl;
        reset();
        
        sdo_upload(0x1000, 0);
        
        check(dut->coe_response_ready == 1, "Response ready");
        check(dut->coe_abort_code == 0, "No abort");
        std::cout << "  Device Type: 0x" << std::hex << dut->coe_response_data << std::dec << std::endl;
    }
    
    void test_error_register_read() {
        std::cout << "\n=== Test: Read Error Register (0x1001) ===" << std::endl;
        reset();
        
        sdo_upload(0x1001, 0);
        
        check(dut->coe_response_ready == 1, "Response ready");
        check(dut->coe_abort_code == 0, "No abort");
        std::cout << "  Error Register: 0x" << std::hex << dut->coe_response_data << std::dec << std::endl;
    }
    
    void test_identity_object() {
        std::cout << "\n=== Test: Read Identity Object (0x1018) ===" << std::endl;
        reset();
        
        // Read number of entries (subindex 0)
        sdo_upload(0x1018, 0);
        check(dut->coe_response_ready == 1, "Subindex 0 response");
        std::cout << "  Number of entries: " << (int)dut->coe_response_data << std::endl;
        
        // Read Vendor ID (subindex 1)
        sdo_upload(0x1018, 1);
        check(dut->coe_response_ready == 1, "Vendor ID response");
        std::cout << "  Vendor ID: 0x" << std::hex << dut->coe_response_data << std::dec << std::endl;
        
        // Read Product Code (subindex 2)
        sdo_upload(0x1018, 2);
        check(dut->coe_response_ready == 1, "Product Code response");
        std::cout << "  Product Code: 0x" << std::hex << dut->coe_response_data << std::dec << std::endl;
        
        // Read Revision (subindex 3)
        sdo_upload(0x1018, 3);
        check(dut->coe_response_ready == 1, "Revision response");
        std::cout << "  Revision: 0x" << std::hex << dut->coe_response_data << std::dec << std::endl;
        
        // Read Serial Number (subindex 4)
        sdo_upload(0x1018, 4);
        check(dut->coe_response_ready == 1, "Serial Number response");
        std::cout << "  Serial Number: 0x" << std::hex << dut->coe_response_data << std::dec << std::endl;
    }
    
    void test_invalid_object_abort() {
        std::cout << "\n=== Test: Invalid Object Abort ===" << std::endl;
        reset();
        
        // Try to read non-existent object
        sdo_upload(0x9999, 0);
        
        check(dut->coe_response_ready == 1, "Response ready");
        check(dut->coe_abort_code != 0, "Abort code set");
        std::cout << "  Abort Code: 0x" << std::hex << dut->coe_abort_code << std::dec << std::endl;
        // Abort code should be 0x06020000 (Object does not exist)
        check(dut->coe_abort_code == 0x06020000, "Correct abort code (object not found)");
    }
    
    void test_invalid_subindex_abort() {
        std::cout << "\n=== Test: Invalid Subindex Abort ===" << std::endl;
        reset();
        
        // Try to read invalid subindex of 0x1018
        sdo_upload(0x1018, 99);
        
        check(dut->coe_response_ready == 1, "Response ready");
        check(dut->coe_abort_code != 0, "Abort code set");
        std::cout << "  Abort Code: 0x" << std::hex << dut->coe_abort_code << std::dec << std::endl;
        // Abort code should be 0x06090011 (Subindex does not exist)
        check(dut->coe_abort_code == 0x06090011, "Correct abort code (subindex not found)");
    }
    
    void test_write_to_readonly() {
        std::cout << "\n=== Test: Write to Read-Only Object ===" << std::endl;
        reset();
        
        // Try to write to Device Type (0x1000) which is read-only
        sdo_download(0x1000, 0, 0x12345678, 4);
        
        check(dut->coe_response_ready == 1, "Response ready");
        check(dut->coe_abort_code != 0, "Abort code set");
        std::cout << "  Abort Code: 0x" << std::hex << dut->coe_abort_code << std::dec << std::endl;
        // Abort code should be 0x06010002 (Attempt to write read-only object)
    }
    
    void run_all_tests() {
        test_device_type_read();
        test_error_register_read();
        test_identity_object();
        test_invalid_object_abort();
        test_invalid_subindex_abort();
        test_write_to_readonly();
        
        std::cout << "\n========================================" << std::endl;
        std::cout << "CoE Handler Test Summary:" << std::endl;
        std::cout << "  Passed: " << test_passed << std::endl;
        std::cout << "  Failed: " << test_failed << std::endl;
        std::cout << "========================================" << std::endl;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    CoEHandlerTB tb;
    tb.enable_trace("tb_coe_handler.vcd");
    
    tb.run_all_tests();
    
    return tb.test_failed > 0 ? 1 : 0;
}
