#!/bin/bash
# Extract synthesis statistics for all modules

echo "=== EtherCAT IP Core - Module Register Analysis ===" > reports/register_count.txt
echo "Date: $(date)" >> reports/register_count.txt
echo "" >> reports/register_count.txt

total_adff=0
total_adffe=0
total_dff=0

# Function to synthesize and extract stats
analyze_module() {
    local file=$1
    local top=$2
    local ext=$3
    
    yosys -l temp.log -p "read_verilog -sv -I../rtl ../rtl/${file}.${ext}; hierarchy -top $top; proc; opt; stat" 2>&1 > /dev/null
    
    # Extract cell counts
    adff=$(grep '$adff ' temp.log 2>/dev/null | awk '{print $1}' | head -1)
    adffe=$(grep '$adffe' temp.log 2>/dev/null | awk '{print $1}' | head -1)
    dff=$(grep '$dff ' temp.log 2>/dev/null | awk '{print $1}' | head -1)
    sdff=$(grep '$sdff' temp.log 2>/dev/null | awk '{print $1}' | head -1)
    wirebits=$(grep 'wire bits' temp.log 2>/dev/null | awk '{print $1}' | head -1)
    cells=$(grep 'cells$' temp.log 2>/dev/null | awk '{print $1}' | head -1)
    
    # Default to 0 if empty
    adff=${adff:-0}
    adffe=${adffe:-0}
    dff=${dff:-0}
    sdff=${sdff:-0}
    wirebits=${wirebits:-0}
    cells=${cells:-0}
    
    # Total FF cells for this module
    ff_cells=$((adff + adffe + dff + sdff))
    
    echo "$top: adff=$adff adffe=$adffe dff=$dff sdff=$sdff total_ff_cells=$ff_cells wire_bits=$wirebits cells=$cells"
    echo "$top: FF cells=$ff_cells, Wire bits=$wirebits, Total cells=$cells" >> reports/register_count.txt
    
    # Return sum
    echo "$ff_cells"
}

echo "Processing modules..."
echo "" >> reports/register_count.txt

# Process each module
echo "=== Per-Module Statistics ===" >> reports/register_count.txt
echo "" >> reports/register_count.txt

sum=0
for mod in "ecat_phy_interface:ecat_phy_interface:v" \
           "ecat_al_statemachine:ecat_al_statemachine:sv" \
           "ecat_pdi_avalon:ecat_pdi_avalon:sv" \
           "ecat_register_map:ecat_register_map:sv" \
           "ecat_dc:ecat_dc:sv" \
           "ecat_frame_receiver:ecat_frame_receiver:sv" \
           "ecat_frame_transmitter:ecat_frame_transmitter:sv" \
           "ecat_fmmu:ecat_fmmu:sv" \
           "ecat_sync_manager:ecat_sync_manager:sv" \
           "ecat_core_main:ecat_core_main:sv"; do
    
    file=$(echo $mod | cut -d: -f1)
    top=$(echo $mod | cut -d: -f2)
    ext=$(echo $mod | cut -d: -f3)
    
    result=$(analyze_module "$file" "$top" "$ext")
    ff=$(echo "$result" | tail -1)
    sum=$((sum + ff))
done

# DPRAM special case - just report memory size
echo "" >> reports/register_count.txt
echo "=== Memory Modules ===" >> reports/register_count.txt
echo "ecat_dpram: 4KB DPRAM = 32768 bits (should use BRAM, not FFs)" >> reports/register_count.txt
echo "  Control registers estimated: ~50 FFs" >> reports/register_count.txt

echo "" >> reports/register_count.txt
echo "=== Summary ===" >> reports/register_count.txt
echo "Total FF cells from logic modules: $sum" >> reports/register_count.txt
echo "DPRAM control registers (estimated): ~50" >> reports/register_count.txt
echo "DPRAM memory (should be BRAM): 32768 bits" >> reports/register_count.txt

rm -f temp.log
echo ""
echo "Done! Total FF cells: $sum"
cat reports/register_count.txt
