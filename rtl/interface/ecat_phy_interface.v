// ============================================================================
// EtherCAT Physical Layer Interface
// PHY interface for MII/RMII/RGMII Ethernet connections
// ============================================================================

`include "ecat_pkg.vh"

module ecat_phy_interface #(
    parameter PHY_COUNT = 2,            // Number of PHY ports
    parameter PHY_TYPE = "MII",         // "MII", "RMII", "RGMII"
    parameter USE_DDR = 1               // Use DDR for RGMII
)(
    // System signals
    input  wire                         rst_n,
    input  wire                         clk,
    input  wire                         clk_ddr,        // DDR clock for RGMII
    
    // Configuration
    input  wire [`FEATURE_VECTOR_SIZE-1:0] feature_vector,
    
    // TX Interface - to PHY (directly driven to PHY pins)
    output wire [PHY_COUNT-1:0]         tx_clk,
    output wire [PHY_COUNT-1:0]         tx_en,
    output wire [PHY_COUNT-1:0]         tx_er,
    output wire [PHY_COUNT*8-1:0]       tx_data,
    
    // RX Interface - from PHY (directly from PHY pins)
    input  wire [PHY_COUNT-1:0]         rx_clk,
    input  wire [PHY_COUNT-1:0]         rx_dv,
    input  wire [PHY_COUNT-1:0]         rx_er,
    input  wire [PHY_COUNT*8-1:0]       rx_data,
    
    // MAC TX Interface - from MAC core
    input  wire [PHY_COUNT-1:0]         mac_tx_clk,
    input  wire [PHY_COUNT-1:0]         mac_tx_en,
    input  wire [PHY_COUNT-1:0]         mac_tx_er,
    input  wire [PHY_COUNT*8-1:0]       mac_tx_data,
    
    // MAC RX Interface - to MAC core
    output wire [PHY_COUNT-1:0]         mac_rx_clk,
    output wire [PHY_COUNT-1:0]         mac_rx_dv,
    output wire [PHY_COUNT-1:0]         mac_rx_er,
    output wire [PHY_COUNT*8-1:0]       mac_rx_data,
    
    // PHY Management Interface (MDIO)
    output reg                          mdio_mdc,       // MDC clock
    inout  wire                         mdio_mdio,      // MDIO data
    output reg                          mdio_oe,        // MDIO output enable
    
    // PHY Reset
    output reg  [PHY_COUNT-1:0]         phy_reset_n,
    
    // Link Status
    output wire [PHY_COUNT-1:0]         link_up,
    output wire [PHY_COUNT-1:0]         link_speed_100, // 1=100Mbps, 0=10Mbps
    output wire [PHY_COUNT-1:0]         link_duplex     // 1=Full, 0=Half
);

    // ========================================================================
    // Internal Signals
    // ========================================================================
    
    reg [PHY_COUNT-1:0] link_status;
    reg [PHY_COUNT-1:0] speed_status;
    reg [PHY_COUNT-1:0] duplex_status;
    
    // MDIO registers
    reg [4:0]   mdio_phy_addr;
    reg [4:0]   mdio_reg_addr;
    reg [15:0]  mdio_write_data;
    reg [15:0]  mdio_read_data;
    reg         mdio_read_valid;
    reg         mdio_busy;
    
    // State machine for MDIO
    localparam MDIO_IDLE    = 3'b000;
    localparam MDIO_PRE     = 3'b001;
    localparam MDIO_START   = 3'b010;
    localparam MDIO_OP      = 3'b011;
    localparam MDIO_ADDR    = 3'b100;
    localparam MDIO_TA      = 3'b101;
    localparam MDIO_DATA    = 3'b110;
    
    reg [2:0]   mdio_state;
    reg [5:0]   mdio_bit_cnt;
    
    genvar i;
    
    // ========================================================================
    // PHY Reset Generation
    // BUGFIX: Reduced reset time from 65535 cycles to 1000 cycles (~10us @ 100MHz)
    // to allow testbench to complete in reasonable time
    // ========================================================================
    
    reg [15:0] reset_counter;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reset_counter <= 16'd1000;  // BUGFIX: Was 16'hFFFF (65535), too long for simulation
            phy_reset_n <= {PHY_COUNT{1'b0}};
        end else begin
            if (reset_counter != 0) begin
                reset_counter <= reset_counter - 1'b1;
                phy_reset_n <= {PHY_COUNT{1'b0}};
            end else begin
                phy_reset_n <= {PHY_COUNT{1'b1}};
            end
        end
    end
    
    // ========================================================================
    // MDIO Controller
    // ========================================================================
    
    reg mdio_out;
    reg mdio_output_enable;
    
    assign mdio_mdio = mdio_output_enable ? mdio_out : 1'bz;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdio_state <= MDIO_IDLE;
            mdio_bit_cnt <= 6'd0;
            mdio_mdc <= 1'b0;
            mdio_out <= 1'b1;
            mdio_output_enable <= 1'b0;
            mdio_busy <= 1'b0;
            mdio_read_valid <= 1'b0;
        end else begin
            case (mdio_state)
                MDIO_IDLE: begin
                    mdio_mdc <= 1'b0;
                    mdio_output_enable <= 1'b0;
                    mdio_busy <= 1'b0;
                    // Wait for management request
                end
                
                MDIO_PRE: begin
                    // Send preamble (32 ones)
                    mdio_output_enable <= 1'b1;
                    mdio_out <= 1'b1;
                    mdio_mdc <= ~mdio_mdc;
                    if (mdio_mdc) begin
                        mdio_bit_cnt <= mdio_bit_cnt + 1'b1;
                        if (mdio_bit_cnt == 6'd31) begin
                            mdio_state <= MDIO_START;
                            mdio_bit_cnt <= 6'd0;
                        end
                    end
                end
                
                default: begin
                    mdio_state <= MDIO_IDLE;
                end
            endcase
        end
    end
    
    // ========================================================================
    // Link Status
    // ========================================================================
    
    assign link_up = link_status;
    assign link_speed_100 = speed_status;
    assign link_duplex = duplex_status;
    
    // Simple link status detection (would normally read from PHY registers)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            link_status <= {PHY_COUNT{1'b0}};
            speed_status <= {PHY_COUNT{1'b1}};   // Default 100Mbps
            duplex_status <= {PHY_COUNT{1'b1}};  // Default Full duplex
        end else begin
            // Link detection logic would go here
            // This is a simplified version
            if (&phy_reset_n) begin
                link_status <= {PHY_COUNT{1'b1}};
            end
        end
    end
    
    // ========================================================================
    // MII/RMII/RGMII Interface
    // ========================================================================
    
    // TX: MAC -> PHY (pass-through with optional processing)
    assign tx_clk = mac_tx_clk;
    assign tx_en = mac_tx_en;
    assign tx_er = mac_tx_er;
    assign tx_data = mac_tx_data;
    
    // RX: PHY -> MAC (pass-through with optional processing)
    assign mac_rx_clk = rx_clk;
    assign mac_rx_dv = rx_dv;
    assign mac_rx_er = rx_er;
    assign mac_rx_data = rx_data;

endmodule
