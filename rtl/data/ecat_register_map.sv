// ============================================================================
// EtherCAT Register Map (ESC Registers)
// Implements ETG.1000 compliant register address space
// P0 Critical Function - Full Implementation
// ============================================================================

`include "ecat_pkg.vh"

module ecat_register_map #(
    parameter VENDOR_ID = 32'h00000000,
    parameter PRODUCT_CODE = 32'h00000000,
    parameter REVISION_NUM = 32'h00010000,
    parameter SERIAL_NUM = 32'h00000001,
    parameter NUM_FMMU = 8,
    parameter NUM_SM = 8
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // Register access interface (from frame receiver)
    input  wire                     reg_req,
    input  wire                     reg_wr,           // 1=write, 0=read
    input  wire [15:0]              reg_addr,
    input  wire [15:0]              reg_wdata,
    input  wire [1:0]               reg_be,           // Byte enable
    output reg  [15:0]              reg_rdata,
    output reg                      reg_ack,
    
    // AL (Application Layer) Control interface
    output reg  [4:0]               al_control,       // AL control from master (5-bit)
    output reg                      al_control_changed,
    input  wire [4:0]               al_status,        // AL status from state machine (5-bit)
    input  wire [15:0]              al_status_code,   // Error code
    
    // DL (Data Link) Control interface
    output reg                      dl_control_fwd_en,     // Forwarding enable
    output reg                      dl_control_temp_loop,  // Temporary loop
    input  wire [15:0]              dl_status,        // From port logic
    
    // Port configuration
    output reg  [3:0]               port_enable,
    input  wire [3:0]               port_link_status,
    input  wire [3:0]               port_loop_status,
    
    // Station address
    output reg  [15:0]              station_address,
    output reg  [15:0]              station_alias,
    
    // IRQ (Interrupt) registers
    output reg  [15:0]              irq_mask,
    input  wire [15:0]              irq_request,
    
    // Sync Manager / FMMU status
    input  wire [7:0]               sm_status,
    input  wire [7:0]               fmmu_status,
    input  wire [NUM_FMMU*8-1:0]    fmmu_error_codes,     // FMMU error codes (0x0F00-0x0F07)
    
    // Distributed Clock
    input  wire [63:0]              dc_system_time,
    output reg  [31:0]              dc_sync0_cycle,
    output reg  [31:0]              dc_sync1_cycle,
    
    // Statistics (packed as 4x8=32 bits each)
    input  wire [31:0]              rx_error_counter,
    input  wire [31:0]              lost_link_counter,
    
    // FMMU Configuration outputs (directly drive FMMU array)
    output reg  [NUM_FMMU*32-1:0]   fmmu_log_start_addr,  // 8 x 32-bit
    output reg  [NUM_FMMU*16-1:0]   fmmu_length,          // 8 x 16-bit
    output reg  [NUM_FMMU*3-1:0]    fmmu_log_start_bit,   // 8 x 3-bit
    output reg  [NUM_FMMU*3-1:0]    fmmu_log_end_bit,     // 8 x 3-bit
    output reg  [NUM_FMMU*16-1:0]   fmmu_phys_start_addr, // 8 x 16-bit
    output reg  [NUM_FMMU*3-1:0]    fmmu_phys_start_bit,  // 8 x 3-bit
    output reg  [NUM_FMMU-1:0]      fmmu_read_enable,     // 8 x 1-bit
    output reg  [NUM_FMMU-1:0]      fmmu_write_enable,    // 8 x 1-bit
    output reg  [NUM_FMMU-1:0]      fmmu_enable,          // 8 x 1-bit
    
    // Sync Manager Configuration outputs (directly drive SM array)
    output reg  [NUM_SM*16-1:0]     sm_phys_start_addr,   // 8 x 16-bit
    output reg  [NUM_SM*16-1:0]     sm_length,            // 8 x 16-bit
    output reg  [NUM_SM*8-1:0]      sm_control,           // 8 x 8-bit
    output reg  [NUM_SM-1:0]        sm_enable,            // 8 x 1-bit
    output reg  [NUM_SM-1:0]        sm_repeat,            // 8 x 1-bit
    input  wire [NUM_SM*8-1:0]      sm_status_in,         // 8 x 8-bit status from SM

    // Sync Manager config mirror (for SM array)
    output reg                      sm_cfg_wr,
    output reg  [3:0]               sm_cfg_sel,
    output reg  [7:0]               sm_cfg_addr,
    output reg  [15:0]              sm_cfg_wdata,
    
    // Watchdog outputs
    output reg  [15:0]              watchdog_divider,
    output reg  [15:0]              watchdog_time_pdi,
    output reg  [15:0]              watchdog_time_sm,
    output reg                      watchdog_enable,
    input  wire                     watchdog_expired
);

    // ========================================================================
    // ETG.1000 Register Address Map - Complete Implementation
    // ========================================================================
    
    // Device Information (0x0000-0x000F) - Read Only
    localparam ADDR_TYPE           = 16'h0000;  // Device type (8-bit)
    localparam ADDR_REVISION       = 16'h0001;  // Revision (8-bit)
    localparam ADDR_BUILD          = 16'h0002;  // Build (16-bit)
    localparam ADDR_FMMU_NUM       = 16'h0004;  // Number of FMMUs (8-bit)
    localparam ADDR_SM_NUM         = 16'h0005;  // Number of SMs (8-bit)
    localparam ADDR_RAM_SIZE       = 16'h0006;  // RAM size kbyte (8-bit)
    localparam ADDR_PORT_DESC      = 16'h0007;  // Port descriptor (8-bit)
    localparam ADDR_FEATURES       = 16'h0008;  // ESC features (16-bit)
    
    // Station Address (0x0010-0x0013)
    localparam ADDR_STATION_ADR    = 16'h0010;  // Configured station address
    localparam ADDR_STATION_ALIAS  = 16'h0012;  // Station alias
    
    // Write Protection (0x0020-0x0021)
    localparam ADDR_WR_REG_ENABLE  = 16'h0020;  // Register write enable
    localparam ADDR_WR_REG_PROTECT = 16'h0021;  // Register write protection
    
    // ESC Write Protection (0x0030-0x0031)
    localparam ADDR_ESC_WR_ENABLE  = 16'h0030;
    localparam ADDR_ESC_WR_PROTECT = 16'h0031;
    
    // ESC Reset (0x0040-0x0041)
    localparam ADDR_ESC_RESET_ECAT = 16'h0040;
    localparam ADDR_ESC_RESET_PDI  = 16'h0041;
    
    // Explicit Device ID (0x0050-0x0053) - P0 Hot Connect Support
    localparam ADDR_EXPLICIT_DEV_ID = 16'h0050;  // Explicit Device ID (32-bit)
    
    // DL Control (0x0100-0x010F)
    localparam ADDR_DL_CONTROL     = 16'h0100;  // DL control (16-bit)
    localparam ADDR_DL_USER        = 16'h0102;  // Reserved
    localparam ADDR_DL_STATUS      = 16'h0110;  // DL status (16-bit)
    
    // AL Control/Status (0x0120-0x013F)
    localparam ADDR_AL_CONTROL     = 16'h0120;  // AL control (16-bit)
    localparam ADDR_AL_STATUS      = 16'h0130;  // AL status (16-bit)
    localparam ADDR_AL_STATUS_CODE = 16'h0134;  // AL status code (16-bit)
    
    // PDI Control (0x0140-0x015F)
    localparam ADDR_PDI_CONTROL    = 16'h0140;  // PDI control (8-bit)
    localparam ADDR_ESC_CONFIG     = 16'h0141;  // ESC configuration (8-bit)
    localparam ADDR_PDI_CONFIG     = 16'h0150;  // PDI config (8-bit)
    localparam ADDR_SYNC_LATCH_CFG = 16'h0151;  // Sync/Latch PDI config (8-bit)
    localparam ADDR_PDI_EXT_CFG    = 16'h0152;  // Extended PDI config (16-bit)
    
    // ECAT Event (0x0200-0x021F)
    localparam ADDR_ECAT_EVENT_MASK    = 16'h0200;  // ECAT event mask (16-bit)
    localparam ADDR_ECAT_EVENT_REQ     = 16'h0210;  // ECAT event request (16-bit)
    
    // AL Event (0x0220-0x0227)
    localparam ADDR_AL_EVENT_MASK  = 16'h0204;  // AL event mask
    localparam ADDR_AL_EVENT_REQ   = 16'h0220;  // AL event request
    
    // RX Error Counter (0x0300-0x030F)
    localparam ADDR_RX_ERR_CNT0    = 16'h0300;  // RX error port 0
    localparam ADDR_RX_ERR_CNT1    = 16'h0302;  // RX error port 1
    localparam ADDR_RX_ERR_CNT2    = 16'h0304;  // RX error port 2
    localparam ADDR_RX_ERR_CNT3    = 16'h0306;  // RX error port 3
    localparam ADDR_FWD_RX_ERR_CNT = 16'h0308;  // Forwarded RX error
    localparam ADDR_PROC_UNIT_ERR  = 16'h030C;  // Processing unit error
    localparam ADDR_PDI_ERROR_CNT  = 16'h030D;  // PDI error counter
    
    // Lost Link Counter (0x0310-0x0313)
    localparam ADDR_LOST_LINK_CNT0 = 16'h0310;
    localparam ADDR_LOST_LINK_CNT1 = 16'h0311;
    localparam ADDR_LOST_LINK_CNT2 = 16'h0312;
    localparam ADDR_LOST_LINK_CNT3 = 16'h0313;
    
    // Watchdog (0x0400-0x044F)
    localparam ADDR_WD_DIVIDER     = 16'h0400;  // Watchdog divider (16-bit)
    localparam ADDR_WD_TIME_PDI    = 16'h0410;  // Watchdog time PDI (16-bit)
    localparam ADDR_WD_TIME_SM     = 16'h0420;  // Watchdog time SM (16-bit)
    localparam ADDR_WD_STATUS      = 16'h0440;  // Watchdog status (16-bit)
    localparam ADDR_WD_CNT_SM      = 16'h0442;  // Watchdog counter SM (8-bit)
    localparam ADDR_WD_CNT_PDI     = 16'h0443;  // Watchdog counter PDI (8-bit)
    
    // SII (EEPROM) Interface (0x0500-0x050F)
    localparam ADDR_EEPROM_CONFIG  = 16'h0500;  // EEPROM configuration (8-bit)
    localparam ADDR_EEPROM_PDI_ACCESS = 16'h0501; // EEPROM PDI access state
    localparam ADDR_EEPROM_CONTROL = 16'h0502;  // EEPROM control/status (16-bit)
    localparam ADDR_EEPROM_ADDR    = 16'h0504;  // EEPROM address (32-bit)
    localparam ADDR_EEPROM_DATA    = 16'h0508;  // EEPROM data (64-bit)
    
    // MII Management (0x0510-0x0517)
    localparam ADDR_MII_CONTROL    = 16'h0510;  // MII control/status (8-bit)
    localparam ADDR_MII_PHY_ADDR   = 16'h0512;  // PHY address (8-bit)
    localparam ADDR_MII_PHY_REG    = 16'h0513;  // PHY register (8-bit)
    localparam ADDR_MII_PHY_DATA   = 16'h0514;  // PHY data (16-bit)
    localparam ADDR_MII_PHY_RW_ERR = 16'h0516;  // MII access state (8-bit)
    
    // FMMU (0x0600-0x06FF) - 8 FMMUs x 16 bytes each
    localparam ADDR_FMMU_BASE      = 16'h0600;
    // Per FMMU: +0x00 Log Start (32), +0x04 Length (16), +0x06 StartBit (8),
    //           +0x07 EndBit (8), +0x08 PhysStart (16), +0x0A PhysStartBit (8),
    //           +0x0B Type (8), +0x0C Activate (8), +0x0D-0x0F Reserved
    
    // Sync Manager (0x0800-0x087F) - 8 SMs x 8 bytes each
    localparam ADDR_SM_BASE        = 16'h0800;
    // Per SM: +0x00 PhysStart (16), +0x02 Length (16), +0x04 Control (8),
    //         +0x05 Status (8), +0x06 Activate (8), +0x07 PDI Control (8)
    
    // DC Registers (0x0900-0x09FF)
    localparam ADDR_DC_RECV_TIME0  = 16'h0900;  // Receive time port 0 (64-bit)
    localparam ADDR_DC_RECV_TIME1  = 16'h0908;  // Receive time port 1 (64-bit)
    localparam ADDR_DC_RECV_TIME2  = 16'h0910;  // Receive time port 2 (64-bit)
    localparam ADDR_DC_RECV_TIME3  = 16'h0918;  // Receive time port 3 (64-bit)
    localparam ADDR_DC_SYS_TIME    = 16'h0910;  // System time (64-bit) - alt location
    localparam ADDR_DC_LOCAL_TIME  = 16'h0918;  // Local system time (64-bit)
    localparam ADDR_DC_SYS_OFFSET  = 16'h0920;  // System time offset (64-bit)
    localparam ADDR_DC_SYS_DELAY   = 16'h0928;  // System time delay (32-bit)
    localparam ADDR_DC_SYS_DIFF    = 16'h092C;  // System time difference (32-bit)
    localparam ADDR_DC_SPEED_CNT   = 16'h0930;  // Speed counter start (16-bit)
    localparam ADDR_DC_SPEED_DIFF  = 16'h0932;  // Speed counter diff (16-bit)
    localparam ADDR_DC_FLT_DEPTH   = 16'h0934;  // System time diff filter (8-bit)
    localparam ADDR_DC_SPEED_FLT   = 16'h0935;  // Speed counter filter (8-bit)
    localparam ADDR_DC_CYC_UNIT    = 16'h0980;  // Cyclic unit control (8-bit)
    localparam ADDR_DC_ACTIVATION  = 16'h0981;  // DC activation (8-bit)
    localparam ADDR_DC_IMPULSE_LEN = 16'h0982;  // Sync impulse length (16-bit)
    localparam ADDR_DC_ACT_STATUS  = 16'h0984;  // DC activation status (8-bit)
    localparam ADDR_DC_SYNC0_STAT  = 16'h098E;  // SYNC0 status (8-bit)
    localparam ADDR_DC_SYNC1_STAT  = 16'h098F;  // SYNC1 status (8-bit)
    localparam ADDR_DC_SYNC0_START = 16'h0990;  // SYNC0 start time (64-bit)
    localparam ADDR_DC_SYNC1_START = 16'h0998;  // SYNC1 start time (64-bit)
    localparam ADDR_DC_SYNC0_CYCLE = 16'h09A0;  // SYNC0 cycle time (32-bit)
    localparam ADDR_DC_SYNC1_CYCLE = 16'h09A4;  // SYNC1 cycle time (32-bit)
    localparam ADDR_DC_LATCH0_CTRL = 16'h09A8;  // Latch0 control (8-bit)
    localparam ADDR_DC_LATCH1_CTRL = 16'h09A9;  // Latch1 control (8-bit)
    localparam ADDR_DC_LATCH0_STAT = 16'h09AE;  // Latch0 status (8-bit)
    localparam ADDR_DC_LATCH1_STAT = 16'h09AF;  // Latch1 status (8-bit)
    localparam ADDR_DC_LATCH0_POS  = 16'h09B0;  // Latch0 pos edge time (64-bit)
    localparam ADDR_DC_LATCH0_NEG  = 16'h09B8;  // Latch0 neg edge time (64-bit)
    localparam ADDR_DC_LATCH1_POS  = 16'h09C0;  // Latch1 pos edge time (64-bit)
    localparam ADDR_DC_LATCH1_NEG  = 16'h09C8;  // Latch1 neg edge time (64-bit)
    
    // FMMU Error Registers (0x0F00-0x0F07) - ETG.1000 Section 6.7.6
    localparam ADDR_FMMU_ERROR_BASE = 16'h0F00; // FMMU error codes (8 bytes)
    // One byte per FMMU:
    //   Bit 0: Logical address out of range
    //   Bit 1: Physical address out of range
    //   Bit 2: Length error
    //   Bit 3: Bit alignment error
    //   Bit 4: Type mismatch (read/write permission)
    //   Bit 5: FMMU not enabled
    //   Bit 6-7: Reserved
    
    // ========================================================================
    // Internal Registers - Device Constants
    // ========================================================================
    
    // Device info (read-only, hardcoded)
    localparam [7:0] DEVICE_TYPE = 8'h05;     // EtherCAT slave controller
    localparam [7:0] REVISION = 8'h01;
    localparam [15:0] BUILD = 16'h0001;
    localparam [7:0] FMMU_COUNT = NUM_FMMU[7:0];
    localparam [7:0] SM_COUNT = NUM_SM[7:0];
    localparam [7:0] RAM_SIZE = 8'h04;        // 4 KB
    localparam [7:0] PORT_DESC = 8'h0F;       // 4 ports MII
    localparam [15:0] ESC_FEATURES = 16'h0184; // DC, FMMU, SM support
    
    // ========================================================================
    // Internal Register Storage
    // ========================================================================
    
    // DL Control registers
    reg         dl_control_loop_port0;
    reg         dl_control_loop_port1;
    reg         dl_control_loop_port2;
    reg         dl_control_loop_port3;
    reg         dl_control_rx_fifo_size;
    reg         dl_control_ecat_ena;
    reg         dl_control_alias_ena;
    
    // Write protection
    reg [7:0]   wr_reg_enable;
    reg [7:0]   wr_reg_protect;
    reg [7:0]   esc_wr_enable;
    reg [7:0]   esc_wr_protect;
    
    // Explicit Device ID (P0 Hot Connect)
    reg [31:0]  explicit_device_id;
    reg         explicit_id_valid;
    
    // PDI Control
    reg [7:0]   pdi_control;
    reg [7:0]   esc_config;
    reg [7:0]   pdi_config;
    reg [7:0]   sync_latch_config;
    reg [15:0]  pdi_ext_config;
    
    // Event registers
    reg [15:0]  ecat_event_mask;
    reg [15:0]  ecat_event_req_latched;
    reg [15:0]  al_event_mask;
    reg [15:0]  al_event_req_latched;
    
    // Error counters (local writeable copies)
    reg [7:0]   rx_err_cnt [0:3];
    reg [7:0]   fwd_rx_err_cnt;
    reg [7:0]   proc_unit_err_cnt;
    reg [7:0]   pdi_error_cnt;
    reg [7:0]   lost_link_cnt [0:3];
    
    // Watchdog registers
    reg [7:0]   wd_cnt_sm;
    reg [7:0]   wd_cnt_pdi;
    reg [15:0]  wd_status;
    
    // EEPROM emulation
    reg [7:0]   eeprom_config_reg;
    reg [7:0]   eeprom_pdi_access;
    reg [15:0]  eeprom_control;
    reg [31:0]  eeprom_addr;
    reg [63:0]  eeprom_data;
    
    // MII Management
    reg [7:0]   mii_control;
    reg [7:0]   mii_phy_addr_reg;
    reg [7:0]   mii_phy_reg;
    reg [15:0]  mii_phy_data;
    reg [7:0]   mii_rw_err;
    
    // DC Extended registers
    reg [63:0]  dc_recv_time [0:3];
    reg [63:0]  dc_sys_offset;
    reg [31:0]  dc_sys_delay;
    reg [31:0]  dc_sys_diff;
    reg [15:0]  dc_speed_cnt_start;
    reg [15:0]  dc_speed_diff;
    reg [7:0]   dc_filter_depth;
    reg [7:0]   dc_speed_filter;
    reg [7:0]   dc_cyc_unit_ctrl;
    reg [7:0]   dc_activation;
    reg [15:0]  dc_impulse_len;
    reg [7:0]   dc_act_status;
    reg [7:0]   dc_sync0_status;
    reg [7:0]   dc_sync1_status;
    reg [63:0]  dc_sync0_start;
    reg [63:0]  dc_sync1_start;
    reg [7:0]   dc_latch0_ctrl;
    reg [7:0]   dc_latch1_ctrl;
    reg [7:0]   dc_latch0_status;
    reg [7:0]   dc_latch1_status;
    reg [63:0]  dc_latch0_pos;
    reg [63:0]  dc_latch0_neg;
    reg [63:0]  dc_latch1_pos;
    reg [63:0]  dc_latch1_neg;
    
    // IRQ latched
    reg [15:0]  irq_request_latched;
    
    // FMMU index calculation
    wire [2:0]  fmmu_idx = reg_addr[6:4];  // 0x0600 + idx*16
    wire [3:0]  fmmu_off = reg_addr[3:0];  // Offset within FMMU
    
    // SM index calculation
    wire [2:0]  sm_idx = reg_addr[5:3];    // 0x0800 + idx*8
    wire [2:0]  sm_off = reg_addr[2:0];    // Offset within SM
    
    // ========================================================================
    // Register Read Logic - Complete Implementation
    // ========================================================================
    
    // Address range detection
    wire addr_in_fmmu_range = (reg_addr >= ADDR_FMMU_BASE) && (reg_addr < ADDR_FMMU_BASE + 16'h0080);
    wire addr_in_sm_range = (reg_addr >= ADDR_SM_BASE) && (reg_addr < ADDR_SM_BASE + 16'h0040);
    wire addr_in_dc_range = (reg_addr >= 16'h0900) && (reg_addr < 16'h0A00);
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_rdata <= '0;
            reg_ack <= 1'b0;
            irq_request_latched <= '0;
            ecat_event_req_latched <= '0;
            al_event_req_latched <= '0;
        end else begin
            reg_ack <= 1'b0;
            
            if (reg_req && !reg_wr) begin
                reg_ack <= 1'b1;
                
                // Default
                reg_rdata <= 16'h0000;
                
                // Device Information (0x0000-0x000F)
                if (reg_addr == ADDR_TYPE) reg_rdata <= {REVISION, DEVICE_TYPE};
                else if (reg_addr == ADDR_BUILD) reg_rdata <= BUILD;
                else if (reg_addr == ADDR_FMMU_NUM) reg_rdata <= {8'h00, FMMU_COUNT};
                else if (reg_addr == ADDR_SM_NUM) reg_rdata <= {8'h00, SM_COUNT};
                else if (reg_addr == ADDR_RAM_SIZE) reg_rdata <= {PORT_DESC, RAM_SIZE};
                else if (reg_addr == ADDR_FEATURES) reg_rdata <= ESC_FEATURES;
                
                // Station Address (0x0010-0x0013)
                else if (reg_addr == ADDR_STATION_ADR) reg_rdata <= station_address;
                else if (reg_addr == ADDR_STATION_ALIAS) reg_rdata <= station_alias;
                
                // Write Protection (0x0020-0x0031)
                else if (reg_addr == ADDR_WR_REG_ENABLE) reg_rdata <= {8'h00, wr_reg_enable};
                else if (reg_addr == ADDR_WR_REG_PROTECT) reg_rdata <= {8'h00, wr_reg_protect};
                
                // ESC Write Protection (0x0030-0x0031)
                else if (reg_addr == ADDR_ESC_WR_ENABLE) reg_rdata <= {8'h00, esc_wr_enable};
                else if (reg_addr == ADDR_ESC_WR_PROTECT) reg_rdata <= {8'h00, esc_wr_protect};
                
                // Explicit Device ID (0x0050-0x0053) - P0 Hot Connect
                else if (reg_addr == ADDR_EXPLICIT_DEV_ID) reg_rdata <= explicit_device_id[15:0];
                else if (reg_addr == ADDR_EXPLICIT_DEV_ID + 16'h0002) reg_rdata <= explicit_device_id[31:16];
                
                // DL Control/Status (0x0100-0x0113)
                else if (reg_addr == ADDR_DL_CONTROL) begin
                    reg_rdata <= {8'h00, dl_control_alias_ena, dl_control_ecat_ena,
                                 dl_control_rx_fifo_size, 1'b0,
                                 dl_control_loop_port3, dl_control_loop_port2,
                                 dl_control_loop_port1, dl_control_loop_port0};
                end
                else if (reg_addr == ADDR_DL_STATUS) reg_rdata <= dl_status;
                
                // AL Control/Status (0x0120-0x0137)
                else if (reg_addr == ADDR_AL_CONTROL) reg_rdata <= {11'h000, al_control};
                else if (reg_addr == ADDR_AL_STATUS) reg_rdata <= {10'h000, al_status, 1'b0};
                else if (reg_addr == ADDR_AL_STATUS_CODE) reg_rdata <= al_status_code;
                
                // PDI (0x0140-0x0155)
                else if (reg_addr == ADDR_PDI_CONTROL) reg_rdata <= {esc_config, pdi_control};
                else if (reg_addr == ADDR_PDI_CONFIG) reg_rdata <= {sync_latch_config, pdi_config};
                else if (reg_addr == ADDR_PDI_EXT_CFG) reg_rdata <= pdi_ext_config;
                
                // Event registers (0x0200-0x0227)
                else if (reg_addr == ADDR_ECAT_EVENT_MASK) reg_rdata <= ecat_event_mask;
                else if (reg_addr == ADDR_AL_EVENT_MASK) reg_rdata <= al_event_mask;
                else if (reg_addr == ADDR_ECAT_EVENT_REQ) begin
                    reg_rdata <= ecat_event_req_latched;
                    ecat_event_req_latched <= '0;
                end
                else if (reg_addr == ADDR_AL_EVENT_REQ) begin
                    reg_rdata <= al_event_req_latched;
                    al_event_req_latched <= '0;
                end
                
                // Error Counters (0x0300-0x0313)
                else if (reg_addr == ADDR_RX_ERR_CNT0) reg_rdata <= {rx_err_cnt[1], rx_err_cnt[0]};
                else if (reg_addr == ADDR_RX_ERR_CNT2) reg_rdata <= {rx_err_cnt[3], rx_err_cnt[2]};
                else if (reg_addr == ADDR_FWD_RX_ERR_CNT) reg_rdata <= {proc_unit_err_cnt, fwd_rx_err_cnt};
                else if (reg_addr == ADDR_PDI_ERROR_CNT) reg_rdata <= {8'h00, pdi_error_cnt};
                else if (reg_addr == ADDR_LOST_LINK_CNT0) reg_rdata <= {lost_link_cnt[1], lost_link_cnt[0]};
                else if (reg_addr == ADDR_LOST_LINK_CNT2) reg_rdata <= {lost_link_cnt[3], lost_link_cnt[2]};
                
                // Watchdog (0x0400-0x0443)
                else if (reg_addr == ADDR_WD_DIVIDER) reg_rdata <= watchdog_divider;
                else if (reg_addr == ADDR_WD_TIME_PDI) reg_rdata <= watchdog_time_pdi;
                else if (reg_addr == ADDR_WD_TIME_SM) reg_rdata <= watchdog_time_sm;
                else if (reg_addr == ADDR_WD_STATUS) reg_rdata <= wd_status;
                else if (reg_addr == ADDR_WD_CNT_SM) reg_rdata <= {wd_cnt_pdi, wd_cnt_sm};
                
                // EEPROM (0x0500-0x050F)
                else if (reg_addr == ADDR_EEPROM_CONFIG) reg_rdata <= {eeprom_pdi_access, eeprom_config_reg};
                else if (reg_addr == ADDR_EEPROM_CONTROL) reg_rdata <= eeprom_control;
                else if (reg_addr == ADDR_EEPROM_ADDR) reg_rdata <= eeprom_addr[15:0];
                else if (reg_addr == ADDR_EEPROM_ADDR + 16'h0002) reg_rdata <= eeprom_addr[31:16];
                else if (reg_addr == ADDR_EEPROM_DATA) reg_rdata <= eeprom_data[15:0];
                else if (reg_addr == ADDR_EEPROM_DATA + 16'h0002) reg_rdata <= eeprom_data[31:16];
                else if (reg_addr == ADDR_EEPROM_DATA + 16'h0004) reg_rdata <= eeprom_data[47:32];
                else if (reg_addr == ADDR_EEPROM_DATA + 16'h0006) reg_rdata <= eeprom_data[63:48];
                
                // MII (0x0510-0x0517)
                else if (reg_addr == ADDR_MII_CONTROL) reg_rdata <= {8'h00, mii_control};
                else if (reg_addr == ADDR_MII_PHY_ADDR) reg_rdata <= {mii_phy_reg, mii_phy_addr_reg};
                else if (reg_addr == ADDR_MII_PHY_DATA) reg_rdata <= mii_phy_data;
                else if (reg_addr == ADDR_MII_PHY_RW_ERR) reg_rdata <= {8'h00, mii_rw_err};
                
                // FMMU registers (0x0600-0x067F)
                else if (addr_in_fmmu_range) begin
                    case (fmmu_off)
                        4'h0: reg_rdata <= fmmu_log_start_addr[fmmu_idx*32 +: 16];
                        4'h2: reg_rdata <= fmmu_log_start_addr[fmmu_idx*32+16 +: 16];
                        4'h4: reg_rdata <= fmmu_length[fmmu_idx*16 +: 16];
                        4'h6: reg_rdata <= {5'h00, fmmu_log_end_bit[fmmu_idx*3 +: 3],
                                           5'h00, fmmu_log_start_bit[fmmu_idx*3 +: 3]};
                        4'h8: reg_rdata <= fmmu_phys_start_addr[fmmu_idx*16 +: 16];
                        4'hA: reg_rdata <= {5'h00, fmmu_phys_start_bit[fmmu_idx*3 +: 3],
                                           6'h00, fmmu_write_enable[fmmu_idx], fmmu_read_enable[fmmu_idx]};
                        4'hC: reg_rdata <= {15'h0000, fmmu_enable[fmmu_idx]};
                        default: reg_rdata <= 16'h0000;
                    endcase
                end
                
                // SM registers (0x0800-0x083F)
                else if (addr_in_sm_range) begin
                    case (sm_off)
                        3'h0: reg_rdata <= sm_phys_start_addr[sm_idx*16 +: 16];
                        3'h2: reg_rdata <= sm_length[sm_idx*16 +: 16];
                        3'h4: reg_rdata <= {sm_status_in[sm_idx*8 +: 8], sm_control[sm_idx*8 +: 8]};
                        3'h6: reg_rdata <= {7'h00, sm_repeat[sm_idx], 7'h00, sm_enable[sm_idx]};
                        default: reg_rdata <= 16'h0000;
                    endcase
                end
                
                // DC registers (0x0900-0x09FF)
                else if (addr_in_dc_range) begin
                    case (reg_addr)
                        ADDR_DC_RECV_TIME0: reg_rdata <= dc_recv_time[0][15:0];
                        ADDR_DC_RECV_TIME0 + 16'h0002: reg_rdata <= dc_recv_time[0][31:16];
                        ADDR_DC_RECV_TIME0 + 16'h0004: reg_rdata <= dc_recv_time[0][47:32];
                        ADDR_DC_RECV_TIME0 + 16'h0006: reg_rdata <= dc_recv_time[0][63:48];
                        ADDR_DC_SYS_TIME: reg_rdata <= dc_system_time[15:0];
                        ADDR_DC_SYS_TIME + 16'h0002: reg_rdata <= dc_system_time[31:16];
                        ADDR_DC_SYS_TIME + 16'h0004: reg_rdata <= dc_system_time[47:32];
                        ADDR_DC_SYS_TIME + 16'h0006: reg_rdata <= dc_system_time[63:48];
                        ADDR_DC_SYS_OFFSET: reg_rdata <= dc_sys_offset[15:0];
                        ADDR_DC_SYS_OFFSET + 16'h0002: reg_rdata <= dc_sys_offset[31:16];
                        ADDR_DC_SYS_OFFSET + 16'h0004: reg_rdata <= dc_sys_offset[47:32];
                        ADDR_DC_SYS_OFFSET + 16'h0006: reg_rdata <= dc_sys_offset[63:48];
                        ADDR_DC_SYS_DELAY: reg_rdata <= dc_sys_delay[15:0];
                        ADDR_DC_SYS_DELAY + 16'h0002: reg_rdata <= dc_sys_delay[31:16];
                        ADDR_DC_SYS_DIFF: reg_rdata <= dc_sys_diff[15:0];
                        ADDR_DC_SYS_DIFF + 16'h0002: reg_rdata <= dc_sys_diff[31:16];
                        ADDR_DC_SPEED_CNT: reg_rdata <= dc_speed_cnt_start;
                        ADDR_DC_SPEED_DIFF: reg_rdata <= dc_speed_diff;
                        ADDR_DC_FLT_DEPTH: reg_rdata <= {dc_speed_filter, dc_filter_depth};
                        ADDR_DC_CYC_UNIT: reg_rdata <= {dc_activation, dc_cyc_unit_ctrl};
                        ADDR_DC_IMPULSE_LEN: reg_rdata <= dc_impulse_len;
                        ADDR_DC_ACT_STATUS: reg_rdata <= {8'h00, dc_act_status};
                        ADDR_DC_SYNC0_STAT: reg_rdata <= {dc_sync1_status, dc_sync0_status};
                        ADDR_DC_SYNC0_START: reg_rdata <= dc_sync0_start[15:0];
                        ADDR_DC_SYNC0_START + 16'h0002: reg_rdata <= dc_sync0_start[31:16];
                        ADDR_DC_SYNC0_START + 16'h0004: reg_rdata <= dc_sync0_start[47:32];
                        ADDR_DC_SYNC0_START + 16'h0006: reg_rdata <= dc_sync0_start[63:48];
                        ADDR_DC_SYNC1_START: reg_rdata <= dc_sync1_start[15:0];
                        ADDR_DC_SYNC1_START + 16'h0002: reg_rdata <= dc_sync1_start[31:16];
                        ADDR_DC_SYNC1_START + 16'h0004: reg_rdata <= dc_sync1_start[47:32];
                        ADDR_DC_SYNC1_START + 16'h0006: reg_rdata <= dc_sync1_start[63:48];
                        ADDR_DC_SYNC0_CYCLE: reg_rdata <= dc_sync0_cycle[15:0];
                        ADDR_DC_SYNC0_CYCLE + 16'h0002: reg_rdata <= dc_sync0_cycle[31:16];
                        ADDR_DC_SYNC1_CYCLE: reg_rdata <= dc_sync1_cycle[15:0];
                        ADDR_DC_SYNC1_CYCLE + 16'h0002: reg_rdata <= dc_sync1_cycle[31:16];
                        ADDR_DC_LATCH0_CTRL: reg_rdata <= {dc_latch1_ctrl, dc_latch0_ctrl};
                        ADDR_DC_LATCH0_STAT: reg_rdata <= {dc_latch1_status, dc_latch0_status};
                        ADDR_DC_LATCH0_POS: reg_rdata <= dc_latch0_pos[15:0];
                        ADDR_DC_LATCH0_POS + 16'h0002: reg_rdata <= dc_latch0_pos[31:16];
                        ADDR_DC_LATCH0_POS + 16'h0004: reg_rdata <= dc_latch0_pos[47:32];
                        ADDR_DC_LATCH0_POS + 16'h0006: reg_rdata <= dc_latch0_pos[63:48];
                        ADDR_DC_LATCH0_NEG: reg_rdata <= dc_latch0_neg[15:0];
                        ADDR_DC_LATCH0_NEG + 16'h0002: reg_rdata <= dc_latch0_neg[31:16];
                        ADDR_DC_LATCH0_NEG + 16'h0004: reg_rdata <= dc_latch0_neg[47:32];
                        ADDR_DC_LATCH0_NEG + 16'h0006: reg_rdata <= dc_latch0_neg[63:48];
                        ADDR_DC_LATCH1_POS: reg_rdata <= dc_latch1_pos[15:0];
                        ADDR_DC_LATCH1_POS + 16'h0002: reg_rdata <= dc_latch1_pos[31:16];
                        ADDR_DC_LATCH1_POS + 16'h0004: reg_rdata <= dc_latch1_pos[47:32];
                        ADDR_DC_LATCH1_POS + 16'h0006: reg_rdata <= dc_latch1_pos[63:48];
                        ADDR_DC_LATCH1_NEG: reg_rdata <= dc_latch1_neg[15:0];
                        ADDR_DC_LATCH1_NEG + 16'h0002: reg_rdata <= dc_latch1_neg[31:16];
                        ADDR_DC_LATCH1_NEG + 16'h0004: reg_rdata <= dc_latch1_neg[47:32];
                        ADDR_DC_LATCH1_NEG + 16'h0006: reg_rdata <= dc_latch1_neg[63:48];
                        default: reg_rdata <= 16'h0000;
                    endcase
                end
                
                // FMMU Error registers (0x0F00-0x0F07)
                else if (reg_addr >= ADDR_FMMU_ERROR_BASE && reg_addr < ADDR_FMMU_ERROR_BASE + 16'h0008) begin
                    // Read FMMU error codes - 2 bytes per read (16-bit data bus)
                    case (reg_addr[2:1])
                        2'b00: reg_rdata <= {fmmu_error_codes[15:8], fmmu_error_codes[7:0]};    // FMMU 1,0
                        2'b01: reg_rdata <= {fmmu_error_codes[31:24], fmmu_error_codes[23:16]}; // FMMU 3,2
                        2'b10: reg_rdata <= {fmmu_error_codes[47:40], fmmu_error_codes[39:32]}; // FMMU 5,4
                        2'b11: reg_rdata <= {fmmu_error_codes[63:56], fmmu_error_codes[55:48]}; // FMMU 7,6
                    endcase
                end
            end
            
            // Latch event requests
            irq_request_latched <= irq_request_latched | irq_request;
            ecat_event_req_latched <= ecat_event_req_latched | irq_request;  // Map to ECAT events
            al_event_req_latched <= al_event_req_latched | {8'h00, sm_status};  // SM status events
        end
    end
    
    // ========================================================================
    // Register Write Logic - Complete Implementation
    // ========================================================================
    
    integer i;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Station address
            station_address <= 16'h0000;
            station_alias <= 16'h0000;
            
            // AL Control
            al_control <= 5'b00001;  // Init state
            al_control_changed <= 1'b0;
            
            // DL Control
            dl_control_loop_port0 <= 1'b0;
            dl_control_loop_port1 <= 1'b0;
            dl_control_loop_port2 <= 1'b0;
            dl_control_loop_port3 <= 1'b0;
            dl_control_rx_fifo_size <= 1'b0;
            dl_control_ecat_ena <= 1'b1;
            dl_control_alias_ena <= 1'b0;
            dl_control_fwd_en <= 1'b1;
            dl_control_temp_loop <= 1'b0;
            port_enable <= 4'b1111;
            
            // Write protection
            wr_reg_enable <= 8'h00;
            wr_reg_protect <= 8'h00;
            esc_wr_enable <= 8'h00;
            esc_wr_protect <= 8'h00;
            explicit_device_id <= 32'h00000000;
            explicit_id_valid <= 1'b0;
            
            // PDI
            pdi_control <= 8'h00;
            esc_config <= 8'h00;
            pdi_config <= 8'h00;
            sync_latch_config <= 8'h00;
            pdi_ext_config <= 16'h0000;
            
            // Events
            ecat_event_mask <= 16'h0000;
            al_event_mask <= 16'h0000;
            irq_mask <= 16'h0000;
            
            // Error counters
            for (i = 0; i < 4; i = i + 1) begin
                rx_err_cnt[i] <= 8'h00;
                lost_link_cnt[i] <= 8'h00;
            end
            fwd_rx_err_cnt <= 8'h00;
            proc_unit_err_cnt <= 8'h00;
            pdi_error_cnt <= 8'h00;
            
            // Watchdog
            watchdog_divider <= 16'h09C4;  // 2500 = 100us at 25MHz
            watchdog_time_pdi <= 16'h03E8; // 1000 = 100ms
            watchdog_time_sm <= 16'h03E8;
            watchdog_enable <= 1'b0;
            wd_status <= 16'h0000;
            wd_cnt_sm <= 8'h00;
            wd_cnt_pdi <= 8'h00;
            
            // EEPROM
            eeprom_config_reg <= 8'h00;
            eeprom_pdi_access <= 8'h00;
            eeprom_control <= 16'h0000;
            eeprom_addr <= 32'h00000000;
            eeprom_data <= 64'h0000000000000000;
            
            // MII
            mii_control <= 8'h00;
            mii_phy_addr_reg <= 8'h00;
            mii_phy_reg <= 8'h00;
            mii_phy_data <= 16'h0000;
            mii_rw_err <= 8'h00;
            
            // FMMU registers - initialize all 8
            fmmu_log_start_addr <= {NUM_FMMU{32'h00000000}};
            fmmu_length <= {NUM_FMMU{16'h0000}};
            fmmu_log_start_bit <= {NUM_FMMU{3'b000}};
            fmmu_log_end_bit <= {NUM_FMMU{3'b000}};
            fmmu_phys_start_addr <= {NUM_FMMU{16'h0000}};
            fmmu_phys_start_bit <= {NUM_FMMU{3'b000}};
            fmmu_read_enable <= {NUM_FMMU{1'b0}};
            fmmu_write_enable <= {NUM_FMMU{1'b0}};
            fmmu_enable <= {NUM_FMMU{1'b0}};
            
            // SM registers - initialize all 8
            sm_phys_start_addr <= {NUM_SM{16'h0000}};
            sm_length <= {NUM_SM{16'h0000}};
            sm_control <= {NUM_SM{8'h00}};
            sm_enable <= {NUM_SM{1'b0}};
            sm_repeat <= {NUM_SM{1'b0}};
            sm_cfg_wr <= 1'b0;
            sm_cfg_sel <= 4'b0000;
            sm_cfg_addr <= 8'h00;
            sm_cfg_wdata <= 16'h0000;
            
            // DC registers
            for (i = 0; i < 4; i = i + 1) begin
                dc_recv_time[i] <= 64'h0000000000000000;
            end
            dc_sys_offset <= 64'h0000000000000000;
            dc_sys_delay <= 32'h00000000;
            dc_sys_diff <= 32'h00000000;
            dc_speed_cnt_start <= 16'h0000;
            dc_speed_diff <= 16'h0000;
            dc_filter_depth <= 8'h00;
            dc_speed_filter <= 8'h00;
            dc_cyc_unit_ctrl <= 8'h00;
            dc_activation <= 8'h00;
            dc_impulse_len <= 16'h0000;
            dc_act_status <= 8'h00;
            dc_sync0_status <= 8'h00;
            dc_sync1_status <= 8'h00;
            dc_sync0_start <= 64'h0000000000000000;
            dc_sync1_start <= 64'h0000000000000000;
            dc_sync0_cycle <= 32'h00000000;
            dc_sync1_cycle <= 32'h00000000;
            dc_latch0_ctrl <= 8'h00;
            dc_latch1_ctrl <= 8'h00;
            dc_latch0_status <= 8'h00;
            dc_latch1_status <= 8'h00;
            dc_latch0_pos <= 64'h0000000000000000;
            dc_latch0_neg <= 64'h0000000000000000;
            dc_latch1_pos <= 64'h0000000000000000;
            dc_latch1_neg <= 64'h0000000000000000;
            
        end else begin
            al_control_changed <= 1'b0;
            sm_cfg_wr <= 1'b0;
            
            // Update watchdog status from external signal
            if (watchdog_expired) begin
                wd_status[0] <= 1'b1;  // PDI watchdog expired
            end
            
            if (reg_req && reg_wr) begin
                
                // Station Address (0x0010-0x0013)
                if (reg_addr == ADDR_STATION_ADR) begin
                    if (reg_be[0]) station_address[7:0] <= reg_wdata[7:0];
                    if (reg_be[1]) station_address[15:8] <= reg_wdata[15:8];
                end
                else if (reg_addr == ADDR_STATION_ALIAS) begin
                    if (reg_be[0]) station_alias[7:0] <= reg_wdata[7:0];
                    if (reg_be[1]) station_alias[15:8] <= reg_wdata[15:8];
                end
                
                // Write Protection
                else if (reg_addr == ADDR_WR_REG_ENABLE) begin
                    if (reg_be[0]) wr_reg_enable <= reg_wdata[7:0];
                end
                else if (reg_addr == ADDR_WR_REG_PROTECT) begin
                    if (reg_be[0]) wr_reg_protect <= reg_wdata[7:0];
                end
                
                // ESC Write Protection (0x0030-0x0031)
                else if (reg_addr == ADDR_ESC_WR_ENABLE) begin
                    if (reg_be[0]) esc_wr_enable <= reg_wdata[7:0];
                end
                else if (reg_addr == ADDR_ESC_WR_PROTECT) begin
                    if (reg_be[0]) esc_wr_protect <= reg_wdata[7:0];
                end
                
                // Explicit Device ID (0x0050-0x0053) - P0 Hot Connect
                else if (reg_addr == ADDR_EXPLICIT_DEV_ID) begin
                    if (reg_be[0]) explicit_device_id[7:0] <= reg_wdata[7:0];
                    if (reg_be[1]) explicit_device_id[15:8] <= reg_wdata[15:8];
                    explicit_id_valid <= 1'b1;
                end
                else if (reg_addr == ADDR_EXPLICIT_DEV_ID + 16'h0002) begin
                    if (reg_be[0]) explicit_device_id[23:16] <= reg_wdata[7:0];
                    if (reg_be[1]) explicit_device_id[31:24] <= reg_wdata[15:8];
                end
                
                // DL Control (0x0100)
                else if (reg_addr == ADDR_DL_CONTROL) begin
                    if (reg_be[0]) begin
                        dl_control_loop_port0 <= reg_wdata[0];
                        dl_control_loop_port1 <= reg_wdata[1];
                        dl_control_loop_port2 <= reg_wdata[2];
                        dl_control_loop_port3 <= reg_wdata[3];
                        dl_control_rx_fifo_size <= reg_wdata[5];
                        dl_control_ecat_ena <= reg_wdata[6];
                        dl_control_alias_ena <= reg_wdata[7];
                    end
                end
                
                // AL Control (0x0120)
                else if (reg_addr == ADDR_AL_CONTROL) begin
                    if (reg_be[0]) begin
                        al_control <= reg_wdata[4:0];
                        al_control_changed <= 1'b1;
                    end
                end
                
                // PDI Control (0x0140-0x0155)
                else if (reg_addr == ADDR_PDI_CONTROL) begin
                    if (reg_be[0]) pdi_control <= reg_wdata[7:0];
                    if (reg_be[1]) esc_config <= reg_wdata[15:8];
                end
                else if (reg_addr == ADDR_PDI_CONFIG) begin
                    if (reg_be[0]) pdi_config <= reg_wdata[7:0];
                    if (reg_be[1]) sync_latch_config <= reg_wdata[15:8];
                end
                else if (reg_addr == ADDR_PDI_EXT_CFG) begin
                    pdi_ext_config <= reg_wdata;
                end
                
                // Event masks (0x0200-0x0207)
                else if (reg_addr == ADDR_ECAT_EVENT_MASK) begin
                    ecat_event_mask <= reg_wdata;
                end
                else if (reg_addr == ADDR_AL_EVENT_MASK) begin
                    al_event_mask <= reg_wdata;
                end
                
                // Watchdog (0x0400-0x0443)
                else if (reg_addr == ADDR_WD_DIVIDER) begin
                    watchdog_divider <= reg_wdata;
                end
                else if (reg_addr == ADDR_WD_TIME_PDI) begin
                    watchdog_time_pdi <= reg_wdata;
                    watchdog_enable <= (reg_wdata != 16'h0000);
                end
                else if (reg_addr == ADDR_WD_TIME_SM) begin
                    watchdog_time_sm <= reg_wdata;
                end
                
                // EEPROM (0x0500-0x050F)
                else if (reg_addr == ADDR_EEPROM_CONFIG) begin
                    if (reg_be[0]) eeprom_config_reg <= reg_wdata[7:0];
                    if (reg_be[1]) eeprom_pdi_access <= reg_wdata[15:8];
                end
                else if (reg_addr == ADDR_EEPROM_CONTROL) begin
                    eeprom_control <= reg_wdata;
                end
                else if (reg_addr == ADDR_EEPROM_ADDR) begin
                    eeprom_addr[15:0] <= reg_wdata;
                end
                else if (reg_addr == ADDR_EEPROM_ADDR + 16'h0002) begin
                    eeprom_addr[31:16] <= reg_wdata;
                end
                
                // MII (0x0510-0x0517)
                else if (reg_addr == ADDR_MII_CONTROL) begin
                    if (reg_be[0]) mii_control <= reg_wdata[7:0];
                end
                else if (reg_addr == ADDR_MII_PHY_ADDR) begin
                    if (reg_be[0]) mii_phy_addr_reg <= reg_wdata[7:0];
                    if (reg_be[1]) mii_phy_reg <= reg_wdata[15:8];
                end
                else if (reg_addr == ADDR_MII_PHY_DATA) begin
                    mii_phy_data <= reg_wdata;
                end
                
                // IRQ Mask
                else if (reg_addr == ADDR_ECAT_EVENT_MASK) begin
                    irq_mask <= reg_wdata;
                end
                
                // FMMU registers (0x0600-0x067F)
                else if (addr_in_fmmu_range) begin
                    case (fmmu_off)
                        4'h0: fmmu_log_start_addr[fmmu_idx*32 +: 16] <= reg_wdata;
                        4'h2: fmmu_log_start_addr[fmmu_idx*32+16 +: 16] <= reg_wdata;
                        4'h4: fmmu_length[fmmu_idx*16 +: 16] <= reg_wdata;
                        4'h6: begin
                            fmmu_log_start_bit[fmmu_idx*3 +: 3] <= reg_wdata[2:0];
                            fmmu_log_end_bit[fmmu_idx*3 +: 3] <= reg_wdata[10:8];
                        end
                        4'h8: fmmu_phys_start_addr[fmmu_idx*16 +: 16] <= reg_wdata;
                        4'hA: begin
                            fmmu_phys_start_bit[fmmu_idx*3 +: 3] <= reg_wdata[10:8];
                            fmmu_read_enable[fmmu_idx] <= reg_wdata[0];
                            fmmu_write_enable[fmmu_idx] <= reg_wdata[1];
                        end
                        4'hC: fmmu_enable[fmmu_idx] <= reg_wdata[0];
                        default: ;
                    endcase
                end
                
                // SM registers (0x0800-0x083F)
                else if (addr_in_sm_range) begin
                    case (sm_off)
                        3'h0: sm_phys_start_addr[sm_idx*16 +: 16] <= reg_wdata;
                        3'h2: sm_length[sm_idx*16 +: 16] <= reg_wdata;
                        3'h4: sm_control[sm_idx*8 +: 8] <= reg_wdata[7:0];
                        3'h6: begin
                            sm_enable[sm_idx] <= reg_wdata[0];
                            sm_repeat[sm_idx] <= reg_wdata[8];
                        end
                        default: ;
                    endcase
                    sm_cfg_wr <= 1'b1;
                    sm_cfg_sel <= {1'b0, sm_idx};
                    sm_cfg_addr <= {5'b0, sm_off};
                    sm_cfg_wdata <= reg_wdata;
                end
                
                // DC registers (0x0900-0x09FF)
                else if (addr_in_dc_range) begin
                    case (reg_addr)
                        ADDR_DC_SYS_OFFSET: dc_sys_offset[15:0] <= reg_wdata;
                        ADDR_DC_SYS_OFFSET + 16'h0002: dc_sys_offset[31:16] <= reg_wdata;
                        ADDR_DC_SYS_OFFSET + 16'h0004: dc_sys_offset[47:32] <= reg_wdata;
                        ADDR_DC_SYS_OFFSET + 16'h0006: dc_sys_offset[63:48] <= reg_wdata;
                        ADDR_DC_SYS_DELAY: dc_sys_delay[15:0] <= reg_wdata;
                        ADDR_DC_SYS_DELAY + 16'h0002: dc_sys_delay[31:16] <= reg_wdata;
                        ADDR_DC_SPEED_CNT: dc_speed_cnt_start <= reg_wdata;
                        ADDR_DC_FLT_DEPTH: begin
                            dc_filter_depth <= reg_wdata[7:0];
                            dc_speed_filter <= reg_wdata[15:8];
                        end
                        ADDR_DC_CYC_UNIT: begin
                            dc_cyc_unit_ctrl <= reg_wdata[7:0];
                            dc_activation <= reg_wdata[15:8];
                        end
                        ADDR_DC_IMPULSE_LEN: dc_impulse_len <= reg_wdata;
                        ADDR_DC_SYNC0_START: dc_sync0_start[15:0] <= reg_wdata;
                        ADDR_DC_SYNC0_START + 16'h0002: dc_sync0_start[31:16] <= reg_wdata;
                        ADDR_DC_SYNC0_START + 16'h0004: dc_sync0_start[47:32] <= reg_wdata;
                        ADDR_DC_SYNC0_START + 16'h0006: dc_sync0_start[63:48] <= reg_wdata;
                        ADDR_DC_SYNC1_START: dc_sync1_start[15:0] <= reg_wdata;
                        ADDR_DC_SYNC1_START + 16'h0002: dc_sync1_start[31:16] <= reg_wdata;
                        ADDR_DC_SYNC1_START + 16'h0004: dc_sync1_start[47:32] <= reg_wdata;
                        ADDR_DC_SYNC1_START + 16'h0006: dc_sync1_start[63:48] <= reg_wdata;
                        ADDR_DC_SYNC0_CYCLE: dc_sync0_cycle[15:0] <= reg_wdata;
                        ADDR_DC_SYNC0_CYCLE + 16'h0002: dc_sync0_cycle[31:16] <= reg_wdata;
                        ADDR_DC_SYNC1_CYCLE: dc_sync1_cycle[15:0] <= reg_wdata;
                        ADDR_DC_SYNC1_CYCLE + 16'h0002: dc_sync1_cycle[31:16] <= reg_wdata;
                        ADDR_DC_LATCH0_CTRL: begin
                            dc_latch0_ctrl <= reg_wdata[7:0];
                            dc_latch1_ctrl <= reg_wdata[15:8];
                        end
                        default: ;
                    endcase
                end
                
            end
        end
    end

endmodule
