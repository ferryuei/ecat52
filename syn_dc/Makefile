# ============================================================================
# EtherCAT IP Core - Design Compiler Synthesis Makefile
# Target: TSMC 28nm HPC+ BWP40P140 HVT
# ============================================================================

TOP_MODULE = ethercat_ipcore_top
DC_SHELL   = dc_shell

# Directories
RTL_DIR    = ../rtl
LIB_DIR    = ../lib
WORK_DIR   = work
RPT_DIR    = reports
OUT_DIR    = output
TMP_DIR    = tmpfiles

# TSMC library paths
TSMCHOME   = /home/fang/Downloads/tcbn28hpcplusbwp40p140hvt_180a/AN61001_20180829/TSMCHOME/digital
LIB_DB     = $(TSMCHOME)/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp40p140hvt_180a/tcbn28hpcplusbwp40p140hvttt1v25c.db
LIB_LIB    = $(TSMCHOME)/Front_End/timing_power_noise/ECSM/tcbn28hpcplusbwp40p140hvt_180a/tcbn28hpcplusbwp40p140hvttt1v25c_ecsm.lib

# ============================================================================
# Targets
# ============================================================================

.PHONY: all synth clean reports check-lib help

all: synth

$(WORK_DIR):
	@mkdir -p $(WORK_DIR)

$(RPT_DIR):
	@mkdir -p $(RPT_DIR)

$(OUT_DIR):
	@mkdir -p $(OUT_DIR)

$(TMP_DIR):
	@mkdir -p $(TMP_DIR)

# Check library availability
.PHONY: check-lib
check-lib:
	@echo "Checking TSMC library..."
	@test -f $(LIB_DB) || (echo "ERROR: Library DB not found: $(LIB_DB)" && exit 1)
	@test -f $(LIB_LIB) || (echo "ERROR: Library LIB not found: $(LIB_LIB)" && exit 1)
	@which $(DC_SHELL) > /dev/null 2>&1 || (echo "ERROR: dc_shell not found in PATH" && exit 1)
	@echo "Library check passed."
	@echo "  DB:  $(LIB_DB)"
	@echo "  LIB: $(LIB_LIB)"

# Run synthesis
synth: check-lib $(WORK_DIR) $(RPT_DIR) $(OUT_DIR) $(TMP_DIR)
	@echo "============================================"
	@echo "Running Design Compiler Synthesis"
	@echo "Top: $(TOP_MODULE)"
	@echo "Library: TSMC 28nm HPC+ HVT (tt 1V 25C)"
	@echo "============================================"
	$(DC_SHELL) -f run_synth.tcl 2>&1 | tee syn_log.txt
	@echo ""
	@echo "Synthesis complete. Check reports/ and output/"

# View reports
reports:
	@echo "============================================"
	@echo "Synthesis Summary"
	@echo "============================================"
	@if [ -f $(RPT_DIR)/summary.rpt ]; then \
		cat $(RPT_DIR)/summary.rpt; \
	else \
		echo "No summary report found. Run 'make synth' first."; \
	fi

# View timing
timing:
	@echo "=== Setup Timing (WNS) ==="
	@if [ -f $(RPT_DIR)/timing_max.rpt ]; then \
		head -50 $(RPT_DIR)/timing_max.rpt; \
	else \
		echo "No timing report found."; \
	fi

# View area
area:
	@if [ -f $(RPT_DIR)/area.rpt ]; then \
		cat $(RPT_DIR)/area.rpt; \
	else \
		echo "No area report found."; \
	fi

# View power
power:
	@if [ -f $(RPT_DIR)/power.rpt ]; then \
		cat $(RPT_DIR)/power.rpt; \
	else \
		echo "No power report found."; \
	fi

# Check for timing violations
check-timing:
	@if [ -f $(RPT_DIR)/timing_max.rpt ]; then \
		echo "=== Timing Violations ==="; \
		grep -A5 "slack.*MET\|slack.*VIOLATED\|Timing is not\|Timing met" $(RPT_DIR)/timing_max.rpt || echo "See $(RPT_DIR)/timing_max.rpt"; \
	else \
		echo "No timing report found."; \
	fi

# Clean
clean:
	@echo "Cleaning synthesis files..."
	@rm -rf $(WORK_DIR) $(OUT_DIR) $(TMP_DIR) lib_work \
		*.mr *.pvl *.syn *.log *.svf \
		alib-52 command.log filenames.log svf.txt syn_log.txt
	@echo "Clean complete."

distclean: clean
	@rm -rf $(RPT_DIR)
	@echo "Distclean complete."

help:
	@echo "============================================"
	@echo "EtherCAT DC Synthesis Makefile"
	@echo "============================================"
	@echo ""
	@echo "Targets:"
	@echo "  make synth        - Run full DC synthesis"
	@echo "  make check-lib    - Verify library setup"
	@echo "  make reports      - Show synthesis summary"
	@echo "  make timing       - Show timing report"
	@echo "  make area         - Show area report"
	@echo "  make power        - Show power report"
	@echo "  make check-timing - Check for violations"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make distclean    - Remove all generated files"
	@echo ""
	@echo "Library: TSMC 28nm HPC+ BWP40P140 HVT"
	@echo "Corner:  tt 1V 25C (ECSM)"
	@echo "Target:  $(TOP_MODULE)"
