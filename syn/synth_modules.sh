#!/bin/bash
# Synthesize each module and extract register count

echo "=== Per-Module Synthesis Statistics ===" > reports/module_stats.txt
echo "Date: $(date)" >> reports/module_stats.txt

# Function to synthesize a module and get stats
synth_module() {
    local file=$1
    local top=$2
    local ext=$3
    
    echo "Synthesizing $top..."
    
    # Create synthesis script - use proc only to avoid memory explosion
    cat > temp_synth.ys << EOF
read_verilog -sv -I../rtl ../rtl/${file}.${ext}
hierarchy -top $top
proc
opt
stat
EOF
    
    # Run synthesis and capture output
    output=$(timeout 60 yosys -s temp_synth.ys 2>&1)
    
    # Extract statistics
    cells=$(echo "$output" | grep "Number of cells:" | tail -1 | awk '{print $4}')
    wires=$(echo "$output" | grep "Number of wires:" | tail -1 | awk '{print $4}')
    wirebits=$(echo "$output" | grep "Number of wire bits:" | tail -1 | awk '{print $5}')
    
    # Count flip-flops (look for $dff patterns)
    dff_count=$(echo "$output" | grep -E '\$dff|\$adff|\$sdff' | awk '{sum += $2} END {print sum+0}')
    
    echo "" >> reports/module_stats.txt
    echo "=== $top ===" >> reports/module_stats.txt
    echo "Cells: $cells" >> reports/module_stats.txt
    echo "Wires: $wires" >> reports/module_stats.txt
    echo "Wire bits: $wirebits" >> reports/module_stats.txt
    echo "DFF estimate: $dff_count" >> reports/module_stats.txt
    
    # Return the wire bits as a proxy for register count (before memory expansion)
    echo "$top:$wirebits:$dff_count"
}

# Synthesize each module
synth_module "ecat_phy_interface" "ecat_phy_interface" "v"
synth_module "ecat_al_statemachine" "ecat_al_statemachine" "sv"
synth_module "ecat_pdi_avalon" "ecat_pdi_avalon" "sv"
synth_module "ecat_register_map" "ecat_register_map" "sv"
synth_module "ecat_dc" "ecat_dc" "sv"
synth_module "ecat_frame_receiver" "ecat_frame_receiver" "sv"
synth_module "ecat_frame_transmitter" "ecat_frame_transmitter" "sv"
synth_module "ecat_fmmu" "ecat_fmmu" "sv"
synth_module "ecat_sync_manager" "ecat_sync_manager" "sv"
synth_module "ecat_core_main" "ecat_core_main" "sv"

# DPRAM needs special handling - just count declared registers, not expanded memory
echo "" >> reports/module_stats.txt
echo "=== ecat_dpram (BRAM - not expanded) ===" >> reports/module_stats.txt
echo "Memory: 4096 x 8 bits = 32768 bits (should be BRAM)" >> reports/module_stats.txt
echo "Control registers: ~50 FFs estimated" >> reports/module_stats.txt

rm -f temp_synth.ys
echo ""
echo "Done! Results in reports/module_stats.txt"
