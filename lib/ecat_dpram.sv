// ============================================================================
// EtherCAT Dual-Port RAM
// True dual-port memory with collision handling and arbitration
// Implements MEM-01 to MEM-04 test requirements
//
// For ASIC synthesis (USE_SRAM_MACRO defined):
//   Uses single-port SRAM macro + arbiter for dual-port emulation
//   SRAM: TS1N28HPCPL2LVTB4096X32M4MWBASO (4096x32, only byte 0 used)
//
// For simulation / FPGA (USE_SRAM_MACRO not defined):
//   Uses behavioral reg array (original implementation)
// ============================================================================

`include "ecat_pkg.vh"
`include "ecat_core_defines.vh"

module ecat_dpram #(
    parameter ADDR_WIDTH = 13,
    parameter DATA_WIDTH = 8,
    parameter RAM_SIZE = 4096,
    parameter ECAT_PRIORITY = 1
)(
    input  wire                     rst_n,
    input  wire                     clk,

    // ECAT Port (Port A)
    input  wire                     ecat_req,
    input  wire                     ecat_wr,
    input  wire [ADDR_WIDTH-1:0]    ecat_addr,
    input  wire [DATA_WIDTH-1:0]    ecat_wdata,
    output reg                      ecat_ack,
    output reg  [DATA_WIDTH-1:0]    ecat_rdata,
    output reg                      ecat_collision,

    // PDI Port (Port B)
    input  wire                     pdi_req,
    input  wire                     pdi_wr,
    input  wire [ADDR_WIDTH-1:0]    pdi_addr,
    input  wire [DATA_WIDTH-1:0]    pdi_wdata,
    output reg                      pdi_ack,
    output reg  [DATA_WIDTH-1:0]    pdi_rdata,
    output reg                      pdi_collision,

    // Status
    output reg  [15:0]              collision_count
);

`ifdef USE_SRAM_MACRO

    // ========================================================================
    // ASIC Implementation: Single-port SRAM + Arbiter
    // ========================================================================

    // Actual memory address (lower 12 bits for 4096 depth)
    wire [11:0] ecat_mem_addr = ecat_addr[11:0];
    wire [11:0] pdi_mem_addr  = pdi_addr[11:0];

    wire ecat_addr_valid = (ecat_addr < RAM_SIZE);
    wire pdi_addr_valid  = (pdi_addr < RAM_SIZE);

    // Collision detection
    wire write_collision = ecat_req && pdi_req &&
                           ecat_wr && pdi_wr &&
                           (ecat_addr == pdi_addr) &&
                           ecat_addr_valid && pdi_addr_valid;

    wire rw_collision = ecat_req && pdi_req &&
                        (ecat_wr != pdi_wr) &&
                        (ecat_addr == pdi_addr) &&
                        ecat_addr_valid && pdi_addr_valid;

    // --------------------------------------------------------------------
    // SRAM Arbiter: Time-division multiplexing for dual-port emulation
    // Cycle 0: ECAT access (if requested)
    // Cycle 1: PDI access  (if requested)
    // When both request same cycle, ECAT has priority
    // --------------------------------------------------------------------
    reg        sram_cen;
    reg        sram_wen;
    reg  [11:0] sram_addr;
    reg  [7:0]  sram_din;
    wire [7:0]  sram_dout;

    // Arbitration state
    reg        arb_pdi_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_cen        <= 1'b1;  // Disabled
            sram_wen        <= 1'b1;  // No write
            sram_addr       <= 12'h0;
            sram_din        <= 8'h0;
            arb_pdi_pending <= 1'b0;
        end else begin
            sram_cen <= 1'b1; // Default: disabled

            if (ecat_req && ecat_addr_valid && !write_collision) begin
                // ECAT has priority
                sram_cen  <= 1'b0;  // Enable
                sram_wen  <= ~ecat_wr;
                sram_addr <= ecat_mem_addr;
                sram_din  <= ecat_wdata;

                // If PDI also wants access, defer to next cycle
                if (pdi_req && pdi_addr_valid && !write_collision)
                    arb_pdi_pending <= 1'b1;
                else
                    arb_pdi_pending <= 1'b0;
            end else if (arb_pdi_pending || (pdi_req && pdi_addr_valid && !write_collision)) begin
                // PDI access (deferred or direct)
                sram_cen        <= 1'b0;
                sram_wen        <= ~pdi_wr;
                sram_addr       <= pdi_mem_addr;
                sram_din        <= pdi_wdata;
                arb_pdi_pending <= 1'b0;
            end else begin
                arb_pdi_pending <= 1'b0;
            end
        end
    end

    // SRAM instance
    ecat_sram_4096x8 u_sram (
        .CLK    (clk),
        .CEN    (sram_cen),
        .WEN    (sram_wen),
        .A      (sram_addr),
        .D      (sram_din),
        .Q      (sram_dout),
        .SLP    (1'b0),
        .SD     (1'b0)
    );

    // --------------------------------------------------------------------
    // ECAT Port Response
    // --------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ecat_ack       <= 1'b0;
            ecat_rdata     <= '0;
            ecat_collision <= 1'b0;
        end else begin
            ecat_ack       <= 1'b0;
            ecat_collision <= 1'b0;

            if (ecat_req) begin
                if (!ecat_addr_valid) begin
                    ecat_ack   <= 1'b1;
                    ecat_rdata <= '0;
                end else if (write_collision) begin
                    ecat_collision <= 1'b1;
                    if (ECAT_PRIORITY) begin
                        ecat_ack <= 1'b1;
                        // ECAT wins - data handled by arbiter
                    end
                end else begin
                    ecat_ack <= 1'b1;
                    if (!ecat_wr) begin
                        // Read: capture SRAM output (1 cycle latency)
                        ecat_rdata <= sram_dout;
                    end
                end
            end
        end
    end

    // --------------------------------------------------------------------
    // PDI Port Response
    // --------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pdi_ack       <= 1'b0;
            pdi_rdata     <= '0;
            pdi_collision <= 1'b0;
        end else begin
            pdi_ack       <= 1'b0;
            pdi_collision <= 1'b0;

            if (pdi_req) begin
                if (!pdi_addr_valid) begin
                    pdi_ack   <= 1'b1;
                    pdi_rdata <= '0;
                end else if (write_collision) begin
                    pdi_collision <= 1'b1;
                    pdi_ack       <= 1'b1;
                end else if (rw_collision) begin
                    pdi_ack <= 1'b1;
                    if (!pdi_wr)
                        pdi_rdata <= sram_dout;
                end else begin
                    pdi_ack <= 1'b1;
                    if (!pdi_wr)
                        pdi_rdata <= sram_dout;
                end
            end
        end
    end

    // Collision counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            collision_count <= 16'h0000;
        else if (write_collision || rw_collision)
            if (collision_count < 16'hFFFF)
                collision_count <= collision_count + 1'b1;
    end

`else

    // ========================================================================
    // Behavioral Implementation: reg array (for simulation / FPGA)
    // ========================================================================

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] memory [0:RAM_SIZE-1];

    wire [11:0] ecat_mem_addr = ecat_addr[11:0];
    wire [11:0] pdi_mem_addr  = pdi_addr[11:0];

    wire ecat_addr_valid = (ecat_addr < RAM_SIZE);
    wire pdi_addr_valid  = (pdi_addr < RAM_SIZE);

    wire write_collision = ecat_req && pdi_req &&
                           ecat_wr && pdi_wr &&
                           (ecat_addr == pdi_addr) &&
                           ecat_addr_valid && pdi_addr_valid;

    wire rw_collision = ecat_req && pdi_req &&
                        (ecat_wr != pdi_wr) &&
                        (ecat_addr == pdi_addr) &&
                        ecat_addr_valid && pdi_addr_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ecat_ack       <= 1'b0;
            ecat_rdata     <= '0;
            ecat_collision <= 1'b0;
        end else begin
            ecat_ack       <= 1'b0;
            ecat_collision <= 1'b0;

            if (ecat_req) begin
                if (!ecat_addr_valid) begin
                    ecat_ack   <= 1'b1;
                    ecat_rdata <= '0;
                end else if (write_collision) begin
                    ecat_collision <= 1'b1;
                    if (ECAT_PRIORITY) begin
                        if (ecat_wr)
                            memory[ecat_mem_addr] <= ecat_wdata;
                        else
                            ecat_rdata <= memory[ecat_mem_addr];
                        ecat_ack <= 1'b1;
                    end else begin
                        ecat_ack <= 1'b0;
                    end
                end else begin
                    ecat_ack <= 1'b1;
                    if (ecat_wr)
                        memory[ecat_mem_addr] <= ecat_wdata;
                    else
                        ecat_rdata <= memory[ecat_mem_addr];
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pdi_ack       <= 1'b0;
            pdi_rdata     <= '0;
            pdi_collision <= 1'b0;
        end else begin
            pdi_ack       <= 1'b0;
            pdi_collision <= 1'b0;

            if (pdi_req) begin
                if (!pdi_addr_valid) begin
                    pdi_ack   <= 1'b1;
                    pdi_rdata <= '0;
                end else if (write_collision) begin
                    pdi_collision <= 1'b1;
                    if (!ECAT_PRIORITY) begin
                        if (pdi_wr)
                            memory[pdi_mem_addr] <= pdi_wdata;
                        else
                            pdi_rdata <= memory[pdi_mem_addr];
                        pdi_ack <= 1'b1;
                    end else begin
                        pdi_ack <= 1'b1;
                    end
                end else if (rw_collision) begin
                    pdi_ack <= 1'b1;
                    if (pdi_wr)
                        memory[pdi_mem_addr] <= pdi_wdata;
                    else
                        pdi_rdata <= memory[pdi_mem_addr];
                end else begin
                    pdi_ack <= 1'b1;
                    if (pdi_wr)
                        memory[pdi_mem_addr] <= pdi_wdata;
                    else
                        pdi_rdata <= memory[pdi_mem_addr];
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            collision_count <= 16'h0000;
        else if (write_collision || rw_collision)
            if (collision_count < 16'hFFFF)
                collision_count <= collision_count + 1'b1;
    end

`endif // USE_SRAM_MACRO

endmodule
