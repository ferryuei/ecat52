// ============================================================================
// TSMC 28nm SRAM Macro Black Box Wrapper
// TS1N28HPCPL2LVTB4096X32M4MWBASO - Single Port SRAM 4096x32
// ============================================================================
// This is a black-box module for DC synthesis.
// The actual SRAM macro will be instantiated during place-and-route.
// For simulation, the behavioral model in ecat_dpram.sv is used instead.
// ============================================================================

module ecat_sram_4096x8 (
    input  wire         CLK,
    input  wire         CEN,     // Chip enable, active low
    input  wire         WEN,     // Write enable, active low
    input  wire [11:0]  A,       // Address
    input  wire [7:0]   D,       // Data input (use byte 0 of 32-bit)
    output wire [7:0]   Q,       // Data output (use byte 0 of 32-bit)
    input  wire         SLP,     // Sleep (active high, tie to 0)
    input  wire         SD       // Shut down (active high, tie to 0)
);

    // Black-box declaration of TSMC SRAM macro
    // Only use byte 0 (bits [7:0]) of the 32-bit data bus
    wire [31:0] q_full;
    wire [31:0] bw_full;  // Byte write enable, active low

    // Only enable write on byte 0
    assign bw_full = 32'hFFFF_FEFF;  // All bytes write-protected except byte 0

    TS1N28HPCPL2LVTB4096X32M4MWBASO sram_inst (
        .CLK    (CLK),
        .CEB    (CEN),
        .WEB    (WEN),
        .A      (A),
        .D      ({24'h0, D}),
        .BWEB   (bw_full),
        .Q      (q_full),
        // Power management - inactive
        .SD     (SD),
        .SLP    (SLP),
        // BIST pins - tie off
        .BIST   (1'b0),
        .CEBM   (1'b0),
        .WEBM   (1'b0),
        .AM     (12'h0),
        .BWEBM  (32'h0),
        .DM     (32'h0)
    );

    assign Q = q_full[7:0];

endmodule
