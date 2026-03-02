# ============================================================================
# EtherCAT IP Core - Synthesis & Lint Makefile
# Updated: 2026-02-06 - Reorganized directory structure
# ============================================================================

# Tool paths
VERILATOR := verilator

# Directories
RTL_DIR := ../rtl
LIB_DIR := ../lib
SYN_DIR := .
REPORT_DIR := reports

# RTL Source Files (order matters for dependencies)
RTL_INCLUDES := \
	$(LIB_DIR)/ecat_pkg.vh \
	$(LIB_DIR)/ecat_core_defines.vh

LIB_SOURCES := \
	$(LIB_DIR)/ddr_stages.v \
	$(LIB_DIR)/synchronizer.v \
	$(LIB_DIR)/async_fifo.v \
	$(LIB_DIR)/ecat_dpram.sv

RTL_SOURCES := \
	$(RTL_DIR)/frame/ecat_frame_receiver.sv \
	$(RTL_DIR)/frame/ecat_frame_transmitter.sv \
	$(RTL_DIR)/frame/ecat_port_controller.sv \
	$(RTL_DIR)/data/ecat_fmmu.sv \
	$(RTL_DIR)/data/ecat_sync_manager.sv \
	$(RTL_DIR)/data/ecat_register_map.sv \
	$(RTL_DIR)/mailbox/ecat_mailbox_handler.sv \
	$(RTL_DIR)/mailbox/ecat_coe_handler.sv \
	$(RTL_DIR)/mailbox/ecat_foe_handler.sv \
	$(RTL_DIR)/mailbox/ecat_eoe_handler.sv \
	$(RTL_DIR)/mailbox/ecat_soe_handler.sv \
	$(RTL_DIR)/mailbox/ecat_voe_handler.sv \
	$(RTL_DIR)/control/ecat_al_statemachine.sv \
	$(RTL_DIR)/dc/ecat_dc.sv \
	$(RTL_DIR)/interface/ecat_sii_controller.sv \
	$(RTL_DIR)/interface/ecat_mdio_master.sv \
	$(RTL_DIR)/interface/ecat_pdi_avalon.sv \
	$(RTL_DIR)/interface/ecat_phy_interface.v \
	$(RTL_DIR)/ethercat_ipcore_top.v

ALL_SOURCES := $(LIB_SOURCES) $(RTL_SOURCES)

TOP_MODULE := ethercat_ipcore_top

# Verilator flags
VLINT_FLAGS := --lint-only -Wall -Wno-fatal -I$(RTL_DIR) -I$(LIB_DIR)
VLINT_STRICT := $(VLINT_FLAGS) -Wpedantic

# ============================================================================
# Targets
# ============================================================================

.PHONY: all lint lint-strict lint-quiet clean help

all: lint

# Create reports directory
$(REPORT_DIR):
	@mkdir -p $(REPORT_DIR)

# ----------------------------------------------------------------------------
# Lint Targets
# ----------------------------------------------------------------------------

## Run lint check (standard warnings)
lint: $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Verilator Lint (Standard)"
	@echo "============================================"
	$(VERILATOR) $(VLINT_FLAGS) \
		$(RTL_INCLUDES) $(ALL_SOURCES) \
		--top-module $(TOP_MODULE) 2>&1 | tee $(REPORT_DIR)/lint.log
	@echo ""
	@echo "Lint complete. Report: $(REPORT_DIR)/lint.log"

## Run strict lint (all pedantic warnings)
lint-strict: $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Verilator Lint (Strict/Pedantic)"
	@echo "============================================"
	$(VERILATOR) $(VLINT_STRICT) \
		$(RTL_INCLUDES) $(ALL_SOURCES) \
		--top-module $(TOP_MODULE) 2>&1 | tee $(REPORT_DIR)/lint_strict.log
	@echo ""
	@echo "Strict lint complete. Report: $(REPORT_DIR)/lint_strict.log"

## Run lint and only show errors (suppress warnings)
lint-quiet:
	@echo "Running quiet lint (errors only)..."
	@$(VERILATOR) --lint-only -I$(RTL_DIR) -I$(LIB_DIR) \
		$(RTL_INCLUDES) $(ALL_SOURCES) \
		--top-module $(TOP_MODULE) 2>&1 | grep -E "^%Error" || echo "No errors found."

## Generate lint summary
lint-summary: $(REPORT_DIR)
	@echo "============================================"
	@echo "Lint Summary"
	@echo "============================================"
	@$(VERILATOR) $(VLINT_STRICT) \
		$(RTL_INCLUDES) $(ALL_SOURCES) \
		--top-module $(TOP_MODULE) 2>&1 | tee $(REPORT_DIR)/lint_full.log
	@echo ""
	@echo "=== Warning Count by Type ==="
	@grep -oE "%Warning-[A-Z]+" $(REPORT_DIR)/lint_full.log | sort | uniq -c | sort -rn || echo "No warnings"
	@echo ""
	@echo "=== Error Count ==="
	@grep -c "%Error" $(REPORT_DIR)/lint_full.log || echo "0 errors"

# ----------------------------------------------------------------------------
# Synthesis Targets (Yosys - if available)
# ----------------------------------------------------------------------------

## Check if Yosys is available
check-yosys:
	@which yosys > /dev/null 2>&1 || (echo "Yosys not found. Install with: apt install yosys" && exit 1)

## Run Yosys synthesis (generic FPGA)
synth: check-yosys $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Yosys Synthesis"
	@echo "============================================"
	yosys -p " \
		read_verilog -sv -I$(RTL_DIR) -I$(LIB_DIR) $(RTL_INCLUDES) $(ALL_SOURCES); \
		hierarchy -top $(TOP_MODULE); \
		proc; opt; fsm; opt; memory; opt; \
		techmap; opt; \
		stat" 2>&1 | tee $(REPORT_DIR)/synth.log
	@echo ""
	@echo "Synthesis complete. Report: $(REPORT_DIR)/synth.log"

## Run Yosys synthesis for Xilinx
synth-xilinx: check-yosys $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Yosys Synthesis (Xilinx target)"
	@echo "============================================"
	yosys -p " \
		read_verilog -sv -I$(RTL_DIR) -I$(LIB_DIR) $(RTL_INCLUDES) $(ALL_SOURCES); \
		hierarchy -top $(TOP_MODULE); \
		synth_xilinx -top $(TOP_MODULE); \
		stat" 2>&1 | tee $(REPORT_DIR)/synth_xilinx.log

## Run Yosys synthesis for Intel/Altera
synth-intel: check-yosys $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Yosys Synthesis (Intel target)"
	@echo "============================================"
	yosys -p " \
		read_verilog -sv -I$(RTL_DIR) -I$(LIB_DIR) $(RTL_INCLUDES) $(ALL_SOURCES); \
		hierarchy -top $(TOP_MODULE); \
		synth_intel -top $(TOP_MODULE); \
		stat" 2>&1 | tee $(REPORT_DIR)/synth_intel.log

# ----------------------------------------------------------------------------
# Utility Targets
# ----------------------------------------------------------------------------

## List all RTL files
list:
	@echo "=== Library Files ==="
	@for f in $(LIB_SOURCES); do echo "  $$f"; done
	@echo ""
	@echo "=== RTL Files ==="
	@for f in $(RTL_SOURCES); do echo "  $$f"; done
	@echo ""
	@echo "Top module: $(TOP_MODULE)"

## Clean generated files
clean:
	rm -rf $(REPORT_DIR)
	rm -f *.log

## Show help
help:
	@echo "EtherCAT IP Core - Synthesis & Lint Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Lint Targets:"
	@echo "  lint          - Run Verilator lint (standard warnings)"
	@echo "  lint-strict   - Run Verilator lint (all pedantic warnings)"
	@echo "  lint-quiet    - Run lint, show only errors"
	@echo "  lint-summary  - Generate lint summary with warning counts"
	@echo ""
	@echo "Synthesis Targets (requires Yosys):"
	@echo "  synth         - Generic FPGA synthesis"
	@echo "  synth-xilinx  - Xilinx-targeted synthesis"
	@echo "  synth-intel   - Intel/Altera-targeted synthesis"
	@echo ""
	@echo "Utility:"
	@echo "  list          - List all RTL source files"
	@echo "  clean         - Remove generated files"
	@echo "  help          - Show this help"
