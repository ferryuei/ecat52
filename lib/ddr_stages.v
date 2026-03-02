// ============================================================================
// DDR Input Stage Module
// Converted from VHDL LDD1028 entity
// Double Data Rate input stage for high-speed serial interfaces
// ============================================================================

`include "ecat_pkg.vh"

module ddr_input_stage #(
    parameter DDR_IN_STYLE = "GENERIC"  // "ALTERA", "XILINX", "GENERIC"
)(
    input  wire nreset_rise,            // Reset for rising edge
    input  wire nreset_fall,            // Reset for falling edge
    input  wire ser_in,                 // Serial input
    input  wire clk,                    // Clock
    output reg  [1:0] ser_in_reg        // Registered output [1]=rising, [0]=falling
);

    // Internal signals
    reg ser_in_rise;
    reg ser_in_fall;

    // Rising edge capture
    always @(posedge clk or negedge nreset_rise) begin
        if (!nreset_rise) begin
            ser_in_rise <= 1'b0;
        end else begin
            ser_in_rise <= ser_in;
        end
    end

    // Falling edge capture
    always @(negedge clk or negedge nreset_fall) begin
        if (!nreset_fall) begin
            ser_in_fall <= 1'b0;
        end else begin
            ser_in_fall <= ser_in;
        end
    end

    // Output registration
    always @(posedge clk or negedge nreset_rise) begin
        if (!nreset_rise) begin
            ser_in_reg <= 2'b00;
        end else begin
            ser_in_reg <= {ser_in_rise, ser_in_fall};
        end
    end

endmodule

// ============================================================================
// DDR Output Stage Module
// Converted from VHDL FDD1030 entity
// Double Data Rate output stage for high-speed serial interfaces
// ============================================================================

module ddr_output_stage (
    input  wire aclr,                   // Asynchronous clear
    input  wire datain_h,               // Data for high phase (rising edge)
    input  wire datain_l,               // Data for low phase (falling edge)
    input  wire outclock,               // Output clock
    output reg  dataout                 // DDR output
);

    // DDR output logic
    always @(posedge outclock or posedge aclr) begin
        if (aclr) begin
            dataout <= 1'b0;
        end else begin
            dataout <= datain_h;
        end
    end

    always @(negedge outclock or posedge aclr) begin
        if (aclr) begin
            dataout <= 1'b0;
        end else begin
            dataout <= datain_l;
        end
    end

endmodule
