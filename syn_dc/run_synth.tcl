# ============================================================================
# EtherCAT IP Core - Design Compiler Synthesis Script
# Target: TSMC 28nm HPC+ BWP40P140 HVT (tt 1V 25C)
# ============================================================================
# Usage: dc_shell -f run_synth.tcl 2>&1 | tee syn_log.txt
# ============================================================================

# ============================================================================
# Configuration
# ============================================================================
set TOP_MODULE      "ethercat_ipcore_top"
set CLK_NAME        "ecat_clk"
set CLK_PERIOD      40.0    ;# 25 MHz = 40ns
set CLK_LATENCY     0.5
set CLK_UNCERTAINTY 1.0
set INPUT_DELAY     2.0
set OUTPUT_DELAY    2.0
set RESET_NAME      "sys_rst_n"

# ============================================================================
# File paths
# ============================================================================
set RTL_DIR    "../rtl"
set LIB_DIR    "../lib"
set WORK_DIR   "./work"
set RPT_DIR    "./reports"
set OUT_DIR    "./output"
set TMP_DIR    "./tmpfiles"

file mkdir $WORK_DIR
file mkdir $RPT_DIR
file mkdir $OUT_DIR
file mkdir $TMP_DIR

# Redirect intermediate files (.pvl, .syn, .mr) to tmpfiles
define_design_lib WORK -path $TMP_DIR

# ============================================================================
# Step 1: Read Design
# ============================================================================
echo "=========================================="
echo "Step 1: Reading RTL Design"
echo "=========================================="

# All files are read as sverilog because ecat_pkg.vh uses SV constructs
# (functions outside modules, etc.) that are included by both .v and .sv files.

analyze -format sverilog -define USE_SRAM_MACRO [list \
    "$LIB_DIR/ddr_stages.v" \
    "$LIB_DIR/synchronizer.v" \
    "$LIB_DIR/async_fifo.v" \
    "$LIB_DIR/ecat_sram_wrapper.sv" \
    "$LIB_DIR/ecat_dpram.sv" \
    "$RTL_DIR/frame/ecat_frame_receiver.sv" \
    "$RTL_DIR/frame/ecat_frame_transmitter.sv" \
    "$RTL_DIR/frame/ecat_port_controller.sv" \
    "$RTL_DIR/data/ecat_fmmu.sv" \
    "$RTL_DIR/data/ecat_sync_manager.sv" \
    "$RTL_DIR/data/ecat_register_map.sv" \
    "$RTL_DIR/mailbox/ecat_mailbox_handler.sv" \
    "$RTL_DIR/mailbox/ecat_coe_handler.sv" \
    "$RTL_DIR/mailbox/ecat_foe_handler.sv" \
    "$RTL_DIR/mailbox/ecat_eoe_handler.sv" \
    "$RTL_DIR/mailbox/ecat_soe_handler.sv" \
    "$RTL_DIR/mailbox/ecat_voe_handler.sv" \
    "$RTL_DIR/control/ecat_al_statemachine.sv" \
    "$RTL_DIR/dc/ecat_dc.sv" \
    "$RTL_DIR/interface/ecat_sii_controller.sv" \
    "$RTL_DIR/interface/ecat_mdio_master.sv" \
    "$RTL_DIR/interface/ecat_pdi_avalon.sv" \
    "$RTL_DIR/interface/ecat_phy_interface.v" \
    "$RTL_DIR/ethercat_ipcore_top.v" \
]

# Elaborate
echo "Elaborating $TOP_MODULE..."
elaborate $TOP_MODULE

current_design $TOP_MODULE
link

# Mark SRAM macro as don't-touch (black box, handled by P&R)
set_dont_touch [get_cells -hierarchical -filter "is_black_box == true"]
set_dont_touch u_sram

check_design

# ============================================================================
# Step 2: Constrain Design
# ============================================================================
echo "=========================================="
echo "Step 2: Applying Constraints"
echo "=========================================="

# Clocks
create_clock -name ecat_clk -period $CLK_PERIOD [get_ports ecat_clk]
create_clock -name sys_clk  -period 20.0        [get_ports sys_clk]
create_clock -name pdi_clk  -period 10.0        [get_ports pdi_clk]

# Clock uncertainty & latency
set_clock_uncertainty $CLK_UNCERTAINTY [all_clocks]
set_clock_latency $CLK_LATENCY [all_clocks]

# Don't touch clock & reset networks
set_ideal_network [get_ports "$CLK_NAME sys_clk pdi_clk sys_rst_n ecat_clk_ddr"]
set_drive 0 [get_ports "$RESET_NAME"]

# Input delays (relative to each clock domain)
set_input_delay $INPUT_DELAY -clock ecat_clk \
    [remove_from_collection [all_inputs] \
     [get_ports "ecat_clk sys_clk pdi_clk sys_rst_n ecat_clk_ddr phy_rx_clk* phy_mdc phy_mdio_i eeprom_scl_i eeprom_sda_i dc_latch0_in dc_latch1_in"]]
set_input_delay $INPUT_DELAY -clock sys_clk  [get_ports "pdi_*"]
set_input_delay $INPUT_DELAY -clock pdi_clk  [get_ports "pdi_clk"]

# Output delays
set_output_delay $OUTPUT_DELAY -clock ecat_clk \
    [get_ports "phy_* led_* dc_sync* eeprom_*"]
set_output_delay $OUTPUT_DELAY -clock sys_clk \
    [get_ports "pdi_readdata pdi_readdatavalid pdi_waitrequest pdi_irq"]

# Input drive strength
set_driving_cell -lib_cell INVD1BWP40P140HVT \
    [remove_from_collection [all_inputs] \
     [get_ports "ecat_clk sys_clk pdi_clk sys_rst_n ecat_clk_ddr"]]

# Output load
set_load 0.02 [all_outputs]

# Fanout
set_max_fanout 16 [all_inputs]

# Area
set_max_area 0

# False paths between clock domains
set_false_path -from [get_clocks ecat_clk] -to [get_clocks sys_clk]
set_false_path -from [get_clocks sys_clk]  -to [get_clocks ecat_clk]
set_false_path -from [get_clocks ecat_clk] -to [get_clocks pdi_clk]
set_false_path -from [get_clocks pdi_clk]  -to [get_clocks ecat_clk]
set_false_path -from [get_clocks sys_clk]  -to [get_clocks pdi_clk]
set_false_path -from [get_clocks pdi_clk]  -to [get_clocks sys_clk]

# ============================================================================
# Step 3: Compile
# ============================================================================
echo "=========================================="
echo "Step 3: Compiling Design"
echo "=========================================="

compile -map_effort medium

# ============================================================================
# Step 4: Reports
# ============================================================================
echo "=========================================="
echo "Step 4: Generating Reports"
echo "=========================================="

report_timing -max_paths 10 -nworst 5 -delay max > $RPT_DIR/timing_max.rpt
report_timing -max_paths 10 -nworst 5 -delay min > $RPT_DIR/timing_min.rpt
report_area -hierarchy -nosplit > $RPT_DIR/area.rpt
report_power -hierarchy -nosplit > $RPT_DIR/power.rpt
report_resource > $RPT_DIR/resource.rpt
report_constraint -all_violators > $RPT_DIR/constraints.rpt
report_clock -skew -attributes > $RPT_DIR/clocks.rpt
report_reference -hierarchy > $RPT_DIR/reference.rpt

# Summary
redirect $RPT_DIR/summary.rpt {
    echo "============================================"
    echo "EtherCAT IP Core - Synthesis Summary"
    echo "Library: TSMC 28nm HPC+ BWP40P140 HVT (tt 1V 25C)"
    echo "============================================"
    echo ""
    echo "=== Timing (WNS) ==="
    report_timing -delay max -max_paths 1 -nosplit
    echo ""
    echo "=== Area ==="
    report_area -nosplit
    echo ""
    echo "=== Power ==="
    report_power -nosplit
}

# ============================================================================
# Step 5: Output
# ============================================================================
echo "=========================================="
echo "Step 5: Writing Output"
echo "=========================================="

define_name_rules verilog -type net
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output $OUT_DIR/${TOP_MODULE}_netlist.v
write_sdc $OUT_DIR/${TOP_MODULE}.sdc
write -format ddc -hierarchy -output $OUT_DIR/${TOP_MODULE}.ddc

echo ""
echo "============================================"
echo "Synthesis Complete!"
echo "============================================"
echo "Reports: $RPT_DIR/"
echo "Output:  $OUT_DIR/"
echo "============================================"

exit
