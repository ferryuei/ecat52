# EtherCAT IP Core User Specification

**Version**: 1.0  
**Date**: February 6, 2026  
**Compliance**: ETG.1000 (~85%)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Top-Level Ports](#2-top-level-ports)
3. [Module Architecture](#3-module-architecture)
4. [Functional Description](#4-functional-description)
5. [Register Map](#5-register-map)
6. [Integration Guide](#6-integration-guide)
7. [Simulation Examples](#7-simulation-examples)
8. [Appendix](#8-appendix)

---

## 1. Overview

### 1.1 Introduction

The EtherCAT IP Core is a fully synthesizable RTL implementation of an EtherCAT Slave Controller (ESC) compliant with ETG.1000 specification. It provides a complete solution for implementing EtherCAT slave devices on FPGA platforms.

### 1.2 Features

| Feature | Description |
|---------|-------------|
| **Protocol Support** | Full EtherCAT frame processing (all datagram commands) |
| **FMMU** | 8 Field bus Memory Management Units |
| **SyncManager** | 8 Sync Managers with 3-buffer mechanism |
| **AL State Machine** | Complete state transitions with error handling |
| **Distributed Clock** | SYNC0/SYNC1 outputs, Latch inputs |
| **Mailbox Protocols** | CoE, FoE, EoE, SoE, VoE |
| **Cable Redundancy** | Line and ring topology support |
| **Hot Connect** | Explicit Device ID support |
| **PDI Interface** | Avalon-MM (32-bit) |

### 1.3 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `FEATURE_VECTOR_SIZE` | 256 | Feature vector width |
| `PDI_TYPE` | "AVALON" | PDI interface type |
| `PDI_DATA_WIDTH` | 32 | PDI data bus width |
| `PDI_ADDR_WIDTH` | 16 | PDI address width |
| `PHY_COUNT` | 2 | Number of Ethernet PHYs |
| `PHY_TYPE` | "MII" | PHY interface type |
| `CLK_FREQ_HZ` | 50000000 | System clock frequency |
| `ECAT_CLK_FREQ_HZ` | 25000000 | EtherCAT clock frequency |
| `NUM_FMMU` | 8 | Number of FMMUs |
| `NUM_SM` | 8 | Number of SyncManagers |
| `DP_RAM_SIZE` | 4096 | Process data RAM size (bytes) |
| `DC_SUPPORT` | 1 | Enable Distributed Clock |
| `VENDOR_ID` | 0x00000000 | Vendor identification |
| `PRODUCT_CODE` | 0x00000000 | Product code |
| `REVISION_NUM` | 0x00010000 | Revision number |
| `SERIAL_NUM` | 0x00000001 | Serial number |

---

## 2. Top-Level Ports

### 2.1 System Interfaces

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `sys_rst_n` | Input | 1 | Active-low system reset |
| `sys_clk` | Input | 1 | System clock (50 MHz typical) |
| `ecat_clk` | Input | 1 | EtherCAT clock (25 MHz) |
| `ecat_clk_ddr` | Input | 1 | DDR clock for PHY (2x ecat_clk) |

### 2.2 Process Data Interface (Avalon-MM)

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `pdi_clk` | Input | 1 | PDI clock domain |
| `pdi_address` | Input | 16 | Register/memory address |
| `pdi_read` | Input | 1 | Read request |
| `pdi_readdata` | Output | 32 | Read data |
| `pdi_readdatavalid` | Output | 1 | Read data valid |
| `pdi_write` | Input | 1 | Write request |
| `pdi_writedata` | Input | 32 | Write data |
| `pdi_byteenable` | Input | 4 | Byte enable mask |
| `pdi_waitrequest` | Output | 1 | Wait request (flow control) |
| `pdi_irq` | Output | 1 | Interrupt request |

### 2.3 Ethernet PHY Interfaces

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `phy_tx_clk` | Output | PHY_COUNT | TX clock to PHYs |
| `phy_tx_en` | Output | PHY_COUNT | TX enable |
| `phy_tx_er` | Output | PHY_COUNT | TX error |
| `phy_tx_data` | Output | PHY_COUNT×8 | TX data (8-bit MII) |
| `phy_rx_clk` | Input | PHY_COUNT | RX clock from PHYs |
| `phy_rx_dv` | Input | PHY_COUNT | RX data valid |
| `phy_rx_er` | Input | PHY_COUNT | RX error |
| `phy_rx_data` | Input | PHY_COUNT×8 | RX data (8-bit MII) |
| `phy_mdc` | Output | 1 | MDIO clock |
| `phy_mdio_o` | Output | 1 | MDIO data out |
| `phy_mdio_oe` | Output | 1 | MDIO output enable |
| `phy_mdio_i` | Input | 1 | MDIO data in |
| `phy_reset_n` | Output | PHY_COUNT | PHY reset (active-low) |

### 2.4 EEPROM Interface (I2C)

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `eeprom_scl_o` | Output | 1 | I2C clock output |
| `eeprom_scl_oe` | Output | 1 | I2C clock output enable |
| `eeprom_scl_i` | Input | 1 | I2C clock input |
| `eeprom_sda_o` | Output | 1 | I2C data output |
| `eeprom_sda_oe` | Output | 1 | I2C data output enable |
| `eeprom_sda_i` | Input | 1 | I2C data input |

### 2.5 Distributed Clock Interface

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `dc_latch0_in` | Input | 1 | Latch0 input signal |
| `dc_latch1_in` | Input | 1 | Latch1 input signal |
| `dc_sync0_out` | Output | 1 | SYNC0 output pulse |
| `dc_sync1_out` | Output | 1 | SYNC1 output pulse |

### 2.6 LED Outputs

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `led_link` | Output | PHY_COUNT | Link status per port |
| `led_act` | Output | PHY_COUNT | Activity indicator per port |
| `led_run` | Output | 1 | Run state indicator |
| `led_err` | Output | 1 | Error state indicator |

---

## 3. Module Architecture

### 3.1 Block Diagram

```
                              ┌─────────────────────────────────────────────────────────────┐
                              │                    ethercat_ipcore_top                       │
                              │                                                              │
  ┌─────────┐    ┌──────────┐ │  ┌──────────────┐    ┌─────────────┐    ┌───────────────┐  │
  │  PHY 0  │◄──►│   PHY    │◄┼─►│    Frame     │◄──►│   Register  │◄──►│     PDI       │◄─┼──► Host CPU
  │  PHY 1  │    │Interface │ │  │  Receiver    │    │     Map     │    │   (Avalon)    │  │
  └─────────┘    └──────────┘ │  └──────┬───────┘    └──────┬──────┘    └───────────────┘  │
                              │         │                    │                              │
                              │         ▼                    ▼                              │
                              │  ┌──────────────┐    ┌─────────────┐                        │
                              │  │    Frame     │    │     AL      │                        │
                              │  │ Transmitter  │    │State Machine│                        │
                              │  └──────────────┘    └─────────────┘                        │
                              │         │                    │                              │
                              │         ▼                    ▼                              │
                              │  ┌──────────────┐    ┌─────────────┐    ┌───────────────┐  │
                              │  │    Port      │    │    FMMU     │◄──►│   SyncMgr     │  │
                              │  │ Controller   │    │   (×8)      │    │    (×8)       │  │
                              │  └──────────────┘    └─────────────┘    └───────────────┘  │
                              │         │                    │                │             │
                              │         ▼                    ▼                ▼             │
                              │  ┌──────────────┐    ┌─────────────────────────────────┐   │
                              │  │   Cable      │    │          Process RAM            │   │
                              │  │ Redundancy   │    │           (4KB)                 │   │
                              │  └──────────────┘    └─────────────────────────────────┘   │
                              │                                                              │
  ┌─────────┐    ┌──────────┐ │  ┌──────────────┐    ┌─────────────┐    ┌───────────────┐  │
  │ EEPROM  │◄──►│   SII    │◄┼─►│   Mailbox    │◄──►│    CoE      │    │     DC        │◄─┼──► SYNC/Latch
  │ (I2C)   │    │Controller│ │  │   Handler    │    │   Handler   │    │   Module      │  │
  └─────────┘    └──────────┘ │  └──────┬───────┘    └─────────────┘    └───────────────┘  │
                              │         │                                                   │
                              │         ├────────────┬────────────┬────────────┐           │
                              │         ▼            ▼            ▼            ▼           │
                              │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
                              │  │   FoE    │ │   EoE    │ │   SoE    │ │   VoE    │      │
                              │  │ Handler  │ │ Handler  │ │ Handler  │ │ Handler  │      │
                              │  └──────────┘ └──────────┘ └──────────┘ └──────────┘      │
                              │                                                              │
                              └─────────────────────────────────────────────────────────────┘
```

### 3.2 Module List

| Module | File | Lines | Priority | Description |
|--------|------|-------|----------|-------------|
| `ethercat_ipcore_top` | ethercat_ipcore_top.v | ~800 | - | Top-level integration |
| `ecat_frame_receiver` | ecat_frame_receiver.sv | ~450 | P0 | EtherCAT frame parsing |
| `ecat_frame_transmitter` | ecat_frame_transmitter.sv | ~300 | P0 | Frame forwarding and CRC |
| `ecat_register_map` | ecat_register_map.sv | ~900 | P0 | ESC register implementation |
| `ecat_al_statemachine` | ecat_al_statemachine.sv | ~450 | P0 | Application Layer state machine |
| `ecat_fmmu` | ecat_fmmu.sv | ~450 | P0 | FMMU with error codes |
| `ecat_fmmu_array` | ecat_fmmu.sv | ~100 | P0 | 8-FMMU aggregator |
| `ecat_sync_manager` | ecat_sync_manager.sv | ~530 | P0 | SyncManager with 3-buffer |
| `ecat_sync_manager_array` | ecat_sync_manager.sv | ~100 | P0 | 8-SM aggregator |
| `ecat_pdi_avalon` | ecat_pdi_avalon.sv | ~330 | P0 | Avalon-MM PDI interface |
| `ecat_dpram` | ecat_dpram.sv | ~150 | P0 | Dual-port process RAM |
| `ecat_port_controller` | ecat_port_controller.sv | ~400 | P1 | Port management, redundancy |
| `ecat_mailbox_handler` | ecat_mailbox_handler.sv | ~400 | P1 | Mailbox protocol dispatcher |
| `ecat_coe_handler` | ecat_coe_handler.sv | ~350 | P1 | CANopen SDO protocol |
| `ecat_foe_handler` | ecat_foe_handler.sv | ~340 | P1 | Firmware update protocol |
| `ecat_eoe_handler` | ecat_eoe_handler.sv | ~380 | P1 | Ethernet tunneling |
| `ecat_soe_handler` | ecat_soe_handler.sv | ~120 | P1 | SERCOS profile (stub) |
| `ecat_voe_handler` | ecat_voe_handler.sv | ~150 | P1 | Vendor specific (stub) |
| `ecat_sii_controller` | ecat_sii_controller.sv | ~300 | P1 | EEPROM I2C controller |
| `ecat_dc` | ecat_dc.sv | ~400 | P2 | Distributed Clock |
| `ecat_mdio_master` | ecat_mdio_master.sv | ~200 | P2 | PHY MDIO management |
| `ecat_phy_interface` | ecat_phy_interface.v | ~300 | P2 | MII/RMII PHY interface |
| `ecat_core_main` | ecat_core_main.sv | ~480 | - | Core interconnect |

### 3.3 Clock Domains

| Clock | Frequency | Usage |
|-------|-----------|-------|
| `sys_clk` | 50 MHz | System logic, registers |
| `ecat_clk` | 25 MHz | EtherCAT frame processing |
| `ecat_clk_ddr` | 50 MHz | DDR PHY interface |
| `pdi_clk` | User-defined | PDI interface to host |
| `phy_rx_clk[n]` | 25 MHz | PHY receive clock |

---

## 4. Functional Description

### 4.1 EtherCAT Frame Processing

#### 4.1.1 Supported Commands

| Command | OpCode | Description |
|---------|--------|-------------|
| APRD | 0x01 | Auto-increment Physical Read |
| APWR | 0x02 | Auto-increment Physical Write |
| APRW | 0x03 | Auto-increment Physical Read/Write |
| FPRD | 0x04 | Fixed Physical Read |
| FPWR | 0x05 | Fixed Physical Write |
| FPRW | 0x06 | Fixed Physical Read/Write |
| BRD | 0x07 | Broadcast Read |
| BWR | 0x08 | Broadcast Write |
| BRW | 0x09 | Broadcast Read/Write |
| LRD | 0x0A | Logical Read |
| LWR | 0x0B | Logical Write |
| LRW | 0x0C | Logical Read/Write |
| ARMW | 0x0D | Auto-increment Read Multiple Write |
| FRMW | 0x0E | Fixed Read Multiple Write |

#### 4.1.2 Address Matching

- **Station Address**: Configured via register 0x0010
- **Station Alias**: Configured via register 0x0012
- **Explicit Device ID**: Configured via register 0x0050 (for Hot Connect)
- **Broadcast**: Always matches for BRD/BWR/BRW commands

### 4.2 AL State Machine

```
                    ┌─────────────────────────────────────────────┐
                    │                                             │
                    ▼                                             │
              ┌──────────┐                                        │
    Reset ───►│   INIT   │◄───────────────────────────────────────┤
              │  (0x01)  │                                        │
              └────┬─────┘                                        │
                   │ EEPROM Loaded                                │
                   ▼                                              │
              ┌──────────┐      ┌──────────┐                      │
              │  PREOP   │◄────►│   BOOT   │                      │
              │  (0x02)  │      │  (0x03)  │                      │
              └────┬─────┘      └──────────┘                      │
                   │ SM Valid                                     │
                   ▼                                              │
              ┌──────────┐                                        │
              │ SAFEOP   │────────────────────────────────────────┤
              │  (0x04)  │                                        │
              └────┬─────┘                                        │
                   │ PDI Operational                              │
                   ▼                                              │
              ┌──────────┐                                        │
              │    OP    │────────────────────────────────────────┘
              │  (0x08)  │         Error / Master Request
              └──────────┘
```

#### 4.2.1 State Transition Conditions

| Transition | Condition |
|------------|-----------|
| INIT → PREOP | EEPROM loaded successfully |
| INIT → BOOT | Bootstrap request from master |
| PREOP → SAFEOP | All required SyncManagers configured and valid |
| SAFEOP → OP | PDI reports operational, DC synchronized (if enabled) |
| Any → INIT | Error condition or master request |

#### 4.2.2 Error States

| State | Code | Description |
|-------|------|-------------|
| INIT+Err | 0x11 | Error in Init state |
| PREOP+Err | 0x12 | Error in Pre-Operational state |
| SAFEOP+Err | 0x14 | Error in Safe-Operational state |

### 4.3 FMMU (Field bus Memory Management Unit)

#### 4.3.1 Configuration (per FMMU, 16 bytes)

| Offset | Size | Description |
|--------|------|-------------|
| 0x00 | 4 | Logical Start Address |
| 0x04 | 2 | Length |
| 0x06 | 1 | Logical Start Bit |
| 0x07 | 1 | Logical End Bit |
| 0x08 | 2 | Physical Start Address |
| 0x0A | 1 | Physical Start Bit |
| 0x0B | 1 | Type (01=Read, 02=Write, 03=R/W) |
| 0x0C | 1 | Activate (01=Enable) |
| 0x0D-0x0F | 3 | Reserved |

#### 4.3.2 Error Codes (Register 0x0F00-0x0F07)

| Bit | Description |
|-----|-------------|
| 0 | Logical address out of range |
| 1 | Physical address out of range |
| 2 | Length error |
| 3 | Bit alignment error |
| 4 | Type mismatch (read/write permission) |
| 5 | FMMU not enabled |
| 6-7 | Reserved |

### 4.4 SyncManager

#### 4.4.1 Configuration (per SM, 8 bytes)

| Offset | Size | Description |
|--------|------|-------------|
| 0x00 | 2 | Physical Start Address |
| 0x02 | 2 | Length |
| 0x04 | 1 | Control |
| 0x05 | 1 | Status |
| 0x06 | 1 | Activate |
| 0x07 | 1 | PDI Control |

#### 4.4.2 Operating Modes

| Mode | Control[1:0] | Description |
|------|--------------|-------------|
| 0 | 00 | 3-Buffer (Mailbox) |
| 1 | 01 | Reserved |
| 2 | 10 | 2-Buffer (Process Data) |
| 3 | 11 | Reserved |

### 4.5 Mailbox Protocols

#### 4.5.1 Protocol Types

| Type | Code | Status | Description |
|------|------|--------|-------------|
| ERR | 0x01 | ✅ | Error Response |
| AoE | 0x02 | ❌ | ADS over EtherCAT |
| EoE | 0x03 | ✅ | Ethernet over EtherCAT |
| CoE | 0x04 | ✅ | CANopen over EtherCAT |
| FoE | 0x05 | ✅ | File over EtherCAT |
| SoE | 0x06 | 🔶 | Servo over EtherCAT (stub) |
| VoE | 0x0F | 🔶 | Vendor Specific (stub) |

#### 4.5.2 FoE Operations

| OpCode | Value | Description |
|--------|-------|-------------|
| RRQ | 0x01 | Read Request |
| WRQ | 0x02 | Write Request |
| DATA | 0x03 | Data Packet |
| ACK | 0x04 | Acknowledge |
| ERROR | 0x05 | Error |
| BUSY | 0x06 | Busy |

#### 4.5.3 EoE Frame Types

| Type | Value | Description |
|------|-------|-------------|
| FRAG_DATA | 0x0 | Fragment Data |
| SET_IP_REQ/RSP | 0x3/0x4 | Set IP Parameters |
| GET_IP_REQ/RSP | 0x7/0x8 | Get IP Parameters |
| SET_FILTER_REQ/RSP | 0x5/0x6 | Set Address Filter |
| GET_FILTER_REQ/RSP | 0x9/0xA | Get Address Filter |

### 4.6 Cable Redundancy

#### 4.6.1 Modes

| Mode | Value | Description |
|------|-------|-------------|
| OFF | 0 | Redundancy disabled |
| LINE | 1 | Line redundancy (dual master) |
| RING | 2 | Ring redundancy (closed loop) |

#### 4.6.2 State Machine

| State | Description |
|-------|-------------|
| RED_IDLE | Redundancy inactive |
| RED_INIT | Initializing redundancy |
| RED_PRIMARY | Operating on primary path |
| RED_BACKUP | Operating on backup path |
| RED_FAILOVER | Switching paths |
| RED_RECOVERY | Recovering to primary |

#### 4.6.3 Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| Failover Time | ~10ms | Time to switch to backup path |
| Recovery Time | ~50ms | Time to switch back to primary |

### 4.7 Distributed Clock

#### 4.7.1 Features

- 64-bit system time counter
- SYNC0 and SYNC1 output pulses
- Latch0 and Latch1 input capture
- Configurable cycle time

#### 4.7.2 Registers

| Address | Size | Description |
|---------|------|-------------|
| 0x0910 | 8 | System Time |
| 0x0920 | 8 | System Time Offset |
| 0x0928 | 4 | System Time Delay |
| 0x0990 | 8 | SYNC0 Start Time |
| 0x09A0 | 4 | SYNC0 Cycle Time |
| 0x0998 | 8 | SYNC1 Start Time |
| 0x09A4 | 4 | SYNC1 Cycle Time |

---

## 5. Register Map

### 5.1 Overview

| Address Range | Description |
|---------------|-------------|
| 0x0000-0x000F | Device Information (RO) |
| 0x0010-0x0013 | Station Address |
| 0x0020-0x0031 | Write Protection |
| 0x0050-0x0053 | Explicit Device ID |
| 0x0100-0x0113 | DL Control/Status |
| 0x0120-0x0137 | AL Control/Status |
| 0x0140-0x0155 | PDI Control |
| 0x0200-0x0227 | Event Registers |
| 0x0300-0x0313 | Error Counters |
| 0x0400-0x0443 | Watchdog |
| 0x0500-0x050F | EEPROM Interface |
| 0x0510-0x0517 | MII Management |
| 0x0600-0x067F | FMMU Configuration (8×16 bytes) |
| 0x0800-0x083F | SyncManager Configuration (8×8 bytes) |
| 0x0900-0x09FF | Distributed Clock |
| 0x0F00-0x0F07 | FMMU Error Codes |
| 0x1000-0x1FFF | Process Data RAM |

### 5.2 Device Information (0x0000-0x000F)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0000 | 1 | Type | RO | Device type (0x05 = ESC) |
| 0x0001 | 1 | Revision | RO | Revision number |
| 0x0002 | 2 | Build | RO | Build number |
| 0x0004 | 1 | FMMU Count | RO | Number of FMMUs (8) |
| 0x0005 | 1 | SM Count | RO | Number of SMs (8) |
| 0x0006 | 1 | RAM Size | RO | RAM size in KB (4) |
| 0x0007 | 1 | Port Descriptor | RO | Port configuration |
| 0x0008 | 2 | ESC Features | RO | Supported features |

### 5.3 Station Address (0x0010-0x0013)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0010 | 2 | Configured Station Address | R/W | Station address from master |
| 0x0012 | 2 | Station Alias | R/W | Alias address (from EEPROM) |

### 5.4 Write Protection (0x0020-0x0031)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0020 | 1 | Write Register Enable | R/W | Write enable bits |
| 0x0021 | 1 | Write Register Protect | R/W | Write protection mask |
| 0x0030 | 1 | ESC Write Enable | R/W | ESC write enable |
| 0x0031 | 1 | ESC Write Protect | R/W | ESC write protection |

### 5.5 Explicit Device ID (0x0050-0x0053)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0050 | 4 | Explicit Device ID | R/W | 32-bit unique device identifier |

### 5.6 DL Control/Status (0x0100-0x0113)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0100 | 2 | DL Control | R/W | Data Link control |
| 0x0110 | 2 | DL Status | RO | Data Link status |

**DL Control Bits:**

| Bit | Name | Description |
|-----|------|-------------|
| 0 | Loop Port 0 | Enable loop on port 0 |
| 1 | Loop Port 1 | Enable loop on port 1 |
| 2 | Loop Port 2 | Enable loop on port 2 |
| 3 | Loop Port 3 | Enable loop on port 3 |
| 5 | RX FIFO Size | RX FIFO size selection |
| 6 | EtherCAT Enable | Enable EtherCAT processing |
| 7 | Alias Enable | Enable station alias addressing |

### 5.7 AL Control/Status (0x0120-0x0137)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0120 | 2 | AL Control | R/W | AL state request from master |
| 0x0130 | 2 | AL Status | RO | Current AL state |
| 0x0134 | 2 | AL Status Code | RO | Error code |

**AL Status Codes:**

| Code | Description |
|------|-------------|
| 0x0000 | No error |
| 0x0001 | Unspecified error |
| 0x0011 | Invalid requested state change |
| 0x0012 | Unknown requested state |
| 0x0013 | Bootstrap not supported |
| 0x0016 | Invalid mailbox configuration |
| 0x001A | Invalid sync manager configuration |
| 0x001B | No valid inputs available |
| 0x001C | No valid outputs |
| 0x001D | Synchronization error |
| 0x001E | Sync manager watchdog |
| 0x0020 | Invalid sync manager types |
| 0x0021 | Invalid output configuration |
| 0x0022 | Invalid input configuration |
| 0x0030 | Invalid DC sync configuration |
| 0x0031 | Invalid DC latch configuration |
| 0x0032 | PLL error |
| 0x0033 | DC sync I/O error |

### 5.8 Watchdog (0x0400-0x0443)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0400 | 2 | Watchdog Divider | R/W | Clock divider (default: 2500) |
| 0x0410 | 2 | Watchdog Time PDI | R/W | PDI watchdog time |
| 0x0420 | 2 | Watchdog Time SM | R/W | SyncManager watchdog time |
| 0x0440 | 2 | Watchdog Status | RO | Current watchdog status |
| 0x0442 | 1 | Watchdog Counter SM | RO | SM watchdog expire count |
| 0x0443 | 1 | Watchdog Counter PDI | RO | PDI watchdog expire count |

### 5.9 FMMU Error Codes (0x0F00-0x0F07)

| Address | Size | Name | Access | Description |
|---------|------|------|--------|-------------|
| 0x0F00 | 1 | FMMU 0 Error | RO | FMMU 0 error code |
| 0x0F01 | 1 | FMMU 1 Error | RO | FMMU 1 error code |
| ... | ... | ... | ... | ... |
| 0x0F07 | 1 | FMMU 7 Error | RO | FMMU 7 error code |

---

## 6. Integration Guide

### 6.1 Clock Generation

```verilog
// Example: Using PLL for clock generation
// Input: 50 MHz oscillator
// Outputs: sys_clk (50 MHz), ecat_clk (25 MHz), ecat_clk_ddr (50 MHz)

pll_inst pll (
    .inclk0     (clk_50mhz),
    .c0         (sys_clk),        // 50 MHz
    .c1         (ecat_clk),       // 25 MHz
    .c2         (ecat_clk_ddr),   // 50 MHz, 90° phase shift
    .locked     (pll_locked)
);

assign sys_rst_n = pll_locked & external_rst_n;
```

### 6.2 PHY Connection (MII)

```verilog
// PHY 0 connection
assign phy0_tx_en   = phy_tx_en[0];
assign phy0_tx_data = phy_tx_data[7:0];
assign phy_rx_dv[0] = phy0_rx_dv;
assign phy_rx_data[7:0] = phy0_rx_data;

// PHY 1 connection
assign phy1_tx_en   = phy_tx_en[1];
assign phy1_tx_data = phy_tx_data[15:8];
assign phy_rx_dv[1] = phy1_rx_dv;
assign phy_rx_data[15:8] = phy1_rx_data;

// MDIO (shared between PHYs)
assign phy_mdio = phy_mdio_oe ? phy_mdio_o : 1'bz;
assign phy_mdio_i = phy_mdio;
```

### 6.3 EEPROM Connection (I2C)

```verilog
// I2C open-drain implementation
assign eeprom_scl = eeprom_scl_oe ? eeprom_scl_o : 1'bz;
assign eeprom_scl_i = eeprom_scl;

assign eeprom_sda = eeprom_sda_oe ? eeprom_sda_o : 1'bz;
assign eeprom_sda_i = eeprom_sda;

// External pull-ups required (4.7k typical)
```

### 6.4 Host CPU Interface

```c
// C code example for PDI access (Avalon-MM)

#define ECAT_BASE       0x10000000
#define ECAT_REG(addr)  (*(volatile uint32_t*)(ECAT_BASE + (addr)))

// Read AL Status
uint16_t al_status = ECAT_REG(0x0130) & 0xFFFF;

// Write AL Control
ECAT_REG(0x0120) = 0x0002;  // Request Pre-Operational

// Read process data
uint32_t data = ECAT_REG(0x1000);

// Write process data
ECAT_REG(0x1100) = output_value;

// Check interrupt
if (ECAT_REG(0x0220) & 0x0001) {
    // AL event occurred
    handle_al_event();
}
```

### 6.5 Instantiation Template

```verilog
ethercat_ipcore_top #(
    .VENDOR_ID          (32'h00001234),
    .PRODUCT_CODE       (32'hABCD0001),
    .REVISION_NUM       (32'h00010000),
    .SERIAL_NUM         (32'h00000001),
    .NUM_FMMU           (8),
    .NUM_SM             (8),
    .DP_RAM_SIZE        (4096),
    .DC_SUPPORT         (1),
    .PHY_COUNT          (2),
    .PHY_TYPE           ("MII")
) ecat_inst (
    // System
    .sys_rst_n          (sys_rst_n),
    .sys_clk            (sys_clk),
    .ecat_clk           (ecat_clk),
    .ecat_clk_ddr       (ecat_clk_ddr),
    
    // PDI (Avalon)
    .pdi_clk            (cpu_clk),
    .pdi_address        (cpu_addr[15:0]),
    .pdi_read           (cpu_read),
    .pdi_readdata       (cpu_readdata),
    .pdi_readdatavalid  (cpu_readdatavalid),
    .pdi_write          (cpu_write),
    .pdi_writedata      (cpu_writedata),
    .pdi_byteenable     (cpu_byteenable),
    .pdi_waitrequest    (cpu_waitrequest),
    .pdi_irq            (cpu_irq),
    
    // PHY
    .phy_tx_clk         (phy_tx_clk),
    .phy_tx_en          (phy_tx_en),
    .phy_tx_er          (phy_tx_er),
    .phy_tx_data        (phy_tx_data),
    .phy_rx_clk         (phy_rx_clk),
    .phy_rx_dv          (phy_rx_dv),
    .phy_rx_er          (phy_rx_er),
    .phy_rx_data        (phy_rx_data),
    .phy_mdc            (phy_mdc),
    .phy_mdio_o         (phy_mdio_o),
    .phy_mdio_oe        (phy_mdio_oe),
    .phy_mdio_i         (phy_mdio_i),
    .phy_reset_n        (phy_reset_n),
    
    // EEPROM
    .eeprom_scl_o       (eeprom_scl_o),
    .eeprom_scl_oe      (eeprom_scl_oe),
    .eeprom_scl_i       (eeprom_scl_i),
    .eeprom_sda_o       (eeprom_sda_o),
    .eeprom_sda_oe      (eeprom_sda_oe),
    .eeprom_sda_i       (eeprom_sda_i),
    
    // DC
    .dc_latch0_in       (dc_latch0),
    .dc_latch1_in       (dc_latch1),
    .dc_sync0_out       (dc_sync0),
    .dc_sync1_out       (dc_sync1),
    
    // LEDs
    .led_link           (led_link),
    .led_act            (led_act),
    .led_run            (led_run),
    .led_err            (led_err)
);
```

---

## 7. Simulation Examples

### 7.1 Directory Structure

```
ECAT/
├── rtl/                    # RTL source files
├── tb/                     # Testbenches
│   ├── tb_frame_receiver.cpp
│   ├── tb_al_statemachine.cpp
│   ├── tb_fmmu_error.cpp
│   ├── tb_coe_handler.cpp
│   ├── tb_port_controller.cpp
│   └── tb_sii_eeprom.cpp
├── run/                    # Simulation workspace
│   ├── Makefile
│   └── build/
└── doc/                    # Documentation
```

### 7.2 Building Testbenches

```bash
cd run/

# Build all testbenches
make all

# Build specific testbench
make tb_frame_receiver

# Run lint check
make lint

# Clean build artifacts
make clean
```

### 7.3 Running Simulations

```bash
# Run frame receiver test
./build/tb_frame_receiver.exe

# Run with VCD waveform output
./build/tb_fmmu_error.exe
# VCD file: tb_fmmu_error.vcd

# View waveforms with GTKWave
gtkwave tb_fmmu_error.vcd
```

### 7.4 Example Testbench (Frame Receiver)

```cpp
// tb_frame_receiver.cpp
#include <verilated.h>
#include "Vecat_frame_receiver.h"

class FrameReceiverTB {
public:
    Vecat_frame_receiver* dut;
    
    void tick() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    }
    
    void reset() {
        dut->rst_n = 0;
        for (int i = 0; i < 10; i++) tick();
        dut->rst_n = 1;
        tick();
    }
    
    void send_ecat_frame(uint8_t* frame, int len) {
        dut->rx_dv = 1;
        for (int i = 0; i < len; i++) {
            dut->rx_data = frame[i];
            tick();
        }
        dut->rx_dv = 0;
        tick();
    }
    
    void test_fprd_command() {
        // Build FPRD frame
        uint8_t frame[64];
        // ... frame construction ...
        
        send_ecat_frame(frame, 64);
        
        // Verify response
        assert(dut->wkc_increment == 1);
    }
};

int main() {
    FrameReceiverTB tb;
    tb.dut = new Vecat_frame_receiver;
    
    tb.reset();
    tb.test_fprd_command();
    
    printf("All tests passed!\n");
    return 0;
}
```

### 7.5 Test Coverage

| Module | Testbench | Tests | Pass Rate |
|--------|-----------|-------|-----------|
| Frame Receiver | tb_frame_receiver | 15 | 100% |
| AL State Machine | tb_al_statemachine | 12 | 100% |
| FMMU Error | tb_fmmu_error | 13 | 100% |
| CoE Handler | tb_coe_handler | 17 | 71% |
| Port Controller | tb_port_controller | 7 | 100% |
| SII EEPROM | tb_sii_eeprom | 6 | 67% |

---

## 8. Appendix

### 8.1 Revision History

| Version | Date | Author | Description |
|---------|------|--------|-------------|
| 1.0 | 2026-02-06 | - | Initial release |

### 8.2 References

- **ETG.1000**: EtherCAT Protocol Specification
- **ETG.1020**: EtherCAT Slave Controller Hardware Data Sheet
- **ETG.2000**: EtherCAT Conformance Test Tool Specification
- **IEC 61158-3-12**: Industrial communication networks - Part 3-12: Data-link layer service definition - Type 12 elements
- **IEC 61158-4-12**: Industrial communication networks - Part 4-12: Data-link layer protocol specification - Type 12 elements

### 8.3 Glossary

| Term | Definition |
|------|------------|
| AL | Application Layer |
| CoE | CANopen over EtherCAT |
| DC | Distributed Clock |
| DL | Data Link layer |
| EoE | Ethernet over EtherCAT |
| ESC | EtherCAT Slave Controller |
| FMMU | Field bus Memory Management Unit |
| FoE | File over EtherCAT |
| PDI | Process Data Interface |
| SM | SyncManager |
| SoE | Servo over EtherCAT |
| VoE | Vendor over EtherCAT |
| WKC | Working Counter |

### 8.4 File List

```
rtl/
├── ecat_pkg.vh                 # Package definitions
├── ecat_core_defines.vh        # Core constants
├── ethercat_ipcore_top.v       # Top-level module
├── ecat_frame_receiver.sv      # Frame reception
├── ecat_frame_transmitter.sv   # Frame transmission
├── ecat_register_map.sv        # ESC registers
├── ecat_al_statemachine.sv     # AL state machine
├── ecat_fmmu.sv                # FMMU + array
├── ecat_sync_manager.sv        # SyncManager + array
├── ecat_pdi_avalon.sv          # Avalon PDI
├── ecat_dpram.sv               # Process RAM
├── ecat_port_controller.sv     # Port management
├── ecat_mailbox_handler.sv     # Mailbox dispatcher
├── ecat_coe_handler.sv         # CoE protocol
├── ecat_foe_handler.sv         # FoE protocol
├── ecat_eoe_handler.sv         # EoE protocol
├── ecat_soe_handler.sv         # SoE protocol
├── ecat_voe_handler.sv         # VoE protocol
├── ecat_sii_controller.sv      # EEPROM I2C
├── ecat_dc.sv                  # Distributed Clock
├── ecat_mdio_master.sv         # PHY MDIO
├── ecat_phy_interface.v        # PHY interface
├── ecat_core_main.sv           # Core interconnect
├── ddr_stages.v                # DDR I/O
├── synchronizer.v              # CDC synchronizers
├── async_fifo.v                # Async FIFO
└── filelist.f                  # File list
```

---

**End of Document**
