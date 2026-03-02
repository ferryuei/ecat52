# EtherCAT IP Core Testbenches

This directory contains Verilator-based testbenches for verifying P0 critical functions of the EtherCAT IP Core.

## Overview

The testbenches are written in C++ and use Verilator for fast, cycle-accurate simulation. Each testbench focuses on a specific P0 module and includes comprehensive test scenarios.

## Available Testbenches

### 1. Frame Receiver Test (`tb_frame_receiver.cpp`)
Tests the EtherCAT frame receiver module including:
- **FPRD** (Fixed Physical Read) command parsing
- **BWR** (Broadcast Write) command handling  
- **LRD** (Logical Read) command processing
- Address matching (station, alias, broadcast)
- Working counter handling
- Frame forwarding

**Module Under Test**: `ecat_frame_receiver.sv`

### 2. AL State Machine Test (`tb_al_statemachine.cpp`)
Tests the Application Layer state machine including:
- Normal transitions: Init → Pre-Op → Safe-Op → Op
- Error condition handling
- Watchdog timeout detection
- State-dependent enable signals (SM, FMMU, PDI)
- AL status code generation

**Module Under Test**: `ecat_al_statemachine.sv`

### 3. Register Map Test (`tb_register_map.cpp`)
Tests the ESC register map including:
- Device information registers (read-only)
- Station address configuration
- AL Control/Status register operation
- DL Control register operation
- IRQ mask/request registers with clear-on-read
- Register read/write with byte-enable

**Module Under Test**: `ecat_register_map.sv`

## Prerequisites

### Required Software
- **Verilator** >= 4.0 (5.0+ recommended)
  ```bash
  sudo apt install verilator
  ```
- **GCC/G++** with C++11 support
- **Make**

### Verify Installation
```bash
verilator --version
```

## Quick Start

### Build All Testbenches
```bash
cd /mnt/d/ECAT/run
make all
```

### Run All Tests
```bash
cd /mnt/d/ECAT/run
make run
```

### Run Individual Tests
```bash
cd /mnt/d/ECAT/run
make run_frame_receiver
make run_al_statemachine
make run_register_map
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `all` | Build all testbenches (default) |
| `run` | Build and run all testbenches |
| `run_frame_receiver` | Run frame receiver test only |
| `run_al_statemachine` | Run AL state machine test only |
| `run_register_map` | Run register map test only |
| `lint` | Run Verilator lint check on P0 modules |
| `check` | Syntax check all RTL files |
| `clean` | Remove build directory |
| `distclean` | Remove build and waves directories |
| `help` | Show help message |

## Build Output

Build artifacts are placed in the `run/` directory:
- `run/build/` - Compiled testbench executables and object files
  - `tb_frame_receiver.exe`
  - `tb_al_statemachine.exe`
  - `tb_register_map.exe`
- `run/waves/` - VCD waveform files (if enabled)

## Test Output

Each testbench produces console output showing:
- Test progress and phases
- Register read/write operations
- State transitions
- Pass/Fail status for each test scenario
- Statistics and counters

Example output:
```
==========================================
EtherCAT Frame Receiver Testbench
==========================================
[INFO] Reset complete

=== TEST 1: FPRD (Fixed Physical Read) ===
[INFO] Sending frame (30 bytes)
  Byte   0: 0x1c [SOF]
  Byte   1: 0x10
  ...
[INFO] Frame receiver statistics:
  RX Frame Count: 1
  RX Error Count: 0

==========================================
All tests complete!
==========================================
```

## Extending Testbenches

### Adding New Test Cases

To add a new test to an existing testbench:

```cpp
void test_new_feature() {
    std::cout << "\n=== TEST: New Feature ===\n";
    
    // Setup test conditions
    dut->some_signal = test_value;
    
    // Perform operations
    clock();
    
    // Check results
    if (dut->output_signal == expected) {
        std::cout << "  [PASS] Test passed\n";
    } else {
        std::cout << "  [FAIL] Test failed\n";
    }
}

// Add to run_all_tests()
void run_all_tests() {
    // ...existing tests...
    test_new_feature();
}
```

### Creating New Testbenches

To create a testbench for a new module:

1. Create `tb_<module_name>.cpp` in this directory
2. Follow the existing testbench structure
3. Add the new target to `Makefile`:
   ```makefile
   tb_<module_name>: $(BUILD_DIR) $(WAVE_DIR)
       $(VERILATOR) $(VERILATOR_FLAGS) <module_name> \
           --Mdir $(BUILD_DIR)/obj_$@ \
           -o ../$@.exe \
           $(RTL_FILES) \
           $(RTL_DIR)/<module_name>.sv \
           $(TB_DIR)/$@.cpp
   ```

## Waveform Generation

To enable VCD waveform generation (currently disabled for speed):

1. Uncomment trace initialization in testbench:
   ```cpp
   #include <verilated_vcd_c.h>
   
   VerilatedVcdC* tfp = new VerilatedVcdC;
   dut->trace(tfp, 99);
   tfp->open("waves/<testname>.vcd");
   
   // In clock() function:
   tfp->dump(main_time);
   
   // In destructor:
   tfp->close();
   ```

2. View waveforms:
   ```bash
   gtkwave waves/<testname>.vcd
   ```

## Troubleshooting

### Compilation Errors

**Error**: `verilator: command not found`
```bash
sudo apt install verilator
```

**Error**: Missing include files
- Check that RTL files are in `../rtl/` directory
- Verify `+incdir+../rtl` path in Makefile

### Runtime Errors

**Assertion failures**: Check that:
- Input signals are properly initialized
- Clock and reset sequences are correct
- State machine has stabilized before checking outputs

### Lint Warnings

Run lint check to see warnings:
```bash
make lint
```

Common warnings:
- `UNUSED`: Signals declared but not used (safe to ignore if intentional)
- `UNDRIVEN`: Signals not driven (check if input is connected)
- `WIDTH`: Bit width mismatch (verify signal widths)

## Performance Notes

- Verilator simulations are **10-100x faster** than Verilog simulators
- Typical test execution time: **< 1 second** per testbench
- Use `--trace` only when debugging (adds overhead)
- Consider `-O3` optimization for large simulations

## Test Coverage

### Currently Tested
- ✅ Frame parsing and command decoding
- ✅ AL state machine transitions
- ✅ Register read/write operations
- ✅ Error detection and status codes
- ✅ Watchdog timeout handling

### Not Yet Tested
- ⏳ Frame transmitter (CRC calculation, multi-port)
- ⏳ FMMU address translation
- ⏳ Sync Manager buffer swapping
- ⏳ PDI AVALON interface
- ⏳ Integrated system-level tests

## Contributing

When adding new tests:
1. Follow existing code style
2. Add descriptive test names
3. Include pass/fail indicators
4. Document test scenarios in comments
5. Update this README

## References

- **Verilator Manual**: https://verilator.org/guide/latest/
- **EtherCAT Spec**: ETG.1000 (see doc/ directory)
- **Module Documentation**: See doc/P0_IMPLEMENTATION_SUMMARY.md

## License

Same as the main EtherCAT IP Core project.
