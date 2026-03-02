// ============================================================================
// EtherCAT IP Core - Package Definitions
// Converted from VHDL to Verilog
// Original: HDL Fileparser V6.8 - generated 29.05.2019 09:46:16
// ============================================================================

`ifndef ECAT_PKG_VH
`define ECAT_PKG_VH

// ============================================================================
// Global Constants
// ============================================================================
`define GCC_MAGIC 32'hDEBB20E3

// ============================================================================
// Feature Vector Size
// ============================================================================
`define FEATURE_VECTOR_SIZE 256

// ============================================================================
// Function: Logarithm base 2 (ceiling)
// ============================================================================
function integer log2;
    input integer value;
    integer temp;
    begin
        temp = value;
        for (log2 = 0; temp > 0; log2 = log2 + 1)
            temp = temp >> 1;
    end
endfunction

// ============================================================================
// Function: Calculate logarithm to base 2 (used for address width)
// ============================================================================
function integer log_to_base2;
    input integer value;
    integer result;
    begin
        result = 0;
        while ((2**result) < value) begin
            result = result + 1;
        end
        log_to_base2 = result;
    end
endfunction

// ============================================================================
// Function: Selection multiplexer (similar to VHDL select function)
// ============================================================================
function integer sel_func_int;
    input sel;
    input integer a;
    input integer b;
    begin
        sel_func_int = sel ? b : a;
    end
endfunction

// ============================================================================
// Function: Minimum of integers
// ============================================================================
function integer min2;
    input integer a;
    input integer b;
    begin
        min2 = (a < b) ? a : b;
    end
endfunction

function integer min3;
    input integer a;
    input integer b;
    input integer c;
    begin
        min3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
    end
endfunction

// ============================================================================
// Function: Maximum of integers
// ============================================================================
function integer max2;
    input integer a;
    input integer b;
    begin
        max2 = (a > b) ? a : b;
    end
endfunction

function integer max3;
    input integer a;
    input integer b;
    input integer c;
    begin
        max3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
    end
endfunction

// ============================================================================
// Function: Clamp value between min and max
// ============================================================================
function integer clamp;
    input integer value;
    input integer min_val;
    input integer max_val;
    begin
        clamp = (value < min_val) ? min_val : ((value > max_val) ? max_val : value);
    end
endfunction

`endif // ECAT_PKG_VH
