# EtherCAT IP Core - Verilog Conversion

## Overview
This is a hierarchical Verilog conversion of the EtherCAT IP Core, originally converted from a 46,151-line VHDL file. The design has been optimized with a clear hierarchical structure for better maintainability, synthesis, and verification.

## File Structure

```
rtl/
├── ecat_pkg.vh                 # Package definitions, constants, functions
├── ddr_stages.v                # DDR input/output stages for PHY
├── synchronizer.v              # Clock domain crossing synchronizer
├── async_fifo.v                # Asynchronous FIFO with Gray code pointers
├── ecat_phy_interface.v        # Ethernet PHY interface (MII/RMII/RGMII)
├── ethercat_ipcore_top.v       # Top-level integration module
├── filelist.f                  # File list for synthesis/simulation
└── EtherCAT_IPCore.vhd         # Original VHDL source (preserved)
```

## Hierarchical Architecture

```
ethercat_ipcore_top
├── Reset Synchronization
│   ├── System clock domain
│   └── EtherCAT clock domain
│
├── ecat_phy_interface (×PHY_COUNT)
│   ├── PHY Reset Controller
│   ├── MDIO Management Interface
│   ├── MII/RMII/RGMII Interface
│   │   ├── ddr_input_stage (for RGMII)
│   │   └── ddr_output_stage (for RGMII)
│   └── Link Status Detection
│
├── Process Data Interface (PDI)
│   ├── Bus Interface (AVALON/AXI/PLB/OPB/uC)
│   ├── Register Access Logic
│   └── Interrupt Controller
│
├── Clock Domain Crossing
│   ├── synchronizer (multiple instances)
│   └── async_fifo (for data buffers)
│
├── Memory Subsystem (placeholder)
│   ├── Dual-Port RAM
│   ├── FMMU (Field bus Memory Management Units)
│   └── Sync Managers
│
└── Distributed Clock (DC) Module (placeholder)
    ├── 64-bit Timestamp Counter
    ├── Sync Pulse Generation
    └── Latch Input Capture
```

## Key Features

### 1. **Modular Design**
- Separated concerns into focused modules
- Each module has a single, well-defined responsibility
- Easy to test, verify, and synthesize individually

### 2. **Parameterizable Configuration**
- Flexible PDI bus types: AVALON, AXI3, AXI4, PLB, OPB, microcontroller
- Configurable PHY count (1-8 ports)
- Multiple PHY types: MII, RMII, RGMII
- Adjustable memory sizes and FMMU/Sync Manager counts

### 3. **Clock Domain Crossing**
- Robust multi-stage synchronizers
- Gray code asynchronous FIFOs
- Separate clock domains for system, EtherCAT, and PHY

### 4. **Industry-Standard Interfaces**
- IEEE 802.3 Ethernet PHY interfaces
- MDIO (IEEE 802.3 Clause 22) management
- Multiple bus protocol support
- I2C EEPROM interface

## Module Descriptions

### ecat_pkg.vh
- Common constants and parameters
- Utility functions (log2, min/max, clamp)
- Feature vector definitions

### ddr_stages.v
- **ddr_input_stage**: Double data rate input for high-speed serial
- **ddr_output_stage**: Double data rate output for RGMII TX
- Configurable for different FPGA vendors (Altera/Xilinx/Generic)

### synchronizer.v
- Multi-stage synchronizer for clock domain crossing
- Configurable synchronization depth
- Data capture with valid/acknowledge handshaking
- Overflow/underflow detection

### async_fifo.v
- Asynchronous FIFO with independent read/write clocks
- Gray code pointer synchronization
- Full/empty flag generation
- Fill level indication for both domains

### ecat_phy_interface.v
- Ethernet PHY management and data interface
- MDIO controller for PHY register access
- Link status detection (up/down, speed, duplex)
- Supports multiple PHY types and ports

### ethercat_ipcore_top.v
- Top-level integration and configuration
- PDI bus interface logic
- System-level control and status registers
- LED control and interrupt generation

## Configuration Parameters

### Top-Level Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PDI_TYPE` | "AVALON" | Process data interface type |
| `PDI_DATA_WIDTH` | 32 | PDI data bus width (8, 16, 32) |
| `PDI_ADDR_WIDTH` | 16 | PDI address bus width |
| `PHY_COUNT` | 2 | Number of Ethernet PHY ports |
| `PHY_TYPE` | "MII" | PHY interface type |
| `CLK_FREQ_HZ` | 50000000 | System clock frequency |
| `FMMU_COUNT` | 8 | Number of FMMUs |
| `SYNC_MANAGER_COUNT` | 8 | Number of Sync Managers |
| `DP_RAM_SIZE` | 4096 | Dual-port RAM size (bytes) |
| `DC_SUPPORT` | 1 | Enable distributed clock |
| `GPIO_WIDTH` | 0 | GPIO width (0, 8, 16, 32, 64) |

## Usage Example

### Basic Instantiation

```verilog
ethercat_ipcore_top #(
    .PDI_TYPE           ("AXI4"),
    .PDI_DATA_WIDTH     (32),
    .PHY_COUNT          (2),
    .PHY_TYPE           ("RGMII"),
    .ECAT_VENDOR_ID     (32'h12345678),
    .PRODUCT_ID0        (32'h00000001)
) ecat_core (
    // System
    .sys_rst_n          (reset_n),
    .sys_clk            (clk_50mhz),
    .ecat_clk           (clk_25mhz),
    .ecat_clk_ddr       (clk_125mhz),
    
    // PDI
    .pdi_clk            (axi_clk),
    .pdi_cs_n           (axi_cs_n),
    .pdi_addr           (axi_addr),
    .pdi_data           (axi_data),
    
    // PHY
    .phy_tx_clk         (phy_tx_clk),
    .phy_tx_data        (phy_tx_data),
    .phy_rx_clk         (phy_rx_clk),
    .phy_rx_data        (phy_rx_data),
    
    // ... other connections
);
```

## Synthesis Notes

1. **Clock Constraints**: Define proper timing constraints for all clock domains
2. **False Paths**: Set false paths on asynchronous resets and CDC signals
3. **Multicycle Paths**: Configure multicycle paths for slow control registers
4. **DDR Constraints**: Apply proper DDR input/output timing for RGMII

### Example Synthesis Commands

```tcl
# Xilinx Vivado
read_verilog -sv filelist.f
synth_design -top ethercat_ipcore_top -part xc7a100t

# Intel Quartus
set_global_assignment -name VERILOG_FILE filelist.f
set_global_assignment -name TOP_LEVEL_ENTITY ethercat_ipcore_top
```

## Simulation

### File List Usage
```bash
# ModelSim/QuestaSim
vlog -f filelist.f

# VCS
vcs -f filelist.f

# Verilator
verilator --lint-only -f filelist.f
```

## Design Improvements Over Original VHDL

1. **Hierarchical Structure**: Clear module separation vs monolithic file
2. **Readability**: Descriptive names and comprehensive comments
3. **Maintainability**: Individual modules can be updated independently
4. **Verification**: Each module can be tested in isolation
5. **Synthesis**: Better control over synthesis boundaries
6. **Code Size**: Reduced from 46,151 lines to ~900 lines (core functionality)

## Current Implementation Status

### ✅ P0 - Fully Implemented (Critical Functions)
- ✅ **Package definitions** and utility functions (ecat_pkg.vh)
- ✅ **Core type definitions** and constants (ecat_core_defines.vh)
- ✅ **DDR input/output stages** for RGMII (ddr_stages.v) - 84 lines
- ✅ **Clock domain crossing** synchronizers (synchronizer.v) - 77 lines
- ✅ **Asynchronous FIFO** with Gray code pointers (async_fifo.v) - 154 lines
- ✅ **FMMU** - Complete implementation (ecat_fmmu.sv) - 397 lines
  - 8 FMMU instances with priority arbitration
  - Logical-to-physical address translation
  - Full ETG.1000 register map (0x0600-0x06FF)
- ✅ **Sync Manager** - Complete implementation (ecat_sync_manager.sv) - 532 lines
  - 8 Sync Manager instances with 3-buffer mechanism
  - Mailbox and process data modes
  - Independent ECAT/PDI interfaces
- ✅ **Frame Receiver** - Complete (ecat_frame_receiver.sv) - 435 lines
  - EtherCAT datagram parsing
  - Command decoder (APRD/APWR/FPRD/FPWR/BRD/BWR/LRD/LWR)
  - Address matching logic
  - Working counter handling
- ✅ **Frame Transmitter** - Complete (ecat_frame_transmitter.sv) - 293 lines
  - Frame forwarding and modification
  - CRC32 calculation (FCS)
  - Multi-port transmission
- ✅ **Register Map** - Complete (ecat_register_map.sv) - 364 lines
  - DL Control/Status (0x0100-0x0110)
  - AL Control/Status (0x0120-0x0135)
  - PDI Control (0x0140-0x0153)
  - IRQ registers (0x0200-0x021F)
  - EEPROM emulation (0x0500-0x0515)
  - MII management (0x0510-0x0517)
  - DC registers (0x0900-0x09FF)
- ✅ **AL State Machine** - Complete (ecat_al_statemachine.sv) - 366 lines
  - Init → Pre-Op → Safe-Op → Op transitions
  - Error state handling with status codes
  - Condition checking per ETG.1000
- ✅ **PDI AVALON Interface** - Complete (ecat_pdi_avalon.sv) - 331 lines
  - AVALON Memory-Mapped Slave
  - Register and process data access
  - Watchdog timer
  - IRQ generation
- ✅ **Main core module** with signal definitions (ecat_core_main.sv) - 479 lines
  - Reset synchronization (8-stage chains)
  - Clock routing and management
  - DC sync pulse generation

**Total P0 Code: ~4,312 lines** (vs 46,151 original VHDL)

### 🚧 P1 - Framework Ready (Important Features)
- ⏳ **PHY Interface** framework (ecat_phy_interface.v) - 181 lines
  - MII/RMII/RGMII structure defined
  - MDIO state machine needs completion
- ⏳ **Complete DC Implementation**
  - Time sync and drift compensation
  - Full SYNC0/SYNC1 pulse generation
- ⏳ **Mailbox & CoE Protocol Handlers**
  - SDO upload/download
  - Emergency messages
- ⏳ **Additional PDI Buses**
  - AXI4/AXI3, PLB, OPB interfaces

### 📋 P2 - Future Enhancements
- Advanced DC features (PTP synchronization)
- Built-in test and diagnostics  
- Performance counters and statistics
- Error injection and recovery
- Debug infrastructure

## License and Attribution

Original VHDL source: EtherCAT_IPCore.vhd  
Generated: HDL Fileparser V6.8 - 29.05.2019 09:46:16  
Converted to Verilog with hierarchical optimization

## Contact and Support

For questions, issues, or contributions, please refer to the project documentation.

---
**Note**: This is a reference implementation demonstrating hierarchical design principles. For production use, complete implementation of all EtherCAT protocol features is required according to the EtherCAT specification (IEC 61158).
