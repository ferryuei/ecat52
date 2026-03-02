// ============================================================================
// EtherCAT IP Core - Top Level Module
// Complete Integration of P0-P2 Modules
// ============================================================================

`include "ecat_pkg.vh"

module ethercat_ipcore_top #(
    // ========================================================================
    // Configuration Parameters
    // ========================================================================
    parameter FEATURE_VECTOR_SIZE = `FEATURE_VECTOR_SIZE,
    parameter [`FEATURE_VECTOR_SIZE-1:0] FEATURE_VECTOR = {`FEATURE_VECTOR_SIZE{1'b0}},
    
    // PDI Configuration
    parameter PDI_TYPE = "AVALON",
    parameter PDI_DATA_WIDTH = 32,
    parameter PDI_ADDR_WIDTH = 16,
    
    // PHY Configuration
    parameter PHY_COUNT = 2,
    parameter PHY_TYPE = "MII",
    
    // Clock Configuration
    parameter CLK_FREQ_HZ = 50000000,
    parameter ECAT_CLK_FREQ_HZ = 25000000,
    
    // Memory Configuration
    parameter NUM_FMMU = 8,
    parameter NUM_SM = 8,
    parameter DP_RAM_SIZE = 4096,
    
    // Feature Flags
    parameter DC_SUPPORT = 1,
    
    // Vendor/Product Identification
    parameter [31:0] VENDOR_ID = 32'h00000000,
    parameter [31:0] PRODUCT_CODE = 32'h00000000,
    parameter [31:0] REVISION_NUM = 32'h00010000,
    parameter [31:0] SERIAL_NUM = 32'h00000001
)(
    // ========================================================================
    // System Interfaces
    // ========================================================================
    input  wire                         sys_rst_n,
    input  wire                         sys_clk,
    input  wire                         ecat_clk,
    input  wire                         ecat_clk_ddr,
    
    // ========================================================================
    // Process Data Interface (PDI) - Avalon Bus
    // ========================================================================
    input  wire                         pdi_clk,
    input  wire [PDI_ADDR_WIDTH-1:0]    pdi_address,
    input  wire                         pdi_read,
    output wire [PDI_DATA_WIDTH-1:0]    pdi_readdata,
    output wire                         pdi_readdatavalid,
    input  wire                         pdi_write,
    input  wire [PDI_DATA_WIDTH-1:0]    pdi_writedata,
    input  wire [(PDI_DATA_WIDTH/8)-1:0] pdi_byteenable,
    output wire                         pdi_waitrequest,
    output wire                         pdi_irq,
    
    // ========================================================================
    // Ethernet PHY Interfaces
    // ========================================================================
    output wire [PHY_COUNT-1:0]         phy_tx_clk,
    output wire [PHY_COUNT-1:0]         phy_tx_en,
    output wire [PHY_COUNT-1:0]         phy_tx_er,
    output wire [PHY_COUNT*8-1:0]       phy_tx_data,
    
    input  wire [PHY_COUNT-1:0]         phy_rx_clk,
    input  wire [PHY_COUNT-1:0]         phy_rx_dv,
    input  wire [PHY_COUNT-1:0]         phy_rx_er,
    input  wire [PHY_COUNT*8-1:0]       phy_rx_data,
    
    // PHY Management (MDIO)
    output wire                         phy_mdc,
    output wire                         phy_mdio_o,
    output wire                         phy_mdio_oe,
    input  wire                         phy_mdio_i,
    
    output wire [PHY_COUNT-1:0]         phy_reset_n,
    
    // ========================================================================
    // EEPROM Interface (I2C)
    // ========================================================================
    output wire                         eeprom_scl_o,
    output wire                         eeprom_scl_oe,
    input  wire                         eeprom_scl_i,
    output wire                         eeprom_sda_o,
    output wire                         eeprom_sda_oe,
    input  wire                         eeprom_sda_i,
    
    // ========================================================================
    // LED Outputs
    // ========================================================================
    output wire [PHY_COUNT-1:0]         led_link,
    output wire [PHY_COUNT-1:0]         led_act,
    output wire                         led_run,
    output wire                         led_err,
    
    // ========================================================================
    // Distributed Clock (DC) Interface
    // ========================================================================
    input  wire                         dc_latch0_in,
    input  wire                         dc_latch1_in,
    output wire                         dc_sync0_out,
    output wire                         dc_sync1_out
);

    // ========================================================================
    // Internal Signals - Reset Synchronization
    // ========================================================================
    reg [2:0] sys_rst_sync;
    reg [2:0] ecat_rst_sync;
    wire sys_rst_n_sync;
    wire ecat_rst_n_sync;
    
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            sys_rst_sync <= 3'b000;
        else
            sys_rst_sync <= {sys_rst_sync[1:0], 1'b1};
    end
    assign sys_rst_n_sync = sys_rst_sync[2];
    
    always @(posedge ecat_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            ecat_rst_sync <= 3'b000;
        else
            ecat_rst_sync <= {ecat_rst_sync[1:0], 1'b1};
    end
    assign ecat_rst_n_sync = ecat_rst_sync[2];

    // ========================================================================
    // Internal Signals - PHY Interface
    // ========================================================================
    wire [PHY_COUNT-1:0] link_up;
    wire [PHY_COUNT-1:0] link_speed_100;
    wire [PHY_COUNT-1:0] link_duplex;
    
    // RX from PHY (active port selection)
    wire [3:0]  rx_port_id;
    wire        rx_valid;
    wire [7:0]  rx_data;
    wire        rx_sof;
    wire        rx_eof;
    wire        rx_error;
    
    // TX to PHY
    wire [3:0]  tx_port_id;
    wire        tx_valid;
    wire [7:0]  tx_data;
    wire        tx_sof;
    wire        tx_eof;
    wire        tx_ready;

    // RX port selection / edge detect (ecat_clk domain)
    reg [3:0]           rx_port_sel;
    reg                 rx_active;
    reg [3:0]           rx_port_pick;
    reg                 rx_port_pick_valid;
    integer             rx_p;
    reg                 rx_in_frame;
    reg                 rx_sof_reg;
    reg                 rx_eof_reg;

    // RX CDC FIFOs
    localparam RX_FIFO_AW = 11; // 2048-deep per port
    wire [PHY_COUNT-1:0] rx_fifo_wr_en;
    wire [8:0]           rx_fifo_wdata [PHY_COUNT-1:0];
    wire [PHY_COUNT-1:0] rx_fifo_full;
    wire [RX_FIFO_AW:0]  rx_fifo_wr_level [PHY_COUNT-1:0];

    wire [PHY_COUNT-1:0] rx_fifo_rd_en;
    wire [8:0]           rx_fifo_rdata [PHY_COUNT-1:0];
    wire [PHY_COUNT-1:0] rx_fifo_empty;
    wire [RX_FIFO_AW:0]  rx_fifo_rd_level [PHY_COUNT-1:0];

    // ========================================================================
    // Internal Signals - Frame Receiver/Transmitter
    // ========================================================================
    // Frame receiver outputs
    wire [15:0] fr_mem_addr;
    wire [15:0] fr_mem_wdata;
    wire [1:0]  fr_mem_be;
    wire        fr_mem_wr_en;
    wire        fr_mem_rd_en;
    wire [15:0] fr_mem_rdata;
    wire        fr_mem_ready;

    // Logical access interface (FMMU translated)
    wire        fr_log_req;
    wire        fr_log_wr;
    wire [31:0] fr_log_addr;
    wire [7:0]  fr_log_wdata;
    wire        fr_log_ack;
    wire [7:0]  fr_log_rdata;
    wire        fr_log_err;
    
    // Frame forwarding
    wire        fwd_valid;
    wire [7:0]  fwd_data;
    wire        fwd_sof;
    wire        fwd_eof;
    wire        fwd_modified;

    // Frame metadata
    wire        frame_rx_valid;
    wire [47:0] frame_src_mac;
    wire [47:0] frame_dst_mac;
    wire        frame_is_ecat;
    wire        frame_crc_error;
    
    // Statistics
    wire [15:0] rx_frame_count;
    wire [15:0] rx_error_count;
    wire [15:0] rx_crc_error_count;
    wire [15:0] tx_frame_count;
    wire [15:0] tx_error_count;

    // ========================================================================
    // Internal Signals - Register Map
    // ========================================================================
    wire        reg_req;
    wire        reg_wr;
    wire [15:0] reg_addr;
    wire [15:0] reg_wdata;
    wire [1:0]  reg_be;
    wire [15:0] reg_rdata;
    wire        reg_ack;
    
    // AL Control/Status
    wire [4:0]  al_control;
    wire        al_control_changed;
    wire [4:0]  al_status;
    wire [15:0] al_status_code;
    
    // DL Control/Status
    wire        dl_control_fwd_en;
    wire        dl_control_temp_loop;
    wire [15:0] dl_status;
    
    // Port configuration
    wire [3:0]  port_enable;
    wire [3:0]  port_link_status;
    wire [3:0]  port_loop_status;
    wire [PHY_COUNT-1:0] port_rx_active;
    wire [PHY_COUNT-1:0] port_tx_active;
    wire [PHY_COUNT-1:0] loop_detected;
    wire        loop_active;
    wire [15:0] dl_status_pc;
    
    // Station address
    wire [15:0] station_address;
    wire [15:0] station_alias;
    
    // IRQ
    wire [15:0] irq_mask;
    wire [15:0] irq_request;
    
    // SM/FMMU status
    wire [7:0]  sm_status;
    wire [7:0]  fmmu_status;

    // FMMU/SM configuration buses from register map
    wire [NUM_FMMU*32-1:0] fmmu_log_start_addr;
    wire [NUM_FMMU*16-1:0] fmmu_length;
    wire [NUM_FMMU*3-1:0]  fmmu_log_start_bit;
    wire [NUM_FMMU*3-1:0]  fmmu_log_end_bit;
    wire [NUM_FMMU*16-1:0] fmmu_phys_start_addr;
    wire [NUM_FMMU*3-1:0]  fmmu_phys_start_bit;
    wire [NUM_FMMU-1:0]    fmmu_read_enable;
    wire [NUM_FMMU-1:0]    fmmu_write_enable;
    wire [NUM_FMMU-1:0]    fmmu_enable;
    wire [NUM_FMMU*8-1:0]  fmmu_error_codes;
    reg  [7:0]             fmmu_err_latched;

    wire [NUM_SM*16-1:0]   sm_phys_start_addr;
    wire [NUM_SM*16-1:0]   sm_length;
    wire [NUM_SM*8-1:0]    sm_control;
    wire [NUM_SM-1:0]      sm_enable;
    wire [NUM_SM-1:0]      sm_repeat;
    wire [NUM_SM*8-1:0]    sm_status_in;

    wire                   sm_cfg_wr;
    wire [3:0]             sm_cfg_sel;
    wire [7:0]             sm_cfg_addr;
    wire [15:0]            sm_cfg_wdata;
    wire [15:0]            sm_cfg_rdata;

    // MDIO (MII management)
    wire        mii_reg_req;
    wire        mii_reg_wr;
    wire [15:0] mii_reg_addr;
    wire [15:0] mii_reg_wdata;
    wire [15:0] mii_reg_rdata;
    wire        mii_reg_ack;
    wire        mdio_busy;
    wire        mdio_error;
    wire        mdio_mdc;
    wire        mdio_mdio_o;
    wire        mdio_mdio_oe;
    
    // DC
    wire [63:0] dc_system_time;
    wire [31:0] dc_sync0_cycle;
    wire [31:0] dc_sync1_cycle;
    
    // Statistics
    wire [31:0] rx_error_counter;
    wire [31:0] lost_link_counter;

    // ========================================================================
    // Internal Signals - AL State Machine
    // ========================================================================
    wire        sm_enable_al;
    wire        fmmu_enable_al;
    wire        pdi_enable;
    wire        watchdog_enable_al;
    wire        al_event_irq;

    // ========================================================================
    // Internal Signals - SII/EEPROM
    // ========================================================================
    wire        sii_reg_req;
    wire        sii_reg_wr;
    wire [15:0] sii_reg_addr;
    wire [31:0] sii_reg_wdata;
    wire [31:0] sii_reg_rdata;
    wire        sii_reg_ack;
    wire        eeprom_loaded;
    wire        eeprom_busy;
    wire        eeprom_error;

    // ========================================================================
    // Internal Signals - DC
    // ========================================================================
    wire        dc_reg_req;
    wire        dc_reg_wr;
    wire [15:0] dc_reg_addr;
    wire [15:0] dc_reg_wdata;
    wire [15:0] dc_reg_rdata;
    wire        dc_reg_ack;
    wire        dc_active;
    wire        sync0_active;
    wire        sync1_active;

    // ========================================================================
    // Internal Signals - DPRAM
    // ========================================================================
    wire        dpram_ecat_req;
    wire        dpram_ecat_wr;
    wire [12:0] dpram_ecat_addr;
    wire [7:0]  dpram_ecat_wdata;
    wire        dpram_ecat_ack;
    wire [7:0]  dpram_ecat_rdata;
    wire        dpram_ecat_collision;
    
    wire        dpram_pdi_req;
    wire        dpram_pdi_wr;
    wire [12:0] dpram_pdi_addr;
    wire [7:0]  dpram_pdi_wdata;
    wire        dpram_pdi_ack;
    wire [7:0]  dpram_pdi_rdata;
    wire        dpram_pdi_collision;
    wire [15:0] collision_count;

    // ========================================================================
    // Internal Signals - PDI Avalon
    // ========================================================================
    wire        pdi_reg_req;
    wire        pdi_reg_wr;
    wire [15:0] pdi_reg_addr;
    wire [15:0] pdi_reg_wdata;
    wire [1:0]  pdi_reg_be;
    wire [15:0] pdi_reg_rdata;
    wire        pdi_reg_ack;
    
    wire [7:0]  pdi_sm_id;
    wire        pdi_sm_req;
    wire        pdi_sm_wr;
    wire [15:0] pdi_sm_addr;
    wire [PDI_DATA_WIDTH-1:0] pdi_sm_wdata;
    wire [PDI_DATA_WIDTH-1:0] pdi_sm_rdata;
    wire        pdi_sm_ack;
    wire        pdi_operational;
    wire        pdi_watchdog_timeout;

    // ========================================================================
    // Internal Signals - Sync Manager Array
    // ========================================================================
    wire        sm_ecat_req;
    wire        sm_ecat_wr;
    wire [15:0] sm_ecat_addr;
    wire [7:0]  sm_ecat_wdata;
    wire        sm_ecat_ack;
    wire [7:0]  sm_ecat_rdata;

    wire        sm_pdi_ack;
    wire [7:0]  sm_pdi_rdata;

    wire        sm_mem_req;
    wire        sm_mem_wr;
    wire [15:0] sm_mem_addr;
    wire [7:0]  sm_mem_wdata;
    wire        sm_mem_ack;
    wire [7:0]  sm_mem_rdata;

    wire [NUM_SM-1:0] sm_irq;
    wire [NUM_SM*8-1:0] sm_status_packed;
    wire [NUM_SM-1:0] sm_active_bits;

    reg        sm_addr_hit;
    reg [2:0]  sm_addr_sel;
    integer    sm_i;

    // Logical access translation (simplified FMMU)
    reg        log_hit;
    reg        log_perm_err;
    reg [15:0] log_phy_addr;
    integer    f_i;
    reg [31:0] fmmu_log_start;
    reg [15:0] fmmu_len;
    reg [31:0] fmmu_end;
    reg [31:0] fmmu_offset;

    // Mailbox handler signals
    wire        mbx_sm0_full;
    wire        mbx_sm1_full_sm;
    wire        mbx_sm0_read;
    wire        mbx_sm1_read;
    wire        mbx_mem_req;
    wire        mbx_mem_wr;
    wire [15:0] mbx_mem_addr;
    wire [7:0]  mbx_mem_wdata;
    wire [7:0]  mbx_mem_rdata;
    wire        mbx_mem_ack;
    wire        mbx_busy;
    wire        mbx_irq;
    wire        mbx_sm1_full_out;
    reg         sm1_full_prev;
    reg [2:0]   mbx_sm_sel;
    reg         mbx_sm_hit;
    integer     mbx_i;

    // PDI SM arbitration
    wire        sm_pdi_req_mux;
    wire        sm_pdi_wr_mux;
    wire [15:0] sm_pdi_addr_mux;
    wire [7:0]  sm_pdi_wdata_mux;
    wire [2:0]  sm_pdi_sel_mux;

    // Mailbox protocol handlers
    wire        coe_request;
    wire [7:0]  coe_service;
    wire [15:0] coe_index;
    wire [7:0]  coe_subindex;
    wire [31:0] coe_data;
    wire        coe_response_ready;
    wire [7:0]  coe_response_service;
    wire [31:0] coe_response_data;
    wire [31:0] coe_abort_code;

    // ========================================================================
    // PHY Interface
    // ========================================================================
    // PHY Interface (data only; MDIO handled by separate master)
    ecat_phy_interface #(
        .PHY_COUNT          (PHY_COUNT),
        .PHY_TYPE           (PHY_TYPE),
        .USE_DDR            (1)
    ) phy_if_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        .clk_ddr            (ecat_clk_ddr),
        .feature_vector     (FEATURE_VECTOR),
        // TX
        .tx_clk             (phy_tx_clk),
        .tx_en              (phy_tx_en),
        .tx_er              (phy_tx_er),
        .tx_data            (phy_tx_data),
        // RX
        .rx_clk             (phy_rx_clk),
        .rx_dv              (phy_rx_dv),
        .rx_er              (phy_rx_er),
        .rx_data            (phy_rx_data),
        // MDIO
        .mdio_mdc           (),
        .mdio_mdio          (),
        .mdio_oe            (),
        // Reset
        .phy_reset_n        (phy_reset_n),
        // Status
        .link_up            (link_up),
        .link_speed_100     (link_speed_100),
        .link_duplex        (link_duplex)
    );

    // ========================================================================
    // RX CDC FIFOs (one per port)
    // ========================================================================
    generate
        for (genvar rp = 0; rp < PHY_COUNT; rp++) begin : gen_rx_fifo
            assign rx_fifo_wr_en[rp] = phy_rx_dv[rp];
            assign rx_fifo_wdata[rp] = {phy_rx_er[rp], phy_rx_data[rp*8 +: 8]};
            async_fifo #(
                .DATA_WIDTH     (9),
                .ADDR_WIDTH     (RX_FIFO_AW),
                .SYNC_STAGES    (2)
            ) rx_fifo_inst (
                .wr_rst_n       (sys_rst_n),
                .wr_clk         (phy_rx_clk[rp]),
                .wr_en          (rx_fifo_wr_en[rp]),
                .wr_data        (rx_fifo_wdata[rp]),
                .wr_full        (rx_fifo_full[rp]),
                .wr_level       (rx_fifo_wr_level[rp]),
                .rd_rst_n       (ecat_rst_n_sync),
                .rd_clk         (ecat_clk),
                .rd_en          (rx_fifo_rd_en[rp]),
                .rd_data        (rx_fifo_rdata[rp]),
                .rd_empty       (rx_fifo_empty[rp]),
                .rd_level       (rx_fifo_rd_level[rp])
            );
        end
    endgenerate
    
    // Assign PHY status to port signals
    assign port_link_status = link_up[PHY_COUNT-1:0];
    assign port_loop_status = {{(4-PHY_COUNT){1'b0}}, loop_detected};
    assign port_tx_active = (tx_valid) ? ({PHY_COUNT{1'b0}} | (1'b1 << tx_port_id)) : {PHY_COUNT{1'b0}};
    assign port_rx_active = ~rx_fifo_empty;

    // ========================================================================
    // Frame Receiver
    // ========================================================================
    ecat_frame_receiver #(
        .ADDR_WIDTH         (16),
        .DATA_WIDTH         (16),
        .STATION_ADDR       (16'h0000)
    ) frame_rx_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Port interface
        .port_id            (rx_port_id),
        .rx_valid           (rx_valid),
        .rx_data            (rx_data),
        .rx_sof             (rx_sof),
        .rx_eof             (rx_eof),
        .rx_error           (rx_error),
        // Register interface
        .station_address    (station_address),
        .station_alias      ({16'b0, station_alias}),
        // Memory interface
        .mem_addr           (fr_mem_addr),
        .mem_wdata          (fr_mem_wdata),
        .mem_be             (fr_mem_be),
        .mem_wr_en          (fr_mem_wr_en),
        .mem_rd_en          (fr_mem_rd_en),
        .mem_rdata          (fr_mem_rdata),
        .mem_ready          (fr_mem_ready),
        // Logical access (FMMU)
        .log_req            (fr_log_req),
        .log_wr             (fr_log_wr),
        .log_addr           (fr_log_addr),
        .log_wdata          (fr_log_wdata),
        .log_ack            (fr_log_ack),
        .log_rdata          (fr_log_rdata),
        .log_err            (fr_log_err),
        // Frame forwarding
        .fwd_valid          (fwd_valid),
        .fwd_data           (fwd_data),
        .fwd_sof            (fwd_sof),
        .fwd_eof            (fwd_eof),
        .fwd_modified       (fwd_modified),
        // Frame metadata
        .frame_rx_valid     (frame_rx_valid),
        .frame_src_mac      (frame_src_mac),
        .frame_dst_mac      (frame_dst_mac),
        .frame_is_ecat      (frame_is_ecat),
        .frame_crc_error    (frame_crc_error),
        // Statistics
        .rx_frame_count     (rx_frame_count),
        .rx_error_count     (rx_error_count),
        .rx_crc_error_count (rx_crc_error_count)
    );

    // ========================================================================
    // Frame Transmitter
    // ========================================================================
    ecat_frame_transmitter #(
        .DATA_WIDTH         (16)
    ) frame_tx_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Port interface
        .port_id            (tx_port_id),
        .tx_valid           (tx_valid),
        .tx_data            (tx_data),
        .tx_sof             (tx_sof),
        .tx_eof             (tx_eof),
        .tx_ready           (tx_ready),
        // Frame input
        .fwd_valid          (fwd_valid),
        .fwd_data           (fwd_data),
        .fwd_sof            (fwd_sof),
        .fwd_eof            (fwd_eof),
        .fwd_modified       (fwd_modified),
        .fwd_from_port      (rx_port_id),
        // Modified data injection
        .inject_enable      (1'b0),
        .inject_offset      (11'b0),
        .inject_data        (8'b0),
        // Port control
        .port_enable        (port_enable),
        .port_link_status   (port_link_status),
        // Statistics
        .tx_frame_count     (tx_frame_count),
        .tx_error_count     (tx_error_count)
    );

    // ========================================================================
    // Port Controller (DL status/loop detection)
    // ========================================================================
    ecat_port_controller #(
        .NUM_PORTS          (PHY_COUNT),
        .LOOP_DETECT_EN     (1),
        .REDUNDANCY_EN      (0)
    ) port_ctrl_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Port status inputs
        .port_link_up       (port_link_status),
        .port_rx_active     (port_rx_active),
        .port_tx_active     (port_tx_active),
        // Frame reception info
        .frame_rx_valid     (frame_rx_valid),
        .frame_rx_port      (rx_port_id),
        .frame_src_mac      (frame_src_mac),
        .frame_dst_mac      (frame_dst_mac),
        .frame_is_ecat      (frame_is_ecat),
        .frame_crc_error    (frame_crc_error),
        // Control inputs
        .port_enable        (port_enable[PHY_COUNT-1:0]),
        .fwd_enable         (dl_control_fwd_en),
        .temp_loop_enable   (dl_control_temp_loop),
        .loop_port_sel      ({PHY_COUNT{1'b0}}),
        // Cable redundancy (disabled)
        .redundancy_enable  (1'b0),
        .redundancy_mode    (2'b00),
        .preferred_port     (1'b0),
        // Forwarding outputs (unused)
        .fwd_port_mask      (),
        .fwd_request        (),
        .fwd_exclude_port   (),
        // DL Status outputs
        .dl_status          (dl_status_pc),
        .port_status_packed (),
        // Loop detection
        .loop_detected      (loop_detected),
        .loop_active        (loop_active),
        // Redundancy status (unused)
        .redundancy_active  (),
        .active_path        (),
        .path_switched      (),
        .switch_count       (),
        // Error counters (unused)
        .rx_error_port0     (),
        .rx_error_port1     (),
        .lost_link_port0    (),
        .lost_link_port1    ()
    );

    // ========================================================================
    // Register Map
    // ========================================================================
    ecat_register_map #(
        .VENDOR_ID          (VENDOR_ID),
        .PRODUCT_CODE       (PRODUCT_CODE),
        .REVISION_NUM       (REVISION_NUM),
        .SERIAL_NUM         (SERIAL_NUM),
        .NUM_FMMU           (NUM_FMMU),
        .NUM_SM             (NUM_SM)
    ) register_map_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Register access interface
        .reg_req            (reg_req),
        .reg_wr             (reg_wr),
        .reg_addr           (reg_addr),
        .reg_wdata          (reg_wdata),
        .reg_be             (reg_be),
        .reg_rdata          (reg_rdata),
        .reg_ack            (reg_ack),
        // AL Control interface
        .al_control         (al_control),
        .al_control_changed (al_control_changed),
        .al_status          (al_status),
        .al_status_code     (al_status_code),
        // DL Control interface
        .dl_control_fwd_en  (dl_control_fwd_en),
        .dl_control_temp_loop(dl_control_temp_loop),
        .dl_status          (dl_status),
        // Port configuration
        .port_enable        (port_enable),
        .port_link_status   (port_link_status),
        .port_loop_status   (port_loop_status),
        // Station address
        .station_address    (station_address),
        .station_alias      (station_alias),
        // IRQ
        .irq_mask           (irq_mask),
        .irq_request        (irq_request),
        // SM/FMMU status
        .sm_status          (sm_status),
        .fmmu_status        (fmmu_status),
        .fmmu_error_codes   (fmmu_error_codes),
        // DC
        .dc_system_time     (dc_system_time),
        .dc_sync0_cycle     (dc_sync0_cycle),
        .dc_sync1_cycle     (dc_sync1_cycle),
        // Statistics
        .rx_error_counter   (rx_error_counter),
        .lost_link_counter  (lost_link_counter),
        // FMMU Configuration (directly to FMMU array - directly wired)
        .fmmu_log_start_addr(fmmu_log_start_addr),
        .fmmu_length        (fmmu_length),
        .fmmu_log_start_bit (fmmu_log_start_bit),
        .fmmu_log_end_bit   (fmmu_log_end_bit),
        .fmmu_phys_start_addr(fmmu_phys_start_addr),
        .fmmu_phys_start_bit(fmmu_phys_start_bit),
        .fmmu_read_enable   (fmmu_read_enable),
        .fmmu_write_enable  (fmmu_write_enable),
        .fmmu_enable        (fmmu_enable),
        // SM Configuration (directly to SM array - directly wired)
        .sm_phys_start_addr (sm_phys_start_addr),
        .sm_length          (sm_length),
        .sm_control         (sm_control),
        .sm_enable          (sm_enable),
        .sm_repeat          (sm_repeat),
        .sm_status_in       (sm_status_in),
        .sm_cfg_wr          (sm_cfg_wr),
        .sm_cfg_sel         (sm_cfg_sel),
        .sm_cfg_addr        (sm_cfg_addr),
        .sm_cfg_wdata       (sm_cfg_wdata),
        // Watchdog
        .watchdog_divider   (),
        .watchdog_time_pdi  (),
        .watchdog_time_sm   (),
        .watchdog_enable    (),
        .watchdog_expired   (1'b0)
    );

    // ========================================================================
    // AL State Machine
    // ========================================================================
    ecat_al_statemachine al_sm_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // AL Control
        .al_control_req     (al_control),
        .al_control_changed (al_control_changed),
        // AL Status
        .al_status          (al_status),
        .al_status_code     (al_status_code),
        // SM/FMMU status
        .sm_activate        (sm_status),
        .sm_error           (8'h00),
        .fmmu_activate      (fmmu_status),
        // PDI status
        .pdi_operational    (pdi_operational),
        .pdi_watchdog_timeout(pdi_watchdog_timeout),
        // DC status
        .dc_sync_active     (dc_active),
        .dc_sync_error      (1'b0),
        // EEPROM status
        .eeprom_loaded      (eeprom_loaded),
        .eeprom_error       (eeprom_error),
        // Link status
        .port_link_status   (port_link_status),
        // Control outputs
        .sm_enable          (sm_enable_al),
        .fmmu_enable        (fmmu_enable_al),
        .pdi_enable         (pdi_enable),
        .watchdog_enable    (watchdog_enable_al),
        // IRQ
        .al_event_irq       (al_event_irq)
    );

    // ========================================================================
    // SII/EEPROM Controller
    // ========================================================================
    ecat_sii_controller #(
        .CLK_FREQ_HZ        (ECAT_CLK_FREQ_HZ),
        .I2C_FREQ_HZ        (100000),
        .EEPROM_ADDR        (7'b1010000)
    ) sii_ctrl_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // Register interface
        .reg_req            (sii_reg_req),
        .reg_wr             (sii_reg_wr),
        .reg_addr           (sii_reg_addr),
        .reg_wdata          (sii_reg_wdata),
        .reg_rdata          (sii_reg_rdata),
        .reg_ack            (sii_reg_ack),
        // I2C interface
        .i2c_scl_o          (eeprom_scl_o),
        .i2c_scl_oe         (eeprom_scl_oe),
        .i2c_scl_i          (eeprom_scl_i),
        .i2c_sda_o          (eeprom_sda_o),
        .i2c_sda_oe         (eeprom_sda_oe),
        .i2c_sda_i          (eeprom_sda_i),
        // Status
        .eeprom_loaded      (eeprom_loaded),
        .eeprom_busy        (eeprom_busy),
        .eeprom_error       (eeprom_error)
    );

    // ========================================================================
    // Distributed Clock (DC)
    // ========================================================================
    generate
        if (DC_SUPPORT) begin : gen_dc
            ecat_dc #(
                .CLK_PERIOD_NS      (1000000000 / ECAT_CLK_FREQ_HZ),
                .NUM_PORTS          (PHY_COUNT)
            ) dc_inst (
                .rst_n              (ecat_rst_n_sync),
                .clk                (ecat_clk),
                // Register interface
                .reg_req            (dc_reg_req),
                .reg_wr             (dc_reg_wr),
                .reg_addr           (dc_reg_addr),
                .reg_wdata          (dc_reg_wdata),
                .reg_rdata          (dc_reg_rdata),
                .reg_ack            (dc_reg_ack),
                // Port receive time
                .port_rx_sof        ({PHY_COUNT{rx_sof}}),
                // SYNC I/O
                .sync0_out          (dc_sync0_out),
                .sync1_out          (dc_sync1_out),
                // Latch I/O
                .latch0_in          (dc_latch0_in),
                .latch1_in          (dc_latch1_in),
                // Status
                .system_time        (dc_system_time),
                .dc_active          (dc_active),
                .sync0_active       (sync0_active),
                .sync1_active       (sync1_active)
            );
        end else begin : gen_no_dc
            assign dc_sync0_out = 1'b0;
            assign dc_sync1_out = 1'b0;
            assign dc_system_time = 64'h0;
            assign dc_active = 1'b0;
            assign sync0_active = 1'b0;
            assign sync1_active = 1'b0;
            assign dc_reg_rdata = 16'h0;
            assign dc_reg_ack = 1'b0;
        end
    endgenerate

    // ========================================================================
    // Dual-Port RAM
    // ========================================================================
    ecat_dpram #(
        .ADDR_WIDTH         (13),
        .DATA_WIDTH         (8),
        .RAM_SIZE           (DP_RAM_SIZE),
        .ECAT_PRIORITY      (1)
    ) dpram_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // ECAT Port
        .ecat_req           (dpram_ecat_req),
        .ecat_wr            (dpram_ecat_wr),
        .ecat_addr          (dpram_ecat_addr),
        .ecat_wdata         (dpram_ecat_wdata),
        .ecat_ack           (dpram_ecat_ack),
        .ecat_rdata         (dpram_ecat_rdata),
        .ecat_collision     (dpram_ecat_collision),
        // PDI Port
        .pdi_req            (dpram_pdi_req),
        .pdi_wr             (dpram_pdi_wr),
        .pdi_addr           (dpram_pdi_addr),
        .pdi_wdata          (dpram_pdi_wdata),
        .pdi_ack            (dpram_pdi_ack),
        .pdi_rdata          (dpram_pdi_rdata),
        .pdi_collision      (dpram_pdi_collision),
        // Status
        .collision_count    (collision_count)
    );

    // ========================================================================
    // PDI Avalon Interface
    // ========================================================================
    ecat_pdi_avalon #(
        .ADDR_WIDTH         (PDI_ADDR_WIDTH),
        .DATA_WIDTH         (PDI_DATA_WIDTH)
    ) pdi_avalon_inst (
        .rst_n              (sys_rst_n_sync),
        .clk                (pdi_clk),
        // Avalon interface
        .avs_address        (pdi_address),
        .avs_read           (pdi_read),
        .avs_readdata       (pdi_readdata),
        .avs_readdatavalid  (pdi_readdatavalid),
        .avs_write          (pdi_write),
        .avs_writedata      (pdi_writedata),
        .avs_byteenable     (pdi_byteenable),
        .avs_waitrequest    (pdi_waitrequest),
        // Register access
        .reg_req            (pdi_reg_req),
        .reg_wr             (pdi_reg_wr),
        .reg_addr           (pdi_reg_addr),
        .reg_wdata          (pdi_reg_wdata),
        .reg_be             (pdi_reg_be),
        .reg_rdata          (pdi_reg_rdata),
        .reg_ack            (pdi_reg_ack),
        // SM access
        .sm_id              (pdi_sm_id),
        .sm_pdi_req         (pdi_sm_req),
        .sm_pdi_wr          (pdi_sm_wr),
        .sm_pdi_addr        (pdi_sm_addr),
        .sm_pdi_wdata       (pdi_sm_wdata),
        .sm_pdi_rdata       (pdi_sm_rdata),
        .sm_pdi_ack         (pdi_sm_ack),
        // Control
        .pdi_enable         (pdi_enable),
        .pdi_operational    (pdi_operational),
        .pdi_watchdog_timeout(pdi_watchdog_timeout),
        // IRQ
        .pdi_irq            (pdi_irq),
        .irq_sources        (irq_request)
    );

    // ========================================================================
    // Mailbox Handler and CoE
    // ========================================================================
    ecat_mailbox_handler #(
        .SM0_ADDR           (16'h1000),
        .SM0_SIZE           (128),
        .SM1_ADDR           (16'h1080),
        .SM1_SIZE           (128)
    ) mailbox_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        // SM0/SM1 mailbox flags (derived)
        .sm0_mailbox_full   (mbx_sm0_full),
        .sm0_mailbox_read   (mbx_sm0_read),
        .sm1_mailbox_full   (mbx_sm1_full_out),
        .sm1_mailbox_read   (mbx_sm1_read),
        // Memory interface via SM array (PDI side)
        .mem_req            (mbx_mem_req),
        .mem_wr             (mbx_mem_wr),
        .mem_addr           (mbx_mem_addr),
        .mem_wdata          (mbx_mem_wdata),
        .mem_rdata          (mbx_mem_rdata),
        .mem_ack            (mbx_mem_ack),
        // CoE
        .coe_request        (coe_request),
        .coe_service        (coe_service),
        .coe_index          (coe_index),
        .coe_subindex       (coe_subindex),
        .coe_data           (coe_data),
        .coe_response_ready (coe_response_ready),
        .coe_response_service(coe_response_service),
        .coe_response_data  (coe_response_data),
        .coe_abort_code     (coe_abort_code),
        // Status
        .mailbox_busy       (mbx_busy),
        .mailbox_error      (),
        .mailbox_irq        (mbx_irq)
    );

    ecat_coe_handler #(
        .VENDOR_ID          (VENDOR_ID),
        .PRODUCT_CODE       (PRODUCT_CODE),
        .REVISION_NUM       (REVISION_NUM),
        .SERIAL_NUM         (SERIAL_NUM)
    ) coe_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        .coe_request        (coe_request),
        .coe_service        (coe_service),
        .coe_index          (coe_index),
        .coe_subindex       (coe_subindex),
        .coe_data_in        (coe_data),
        .coe_data_length    (16'd4),
        .coe_response_ready (coe_response_ready),
        .coe_response_service(coe_response_service),
        .coe_response_data  (coe_response_data),
        .coe_abort_code     (coe_abort_code),
        // PDI object access (not implemented)
        .pdi_obj_req        (),
        .pdi_obj_wr         (),
        .pdi_obj_index      (),
        .pdi_obj_subindex   (),
        .pdi_obj_wdata      (),
        .pdi_obj_rdata      (32'h0),
        .pdi_obj_ack        (1'b1),
        .pdi_obj_error      (1'b0),
        // Status
        .coe_busy           (),
        .coe_error          ()
    );

    // ========================================================================
    // Sync Manager Array
    // ========================================================================
    ecat_sync_manager_array #(
        .NUM_SM             (NUM_SM),
        .ADDR_WIDTH         (16),
        .DATA_WIDTH         (8)
    ) sm_array_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        .pdi_clk            (pdi_clk),
        .feature_vector     (FEATURE_VECTOR),
        // Configuration interface
        .cfg_wr             (sm_cfg_wr),
        .cfg_sm_sel         (sm_cfg_sel),
        .cfg_addr           (sm_cfg_addr),
        .cfg_wdata          (sm_cfg_wdata),
        .cfg_rdata          (sm_cfg_rdata),
        // EtherCAT interface (from frame receiver)
        .ecat_req           (sm_ecat_req),
        .ecat_wr            (sm_ecat_wr),
        .ecat_addr          (sm_ecat_addr),
        .ecat_wdata         (sm_ecat_wdata),
        .ecat_ack           (sm_ecat_ack),
        .ecat_rdata         (sm_ecat_rdata),
        // PDI interface
        .pdi_req            (sm_pdi_req_mux),
        .pdi_wr             (sm_pdi_wr_mux),
        .pdi_addr           (sm_pdi_addr_mux),
        .pdi_wdata          (sm_pdi_wdata_mux),
        .pdi_sm_sel         (sm_pdi_sel_mux),
        .pdi_ack            (sm_pdi_ack),
        .pdi_rdata          (sm_pdi_rdata),
        // Memory interface
        .mem_req            (sm_mem_req),
        .mem_wr             (sm_mem_wr),
        .mem_addr           (sm_mem_addr),
        .mem_wdata          (sm_mem_wdata),
        .mem_ack            (sm_mem_ack),
        .mem_rdata          (sm_mem_rdata),
        // Interrupt and status
        .sm_irq             (sm_irq),
        .sm_status_packed   (sm_status_packed),
        .sm_active_bits     (sm_active_bits),
        .ecat_sm_sel        (sm_addr_sel)
    );

    // ========================================================================
    // Mailbox SM selection (based on configured SM ranges)
    // ========================================================================
    always @* begin
        mbx_sm_hit = 1'b0;
        mbx_sm_sel = 3'd0;
        for (mbx_i = 0; mbx_i < NUM_SM; mbx_i = mbx_i + 1) begin
            if (sm_enable[mbx_i]) begin
                if ((mbx_mem_addr >= sm_phys_start_addr[mbx_i*16 +: 16]) &&
                    (mbx_mem_addr < (sm_phys_start_addr[mbx_i*16 +: 16] + sm_length[mbx_i*16 +: 16]))) begin
                    if (!mbx_sm_hit) begin
                        mbx_sm_hit = 1'b1;
                        mbx_sm_sel = mbx_i[2:0];
                    end
                end
            end
        end
    end

    // PDI arbitration: mailbox handler has priority over PDI Avalon
    assign sm_pdi_req_mux   = mbx_mem_req ? mbx_sm_hit : pdi_sm_req;
    assign sm_pdi_wr_mux    = mbx_mem_req ? mbx_mem_wr : pdi_sm_wr;
    assign sm_pdi_addr_mux  = mbx_mem_req ? mbx_mem_addr : pdi_sm_addr;
    assign sm_pdi_wdata_mux = mbx_mem_req ? mbx_mem_wdata : pdi_sm_wdata[7:0];
    assign sm_pdi_sel_mux   = mbx_mem_req ? mbx_sm_sel : pdi_sm_id[2:0];

    assign mbx_mem_ack   = mbx_mem_req ? sm_pdi_ack : 1'b0;
    assign mbx_mem_rdata = sm_pdi_rdata;

    assign pdi_sm_ack   = (!mbx_mem_req) ? sm_pdi_ack : 1'b0;

    // ========================================================================
    // SM Address Decode (match against configured SM regions)
    // ========================================================================
    always @* begin
        sm_addr_hit = 1'b0;
        sm_addr_sel = 3'd0;
        for (sm_i = 0; sm_i < NUM_SM; sm_i = sm_i + 1) begin
            if (sm_enable[sm_i]) begin
                if ((fr_mem_addr >= sm_phys_start_addr[sm_i*16 +: 16]) &&
                    (fr_mem_addr < (sm_phys_start_addr[sm_i*16 +: 16] + sm_length[sm_i*16 +: 16]))) begin
                    if (!sm_addr_hit) begin
                        sm_addr_hit = 1'b1;
                        sm_addr_sel = sm_i[2:0];
                    end
                end
            end
        end
    end

    assign sm_ecat_req = sm_addr_hit && (fr_mem_rd_en || fr_mem_wr_en);
    assign sm_ecat_wr = fr_mem_wr_en;
    assign sm_ecat_addr = fr_mem_addr;
    assign sm_ecat_wdata = fr_mem_wdata[7:0];

    // ========================================================================
    // FMMU Logical Address Translation (simplified)
    // ========================================================================
    always @* begin
        log_hit = 1'b0;
        log_perm_err = 1'b0;
        log_phy_addr = 16'h0000;
        for (f_i = 0; f_i < NUM_FMMU; f_i = f_i + 1) begin
            if (fmmu_enable[f_i]) begin
                fmmu_log_start = fmmu_log_start_addr[f_i*32 +: 32];
                fmmu_len = fmmu_length[f_i*16 +: 16];
                fmmu_end = fmmu_log_start + {16'h0000, fmmu_len};
                if ((fr_log_addr >= fmmu_log_start) && (fr_log_addr < fmmu_end) && !log_hit) begin
                    fmmu_offset = fr_log_addr - fmmu_log_start;
                    log_phy_addr = fmmu_phys_start_addr[f_i*16 +: 16] + fmmu_offset[15:0];
                    if (fr_log_wr && !fmmu_write_enable[f_i])
                        log_perm_err = 1'b1;
                    if (!fr_log_wr && !fmmu_read_enable[f_i])
                        log_perm_err = 1'b1;
                    log_hit = 1'b1;
                end
            end
        end
    end

    assign fr_log_ack = fr_log_req && log_hit && !log_perm_err && dpram_ecat_ack && !sm_mem_grant;
    assign fr_log_err = fr_log_req && (!log_hit || log_perm_err);
    assign fr_log_rdata = dpram_ecat_rdata;

    // ========================================================================
    // Register Access Arbitration
    // ========================================================================
    // Priority: Frame Receiver > PDI > SII > DC > MII
    // Address-based routing for different register ranges
    
    // Address range detection
    wire is_sii_addr = (fr_mem_addr >= 16'h0500) && (fr_mem_addr <= 16'h050F);
    wire is_dc_addr  = (fr_mem_addr >= 16'h0900) && (fr_mem_addr <= 16'h09FF);
    wire is_mii_addr = (fr_mem_addr >= 16'h0510) && (fr_mem_addr <= 16'h0517);
    wire is_sm_addr  = sm_addr_hit;
    wire is_reg_addr = !is_sii_addr && !is_dc_addr && !is_sm_addr && !is_mii_addr;
    
    // Route requests based on address
    wire reg_req_fr = (fr_mem_rd_en || fr_mem_wr_en) && is_reg_addr;
    wire mii_req_fr = (fr_mem_rd_en || fr_mem_wr_en) && is_mii_addr;

    wire pdi_is_mii_addr = (pdi_reg_addr >= 16'h0510) && (pdi_reg_addr <= 16'h0517);
    wire reg_req_pdi = pdi_reg_req && !pdi_is_mii_addr;
    wire mii_req_pdi = pdi_reg_req && pdi_is_mii_addr;

    assign reg_req = reg_req_fr || reg_req_pdi;
    assign reg_wr = reg_req_fr ? fr_mem_wr_en : pdi_reg_wr;
    assign reg_addr = reg_req_fr ? fr_mem_addr : pdi_reg_addr;
    assign reg_wdata = reg_req_fr ? fr_mem_wdata : pdi_reg_wdata;
    assign reg_be = reg_req_fr ? fr_mem_be : pdi_reg_be;
    
    // SII register access (for address range 0x0500-0x050F)
    assign sii_reg_req = (fr_mem_rd_en || fr_mem_wr_en) && is_sii_addr;
    assign sii_reg_wr = fr_mem_wr_en && is_sii_addr;
    assign sii_reg_addr = fr_mem_addr;
    assign sii_reg_wdata = {16'h0, fr_mem_wdata};
    
    // DC register access (for address range 0x0900-0x09FF)
    assign dc_reg_req = (fr_mem_rd_en || fr_mem_wr_en) && is_dc_addr;
    assign dc_reg_wr = fr_mem_wr_en && is_dc_addr;
    assign dc_reg_addr = fr_mem_addr;
    assign dc_reg_wdata = fr_mem_wdata;
    
    // Mux read data and ready signals based on address
    assign fr_mem_rdata = is_sii_addr ? sii_reg_rdata[15:0] :
                          is_dc_addr  ? dc_reg_rdata :
                          is_mii_addr ? mii_reg_rdata :
                          is_sm_addr  ? {8'h00, sm_ecat_rdata} :
                                        reg_rdata;
    assign fr_mem_ready = is_sii_addr ? sii_reg_ack :
                          is_dc_addr  ? dc_reg_ack :
                          is_mii_addr ? mii_reg_ack :
                          is_sm_addr  ? sm_ecat_ack :
                                        reg_ack;
    
    // PDI to register map connection (with MII decode)
    assign pdi_reg_rdata = pdi_is_mii_addr ? mii_reg_rdata : reg_rdata;
    assign pdi_reg_ack = pdi_is_mii_addr ? (mii_reg_ack && !mii_req_fr) : (reg_ack && !reg_req_fr);

    // ========================================================================
    // DPRAM Connections (via Sync Manager array)
    // ========================================================================
    wire sm_mem_grant = sm_mem_req && !fr_log_req;
    assign dpram_ecat_req = sm_mem_grant | (fr_log_req && log_hit && !log_perm_err);
    assign dpram_ecat_wr = sm_mem_grant ? sm_mem_wr : fr_log_wr;
    assign dpram_ecat_addr = sm_mem_grant ? sm_mem_addr[12:0] : log_phy_addr[12:0];
    assign dpram_ecat_wdata = sm_mem_grant ? sm_mem_wdata : fr_log_wdata;
    assign sm_mem_ack = sm_mem_grant ? dpram_ecat_ack : 1'b0;
    assign sm_mem_rdata = dpram_ecat_rdata;
    
    // PDI port unused (SM array arbitrates both sides)
    assign dpram_pdi_req = 1'b0;
    assign dpram_pdi_wr = 1'b0;
    assign dpram_pdi_addr = 13'h0000;
    assign dpram_pdi_wdata = 8'h00;
    
    // pdi_sm_* are driven by SM arbitration above

    // ========================================================================
    // Statistics Aggregation
    // ========================================================================
    assign rx_error_counter = {rx_crc_error_count, rx_error_count};

    // FMMU error latch (minimal)
    always @(posedge ecat_clk or negedge ecat_rst_n_sync) begin
        if (!ecat_rst_n_sync) begin
            fmmu_err_latched <= 8'h00;
        end else begin
            if (fr_log_err) begin
                if (!log_hit)
                    fmmu_err_latched[0] <= 1'b1;
                if (log_perm_err)
                    fmmu_err_latched[4] <= 1'b1;
            end
        end
    end
    
    // Link loss counter - tracks link down events per port
    reg [15:0] link_loss_cnt_0;
    reg [15:0] link_loss_cnt_1;
    reg [PHY_COUNT-1:0] link_up_prev;
    
    always @(posedge ecat_clk or negedge ecat_rst_n_sync) begin
        if (!ecat_rst_n_sync) begin
            link_loss_cnt_0 <= 16'h0;
            link_loss_cnt_1 <= 16'h0;
            link_up_prev <= {PHY_COUNT{1'b0}};
        end else begin
            link_up_prev <= link_up;
            // Detect falling edge on link_up (link lost)
            if (link_up_prev[0] && !link_up[0])
                link_loss_cnt_0 <= link_loss_cnt_0 + 1'b1;
            if (PHY_COUNT > 1 && link_up_prev[1] && !link_up[1])
                link_loss_cnt_1 <= link_loss_cnt_1 + 1'b1;
        end
    end
    assign lost_link_counter = {link_loss_cnt_1, link_loss_cnt_0};

    // ========================================================================
    // IRQ Generation
    // ========================================================================
    assign irq_request = {8'h00, al_event_irq, 7'h00};

    // ========================================================================
    // LED Control
    // ========================================================================
    assign led_link = link_up;
    assign led_act = {PHY_COUNT{rx_valid | tx_valid}};
    assign led_run = (al_status == 5'h08);  // Operational state
    assign led_err = (al_status[4]);         // Error bit set

    // ========================================================================
    // Status Wiring (partial integration)
    // ========================================================================
    assign sm_status = sm_active_bits[7:0];
    assign fmmu_status = fmmu_enable[7:0];
    assign sm_status_in = sm_status_packed;
    assign fmmu_error_codes = { {(NUM_FMMU-1){8'h00}}, fmmu_err_latched };
    assign dl_status = dl_status_pc;

    // ========================================================================
    // Mailbox SM status derivation (simple)
    // ========================================================================
    assign mbx_sm0_full = sm_status_packed[0*8 + 3];
    assign mbx_sm1_full_sm = sm_status_packed[1*8 + 3];
    assign mbx_sm0_read = 1'b0; // TODO: drive via host/PDI when mailbox read completes

    always @(posedge ecat_clk or negedge ecat_rst_n_sync) begin
        if (!ecat_rst_n_sync) begin
            sm1_full_prev <= 1'b0;
        end else begin
            sm1_full_prev <= mbx_sm1_full_sm;
        end
    end
    assign mbx_sm1_read = sm1_full_prev && !mbx_sm1_full_sm;
    
    // RX port selection based on FIFO availability
    always @* begin
        rx_port_pick = 4'd0;
        rx_port_pick_valid = 1'b0;
        for (rx_p = 0; rx_p < PHY_COUNT; rx_p = rx_p + 1) begin
            if (!rx_fifo_empty[rx_p] && !rx_port_pick_valid) begin
                rx_port_pick = rx_p[3:0];
                rx_port_pick_valid = 1'b1;
            end
        end
    end

    always @(posedge ecat_clk or negedge ecat_rst_n_sync) begin
        if (!ecat_rst_n_sync) begin
            rx_port_sel <= 4'h0;
            rx_active <= 1'b0;
        end else begin
            if (!rx_active) begin
                if (rx_port_pick_valid) begin
                    rx_active <= 1'b1;
                    rx_port_sel <= rx_port_pick;
                end
            end else if (rx_fifo_empty[rx_port_sel]) begin
                rx_active <= 1'b0;
            end
        end
    end

    assign rx_valid = rx_active && !rx_fifo_empty[rx_port_sel];
    assign rx_fifo_rd_en = rx_valid ? (1'b1 << rx_port_sel) : {PHY_COUNT{1'b0}};
    assign rx_port_id = rx_port_sel;
    assign rx_data = rx_fifo_rdata[rx_port_sel][7:0];
    assign rx_error = rx_fifo_rdata[rx_port_sel][8];

    always @(posedge ecat_clk or negedge ecat_rst_n_sync) begin
        if (!ecat_rst_n_sync) begin
            rx_in_frame <= 1'b0;
            rx_sof_reg <= 1'b0;
            rx_eof_reg <= 1'b0;
        end else begin
            rx_sof_reg <= 1'b0;
            rx_eof_reg <= 1'b0;
            if (!rx_in_frame && rx_valid) begin
                rx_in_frame <= 1'b1;
                rx_sof_reg <= 1'b1;
            end
            if (rx_valid && (rx_fifo_rd_level[rx_port_sel] == 1)) begin
                rx_in_frame <= 1'b0;
                rx_eof_reg <= 1'b1;
            end
        end
    end
    assign rx_sof = rx_sof_reg;
    assign rx_eof = rx_eof_reg;
    
    // TX ready tied to link status of target port
    wire tx_port_valid = (tx_port_id < PHY_COUNT);
    assign tx_ready = tx_port_valid ? port_link_status[tx_port_id] : 1'b0;

    // ========================================================================
    // MDIO Master (Clause 22)
    // ========================================================================
    assign mii_reg_req = mii_req_fr || mii_req_pdi;
    assign mii_reg_wr = mii_req_fr ? fr_mem_wr_en : pdi_reg_wr;
    assign mii_reg_addr = mii_req_fr ? fr_mem_addr : pdi_reg_addr;
    assign mii_reg_wdata = mii_req_fr ? fr_mem_wdata : pdi_reg_wdata;

    ecat_mdio_master #(
        .CLK_FREQ_HZ        (ECAT_CLK_FREQ_HZ),
        .MDC_FREQ_HZ        (2500000)
    ) mdio_inst (
        .rst_n              (ecat_rst_n_sync),
        .clk                (ecat_clk),
        .reg_req            (mii_reg_req),
        .reg_wr             (mii_reg_wr),
        .reg_addr           (mii_reg_addr),
        .reg_wdata          (mii_reg_wdata),
        .reg_rdata          (mii_reg_rdata),
        .reg_ack            (mii_reg_ack),
        .mdc                (mdio_mdc),
        .mdio_o             (mdio_mdio_o),
        .mdio_oe            (mdio_mdio_oe),
        .mdio_i             (phy_mdio_i),
        .mdio_busy          (mdio_busy),
        .mdio_error         (mdio_error)
    );

    assign phy_mdc = mdio_mdc;
    assign phy_mdio_o = mdio_mdio_o;
    assign phy_mdio_oe = mdio_mdio_oe;

endmodule
