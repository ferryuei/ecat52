// ============================================================================
// Synchronizer Module
// Converted from VHDL ESY1012 entity
// Multi-stage synchronizer for clock domain crossing
// ============================================================================

`include "ecat_pkg.vh"

module synchronizer #(
    parameter DATA_WIDTH = 1,           // Width of data to synchronize
    parameter SYNC_STAGES = 2,          // Number of synchronization stages
    parameter INIT_VALUE = 0,           // Initial value
    parameter USE_ASYNC = 0             // Use asynchronous reset
)(
    input  wire                     xnr_reset,      // Reset (active low)
    input  wire                     hcl_clk,        // Destination clock
    input  wire                     kwr_sync_en,    // Synchronization enable
    input  wire [DATA_WIDTH-1:0]    nwr_data_in,    // Input data
    input  wire                     hwr_valid_in,   // Input valid
    input  wire                     enr_src_clk,    // Source clock
    input  wire                     fcl_src_en,     // Source enable
    input  wire [SYNC_STAGES-1:0]   ird_sync_reg,   // Sync stage registers
    input  wire                     mrd_read_ack,   // Read acknowledge
    output reg                      rrd_sync_out,   // Synchronized output
    output reg  [DATA_WIDTH-1:0]    brd_data_out,   // Output data
    output reg                      rrd_valid_out,  // Output valid
    output reg                      frd_overflow,   // Overflow flag
    output reg                      yrd_underflow,  // Underflow flag
    output reg                      mrd_error,      // Error flag
    output reg                      erd_status      // Status
);

    // Internal synchronization registers
    reg [SYNC_STAGES-1:0] sync_chain;
    reg [DATA_WIDTH-1:0]  data_reg;
    reg                   valid_reg;

    integer i;

    // Synchronization chain
    always @(posedge hcl_clk or negedge xnr_reset) begin
        if (!xnr_reset) begin
            sync_chain <= {SYNC_STAGES{1'b0}};
            rrd_sync_out <= 1'b0;
        end else if (kwr_sync_en) begin
            sync_chain <= {sync_chain[SYNC_STAGES-2:0], hwr_valid_in};
            rrd_sync_out <= sync_chain[SYNC_STAGES-1];
        end
    end

    // Data capture
    always @(posedge hcl_clk or negedge xnr_reset) begin
        if (!xnr_reset) begin
            data_reg <= {DATA_WIDTH{1'b0}};
            valid_reg <= 1'b0;
        end else begin
            if (sync_chain[SYNC_STAGES-1] && !rrd_sync_out) begin
                data_reg <= nwr_data_in;
                valid_reg <= 1'b1;
            end else if (mrd_read_ack) begin
                valid_reg <= 1'b0;
            end
        end
    end

    // Output assignment
    always @(*) begin
        brd_data_out = data_reg;
        rrd_valid_out = valid_reg;
        frd_overflow = 1'b0;
        yrd_underflow = 1'b0;
        mrd_error = 1'b0;
        erd_status = valid_reg;
    end

endmodule
