// ============================================================================
// Clock Domain Crossing FIFO
// Asynchronous FIFO for clock domain crossing with gray code pointers
// ============================================================================

`include "ecat_pkg.vh"

module async_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 4,
    parameter SYNC_STAGES = 2
)(
    // Write side
    input  wire                     wr_rst_n,
    input  wire                     wr_clk,
    input  wire                     wr_en,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output wire                     wr_full,
    output wire [ADDR_WIDTH:0]      wr_level,
    
    // Read side
    input  wire                     rd_rst_n,
    input  wire                     rd_clk,
    input  wire                     rd_en,
    output reg  [DATA_WIDTH-1:0]    rd_data,
    output wire                     rd_empty,
    output wire [ADDR_WIDTH:0]      rd_level
);

    localparam DEPTH = 1 << ADDR_WIDTH;
    
    // Memory
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    
    // Write domain pointers
    reg [ADDR_WIDTH:0] wr_ptr;
    reg [ADDR_WIDTH:0] wr_ptr_gray;
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync [0:SYNC_STAGES-1];
    
    // Read domain pointers
    reg [ADDR_WIDTH:0] rd_ptr;
    reg [ADDR_WIDTH:0] rd_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync [0:SYNC_STAGES-1];
    
    wire [ADDR_WIDTH:0] wr_ptr_next;
    wire [ADDR_WIDTH:0] rd_ptr_next;
    wire [ADDR_WIDTH:0] wr_ptr_gray_next;
    wire [ADDR_WIDTH:0] rd_ptr_gray_next;
    
    integer i;
    
    // Binary to Gray conversion
    function [ADDR_WIDTH:0] bin2gray;
        input [ADDR_WIDTH:0] bin;
        begin
            bin2gray = bin ^ (bin >> 1);
        end
    endfunction
    
    // Gray to Binary conversion
    function [ADDR_WIDTH:0] gray2bin;
        input [ADDR_WIDTH:0] gray;
        integer i;
        begin
            gray2bin[ADDR_WIDTH] = gray[ADDR_WIDTH];
            for (i = ADDR_WIDTH-1; i >= 0; i = i - 1) begin
                gray2bin[i] = gray2bin[i+1] ^ gray[i];
            end
        end
    endfunction
    
    // Write pointer logic
    assign wr_ptr_next = wr_ptr + (wr_en && !wr_full);
    assign wr_ptr_gray_next = bin2gray(wr_ptr_next);
    
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr <= wr_ptr_next;
            wr_ptr_gray <= wr_ptr_gray_next;
        end
    end
    
    // Write data
    always @(posedge wr_clk) begin
        if (wr_en && !wr_full) begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end
    
    // Synchronize read pointer to write domain
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            for (i = 0; i < SYNC_STAGES; i = i + 1) begin
                rd_ptr_gray_sync[i] <= {(ADDR_WIDTH+1){1'b0}};
            end
        end else begin
            rd_ptr_gray_sync[0] <= rd_ptr_gray;
            for (i = 1; i < SYNC_STAGES; i = i + 1) begin
                rd_ptr_gray_sync[i] <= rd_ptr_gray_sync[i-1];
            end
        end
    end
    
    // Full flag
    assign wr_full = (wr_ptr_gray == {~rd_ptr_gray_sync[SYNC_STAGES-1][ADDR_WIDTH:ADDR_WIDTH-1],
                                      rd_ptr_gray_sync[SYNC_STAGES-1][ADDR_WIDTH-2:0]});
    
    // Write level
    assign wr_level = wr_ptr - gray2bin(rd_ptr_gray_sync[SYNC_STAGES-1]);
    
    // Read pointer logic
    assign rd_ptr_next = rd_ptr + (rd_en && !rd_empty);
    assign rd_ptr_gray_next = bin2gray(rd_ptr_next);
    
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr <= rd_ptr_next;
            rd_ptr_gray <= rd_ptr_gray_next;
        end
    end
    
    // Read data
    always @(posedge rd_clk) begin
        rd_data <= mem[rd_ptr[ADDR_WIDTH-1:0]];
    end
    
    // Synchronize write pointer to read domain
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            for (i = 0; i < SYNC_STAGES; i = i + 1) begin
                wr_ptr_gray_sync[i] <= {(ADDR_WIDTH+1){1'b0}};
            end
        end else begin
            wr_ptr_gray_sync[0] <= wr_ptr_gray;
            for (i = 1; i < SYNC_STAGES; i = i + 1) begin
                wr_ptr_gray_sync[i] <= wr_ptr_gray_sync[i-1];
            end
        end
    end
    
    // Empty flag
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync[SYNC_STAGES-1]);
    
    // Read level
    assign rd_level = gray2bin(wr_ptr_gray_sync[SYNC_STAGES-1]) - rd_ptr;

endmodule
