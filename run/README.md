# EtherCAT IP Core - Simulation Run Directory

This directory is the working directory for running Verilator simulations.

## Quick Start

```bash
# Build all testbenches
make all

# Run all tests
make run

# Run individual test
make run_frame_receiver
```

## Directory Contents

- `Makefile` - Main build and simulation control
- `build/` - Generated during build (executables and object files)
- `waves/` - Generated during simulation (VCD waveform files)

## Available Targets

```bash
make help              # Show all available targets
make all               # Build all testbenches
make run               # Build and run all tests
make run_<test>        # Run specific test
make lint              # Run Verilator lint check
make check             # Syntax check all RTL
make clean             # Remove build artifacts
make distclean         # Clean everything
```

## File Locations

- **RTL Source**: `../rtl/` - SystemVerilog/Verilog modules
- **Testbenches**: `../tb/` - C++ testbench files
- **Documentation**: `../doc/` - Project documentation
- **VHDL Reference**: `../vhdl/` - Original VHDL source

## Build Output

Testbench executables are created in `build/`:
- `build/tb_frame_receiver.exe`
- `build/tb_al_statemachine.exe`
- `build/tb_register_map.exe`

## Notes

- All simulation commands should be run from this directory
- Build artifacts are self-contained in `build/` and `waves/`
- Run `make clean` to remove generated files
- See `../tb/README.md` for detailed testbench documentation
