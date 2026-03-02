// ============================================================================
// EtherCAT Dual-Port RAM
// True dual-port memory with collision handling and arbitration
// Implements MEM-01 to MEM-04 test requirements
// ============================================================================

`include "ecat_pkg.vh"
`include "ecat_core_defines.vh"

module ecat_dpram #(
    parameter ADDR_WIDTH = 13,                // Address width (13 bits to handle OOB check)
    parameter DATA_WIDTH = 8,                 // Data width
    parameter RAM_SIZE = 4096,                // RAM size in bytes
    parameter ECAT_PRIORITY = 1               // 1=ECAT wins collision, 0=PDI wins
)(
    // System signals
    input  wire                     rst_n,
    input  wire                     clk,
    
    // ECAT Port (Port A)
    input  wire                     ecat_req,
    input  wire                     ecat_wr,
    input  wire [ADDR_WIDTH-1:0]    ecat_addr,
    input  wire [DATA_WIDTH-1:0]    ecat_wdata,
    output reg                      ecat_ack,
    output reg  [DATA_WIDTH-1:0]    ecat_rdata,
    output reg                      ecat_collision,   // Collision detected
    
    // PDI Port (Port B)
    input  wire                     pdi_req,
    input  wire                     pdi_wr,
    input  wire [ADDR_WIDTH-1:0]    pdi_addr,
    input  wire [DATA_WIDTH-1:0]    pdi_wdata,
    output reg                      pdi_ack,
    output reg  [DATA_WIDTH-1:0]    pdi_rdata,
    output reg                      pdi_collision,    // Collision detected
    
    // Status
    output reg  [15:0]              collision_count   // Total collisions
);

    // ========================================================================
    // Memory Array
    // ========================================================================
    
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] memory [0:RAM_SIZE-1];
    
    // Actual memory address (lower bits only)
    wire [11:0] ecat_mem_addr = ecat_addr[11:0];
    wire [11:0] pdi_mem_addr = pdi_addr[11:0];
    
    // ========================================================================
    // Address Boundary Check
    // ========================================================================
    
    wire ecat_addr_valid = (ecat_addr < RAM_SIZE);
    wire pdi_addr_valid = (pdi_addr < RAM_SIZE);
    
    // ========================================================================
    // Collision Detection
    // ========================================================================
    
    // Same-cycle write collision to same address
    wire write_collision = ecat_req && pdi_req && 
                          ecat_wr && pdi_wr && 
                          (ecat_addr == pdi_addr) &&
                          ecat_addr_valid && pdi_addr_valid;
    
    // Read-write collision (concurrent read/write to same address)
    wire rw_collision = ecat_req && pdi_req &&
                       (ecat_wr != pdi_wr) &&
                       (ecat_addr == pdi_addr) &&
                       ecat_addr_valid && pdi_addr_valid;
    
    // ========================================================================
    // ECAT Port Logic (Port A)
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ecat_ack <= 1'b0;
            ecat_rdata <= '0;
            ecat_collision <= 1'b0;
        end else begin
            ecat_ack <= 1'b0;
            ecat_collision <= 1'b0;
            
            if (ecat_req) begin
                if (!ecat_addr_valid) begin
                    // Out-of-bounds access - return 0, no error
                    ecat_ack <= 1'b1;
                    ecat_rdata <= '0;
                end else if (write_collision) begin
                    // Write collision
                    ecat_collision <= 1'b1;
                    if (ECAT_PRIORITY) begin
                        // ECAT wins - perform write
                        if (ecat_wr)
                            memory[ecat_mem_addr] <= ecat_wdata;
                        else
                            ecat_rdata <= memory[ecat_mem_addr];
                        ecat_ack <= 1'b1;
                    end else begin
                        // PDI wins - ECAT deferred
                        ecat_ack <= 1'b0;
                    end
                end else begin
                    // Normal access
                    ecat_ack <= 1'b1;
                    if (ecat_wr) begin
                        memory[ecat_mem_addr] <= ecat_wdata;
                    end else begin
                        ecat_rdata <= memory[ecat_mem_addr];
                    end
                end
            end
        end
    end
    
    // ========================================================================
    // PDI Port Logic (Port B)
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pdi_ack <= 1'b0;
            pdi_rdata <= '0;
            pdi_collision <= 1'b0;
        end else begin
            pdi_ack <= 1'b0;
            pdi_collision <= 1'b0;
            
            if (pdi_req) begin
                if (!pdi_addr_valid) begin
                    // Out-of-bounds access - return 0, no error
                    pdi_ack <= 1'b1;
                    pdi_rdata <= '0;
                end else if (write_collision) begin
                    // Write collision
                    pdi_collision <= 1'b1;
                    if (!ECAT_PRIORITY) begin
                        // PDI wins - perform write
                        if (pdi_wr)
                            memory[pdi_mem_addr] <= pdi_wdata;
                        else
                            pdi_rdata <= memory[pdi_mem_addr];
                        pdi_ack <= 1'b1;
                    end else begin
                        // ECAT wins - PDI rejected
                        pdi_ack <= 1'b1;  // Ack but data discarded
                    end
                end else if (rw_collision) begin
                    // Read-write collision - both proceed
                    // Reader gets pre-write or post-write value (implementation defined)
                    pdi_ack <= 1'b1;
                    if (pdi_wr) begin
                        memory[pdi_mem_addr] <= pdi_wdata;
                    end else begin
                        pdi_rdata <= memory[pdi_mem_addr];
                    end
                end else begin
                    // Normal access
                    pdi_ack <= 1'b1;
                    if (pdi_wr) begin
                        memory[pdi_mem_addr] <= pdi_wdata;
                    end else begin
                        pdi_rdata <= memory[pdi_mem_addr];
                    end
                end
            end
        end
    end
    
    // ========================================================================
    // Collision Counter
    // ========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            collision_count <= 16'h0000;
        end else begin
            if (write_collision || rw_collision) begin
                if (collision_count < 16'hFFFF)
                    collision_count <= collision_count + 1'b1;
            end
        end
    end

endmodule
