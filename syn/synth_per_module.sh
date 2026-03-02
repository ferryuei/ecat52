#!/bin/bash
# Synthesize each module individually to get accurate register counts

cd /mnt/d/ECAT/syn
mkdir -p reports

echo "=== EtherCAT IP Core - Per-Module Synthesis Statistics ===" > reports/module_stats.txt
echo "Date: $(date)" >> reports/module_stats.txt
echo "" >> reports/module_stats.txt

# List of modules to synthesize
modules=(
    "ecat_dpram:ecat_dpram"
    "ecat_fmmu:ecat_fmmu"
    "ecat_sync_manager:ecat_sync_manager"
    "ecat_frame_receiver:ecat_frame_receiver"
    "ecat_frame_transmitter:ecat_frame_transmitter"
    "ecat_register_map:ecat_register_map"
    "ecat_dc:ecat_dc"
    "ecat_al_statemachine:ecat_al_statemachine"
    "ecat_pdi_avalon:ecat_pdi_avalon"
    "ecat_core_main:ecat_core_main"
    "ecat_phy_interface:ecat_phy_interface"
)

total_ff=0

for entry in "${modules[@]}"; do
    file="${entry%%:*}"
    top="${entry##*:}"
    
    echo "Processing $top..."
    
    # Find file extension
    if [ -f "../rtl/${file}.sv" ]; then
        srcfile="../rtl/${file}.sv"
    else
        srcfile="../rtl/${file}.v"
    fi
    
    # Create temp synthesis script
    cat > temp_synth.ys << EOF
read_verilog -sv -I../rtl ../rtl/ddr_stages.v
read_verilog -sv -I../rtl ../rtl/synchronizer.v
read_verilog -sv -I../rtl ../rtl/async_fifo.v
read_verilog -sv -I../rtl $srcfile
hierarchy -top $top
proc
opt
memory
opt
stat
EOF
    
    # Run synthesis and capture stats
    output=$(yosys -s temp_synth.ys 2>&1)
    
    # Extract flip-flop count
    ff_count=$(echo "$output" | grep -E "Number of cells:" -A 50 | grep -E "\\\$_DFF|flip-flop|Flip-Flop|DFF" | head -1)
    wire_count=$(echo "$output" | grep "Number of wires:" | head -1)
    cell_count=$(echo "$output" | grep "Number of cells:" | head -1)
    
    echo "" >> reports/module_stats.txt
    echo "=== $top ===" >> reports/module_stats.txt
    echo "$output" | grep -E "Number of|wire bits" >> reports/module_stats.txt
    
done

rm -f temp_synth.ys

echo ""
echo "Results saved to reports/module_stats.txt"
