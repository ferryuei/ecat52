// ============================================================================
// EtherCAT Core - Type Definitions and Constants
// Extracted from VHDL ICL3476 entity (main core architecture)
// ============================================================================

`ifndef ECAT_CORE_DEFINES_VH
`define ECAT_CORE_DEFINES_VH

// ============================================================================
// EtherCAT Port Configuration
// ============================================================================
`define UCM1063_POS2 2              // Number of ports (max 8)
`define MAX_PORTS 8

// ============================================================================
// Clock Configuration Indices
// ============================================================================
`define XCC1632 0                   // Port 0 clock index
`define JCC1633 1                   // Port 1 clock index
`define PCC1634 2                   // Port 2 clock index
`define KCC1635 3                   // Port 3 clock index
`define TCC1636 4                   // ECAT clock index
`define QCC1637 5                   // PDI clock index
`define VCC1638 6                   // DC clock index
`define WCC1639 7                   // Reserved

// ============================================================================
// Delay Compensation Bit Positions
// ============================================================================
`define OCC1069 3:0                 // Delay value bits
`define JCC1070 4                   // Zero delay flag
`define ACC1071 5                   // Unit delay flag
`define ECC1072 6                   // Multi delay flag
`define RCC1073 7                   // Negative delay flag

// ============================================================================
// Feature Vector Bit Positions
// ============================================================================
`define CF_1076  0                  // Core function enable
`define MF_1078  1                  // Master mode
`define DF_1084  2                  // DC function
`define JF_1096  3                  // ECAT initialization
`define QF_1081  4                  // SYNC0 enable
`define CF_1080  5                  // SYNC1 enable
`define WF_1136  6                  // Swap ports
`define KF_1132  7                  // GigaCAT mode (1000Mbps)
`define XF_1131  8                  // Enhanced link detection
`define PF_1181  9                  // Port 0 delay comp disable
`define DF_1182  10                 // Port 1 delay comp disable
`define SF_1150  11                 // PDI disabled
`define FF_1151  12                 // PDI type bit 0
`define XF_1158  13                 // PDI type bit 1
`define SF_1162  14                 // PDI type bit 2
`define BF_1163  15                 // PDI type bit 3
`define NF_1167  16                 // MII mode
`define XF_1169  17                 // RMII mode
`define KF_1170  18                 // RGMII mode
`define WF_1074  19                 // Enhanced PHY mode

// ============================================================================
// Clock Divider Values (in ps)
// ============================================================================
`define CLK_8NS    8000             // 8ns = 125MHz
`define CLK_40NS   40000            // 40ns = 25MHz

// ============================================================================
// Complex Type Equivalents (using SystemVerilog syntax)
// ============================================================================

// Record type for clock reset structure
typedef struct packed {
    logic       dcl2015;            // Main reset
    logic       kcl2017;            // Secondary reset  
    logic       ocl2019;            // Tertiary reset
    logic       bcl2022;            // Quaternary reset
    logic [3:0] fcl2024;            // Port resets
    logic       xcl2028;            // ECAT reset
    logic       tcl2030;            // PDI reset
    logic       dcl2032;            // DC reset
    logic [7:0] ycl2036;            // Port specific resets
} xtr2010_t;

// Record type for system control
typedef struct packed {
    logic       abi2011;            // System enable
    logic       qbi2012;            // Bus enable
    logic       obi2013;            // Memory enable
    logic       pcl2014;            // Clock enable
    logic       dcl2015;            // Reset
    logic       ccl2016;            // Config enable
    logic       kcl2017;            // Interrupt enable
    logic       jcl2018;            // DMA enable
    logic       ocl2019;            // Status enable
    logic       ocl2020;            // Error enable
    logic       gcl2021;            // Debug enable
    logic       bcl2022;            // Test enable
    logic [7:0] ocl2023;            // Port enable
    logic [3:0] fcl2024;            // PHY enable
    logic [7:0] ncl2025;            // Port link status
    logic       icl2026;            // Link change
    logic       dcl2027;            // DC event
    logic       xcl2028;            // ECAT event
    logic       xcl2029;            // PDI event
    logic       tcl2030;            // Mailbox event
    logic       xcl2031;            // Error event
    logic       dcl2032;            // Sync event
    logic       kcl2033;            // Process data event
    logic       xcl2034;            // CoE event
    logic [7:0] acl2035;            // Status bits
    logic [7:0] ycl2036;            // Port status
    logic       dcl2037;            // PHY status
    logic       icl2038;            // Memory status
    logic [7:0] fcl2039;            // Port RX status
    logic [7:0] pcl2040;            // Port TX status
    logic       vcl2041;            // DMA status
} xtr2010_full_t;

// Record type for synchronization structure
typedef struct packed {
    logic [3:0] vrg1994;            // Clock ready flags
    logic       nfr1995;            // Reference clock ready
    logic       qec1996;            // ECAT clock ready
    logic       eec1997;            // Secondary clock ready
    logic       vec1998;            // Tertiary clock ready
    logic       jfa1999;            // Clock A ready
    logic       ufa2000;            // Clock B ready
    logic       mfa2001;            // Clock C ready
    logic       mfa2002;            // Clock D ready
    logic       cpd2003;            // Port 0 clock ready
    logic       gpd2004;            // Port 1 clock ready
    logic       upd2005;            // Port 2 clock ready
    logic [7:0] lpd2006;            // Port clock ready array
    logic [7:0] lpd2007;            // Port PLL lock array
} ets1993_t;

`endif // ECAT_CORE_DEFINES_VH
