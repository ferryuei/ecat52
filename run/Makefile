# ============================================================================
# Makefile for EtherCAT IP Core Simulation & Synthesis
# Supports: Verilator C++ TB, Verilator Verilog TB, iverilog, Yosys
# Run from 'run' directory
# Updated: 2026-02-08
# ============================================================================

# Directories (relative to run/)
RTL_DIR    = ../rtl
LIB_DIR    = ../lib
TB_CPP_DIR = ../tb
TB_V_DIR   = ../tb_verilog
BUILD_DIR  = build
WAVE_DIR   = waves
REPORT_DIR = reports

# Absolute paths for Verilator (needed when cd to build/)
ABS_RTL    = ../../rtl
ABS_LIB    = ../../lib
ABS_TB_V   = ../../tb_verilog
ABS_TB_CPP = ../../tb

# ============================================================================
# Tool Configuration
# ============================================================================

VERILATOR = verilator
VERILATOR_FLAGS = --binary --trace -Wall -Wno-fatal
VERILATOR_FLAGS += -I$(ABS_RTL) -I$(ABS_LIB)
VERILATOR_FLAGS += -I$(ABS_RTL)/frame -I$(ABS_RTL)/data -I$(ABS_RTL)/control
VERILATOR_FLAGS += -I$(ABS_RTL)/dc -I$(ABS_RTL)/interface -I$(ABS_RTL)/mailbox

# Verilator flags for C++ testbench (need --cc not --binary for separate compile)
VERILATOR_CPP_FLAGS = --cc --trace -Wall -Wno-fatal
VERILATOR_CPP_FLAGS += -I$(RTL_DIR) -I$(LIB_DIR)
VERILATOR_CPP_FLAGS += -I$(RTL_DIR)/frame -I$(RTL_DIR)/data -I$(RTL_DIR)/control
VERILATOR_CPP_FLAGS += -I$(RTL_DIR)/dc -I$(RTL_DIR)/interface -I$(RTL_DIR)/mailbox

# iverilog configuration
IVERILOG = iverilog
IVERILOG_FLAGS = -g2012 -Wall
IVERILOG_FLAGS += -I$(RTL_DIR) -I$(LIB_DIR)
VVP = vvp

# Yosys configuration
YOSYS = yosys
TOP_MODULE = ethercat_ipcore_top

# ============================================================================
# RTL Source Files (for synthesis)
# ============================================================================

RTL_INCLUDES = \
	$(LIB_DIR)/ecat_pkg.vh \
	$(LIB_DIR)/ecat_core_defines.vh

LIB_SOURCES = \
	$(LIB_DIR)/ddr_stages.v \
	$(LIB_DIR)/synchronizer.v \
	$(LIB_DIR)/async_fifo.v \
	$(LIB_DIR)/ecat_dpram.sv

RTL_SOURCES = \
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
	$(RTL_DIR)/interface/ecat_pdi_spi.sv \
	$(RTL_DIR)/interface/ecat_pdi_parallel.sv \
	$(RTL_DIR)/interface/ecat_phy_interface.v \
	$(RTL_DIR)/ethercat_ipcore_top.v

ALL_RTL = $(LIB_SOURCES) $(RTL_SOURCES)

# ============================================================================
# Testbench Lists
# ============================================================================

# C++ Testbenches (in tb/, require Verilator model generation + C++ compile)
CPP_TESTS = \
	tb_dpram \
	tb_register_map \
	tb_al_statemachine \
	tb_fmmu \
	tb_sync_manager \
	tb_dc \
	tb_frame_receiver \
	tb_sii_eeprom \
	tb_coe_handler \
	tb_pdi \
	tb_mii \
	tb_port_controller \
	tb_sm \
	tb_mem \
	tb_epu \
	tb_crc_validation \
	tb_fmmu_error

# Verilog Testbenches (in tb_verilog/, Verilator-compatible)
VERILOG_TESTS = \
	tb_dpram \
	tb_register_map \
	tb_al_statemachine \
	tb_fmmu \
	tb_sync_manager \
	tb_dc \
	tb_frame_receiver \
	tb_frame_transmitter \
	tb_sii_eeprom \
	tb_coe_handler \
	tb_pdi \
	tb_mii \
	tb_port_controller \
	tb_sm \
	tb_mailbox_handler \
	tb_soe_handler \
	tb_voe_handler \
	tb_ethercat_top

# iverilog-compatible tests (subset with pure Verilog RTL)
IVERILOG_TESTS = \
	tb_dpram \
	tb_register_map \
	tb_al_statemachine \
	tb_mailbox_handler

# ============================================================================
# Default Target
# ============================================================================

.PHONY: all
all: help

# Create directories
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(WAVE_DIR):
	@mkdir -p $(WAVE_DIR)

$(REPORT_DIR):
	@mkdir -p $(REPORT_DIR)

# ============================================================================
# Verilator C++ Testbench Targets
# ============================================================================

.PHONY: cpp-all cpp-run cpp-clean

# Build all C++ testbenches
cpp-all: $(addprefix cpp-,$(CPP_TESTS))

# Generic pattern for C++ testbench build
# Each test needs its own RTL sources - define module mappings
define CPP_TEST_RULE
cpp-$(1): $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building $(1) (Verilator C++) ==="
	$(VERILATOR) $(VERILATOR_CPP_FLAGS) \
		--top-module $(call get_module,$(1)) \
		--Mdir $(BUILD_DIR)/obj_cpp_$(1) \
		--exe $(TB_CPP_DIR)/$(1).cpp \
		$(call get_rtl,$(1))
	@$(MAKE) -j -C $(BUILD_DIR)/obj_cpp_$(1) -f V$(call get_module,$(1)).mk
	@echo "Build complete: $(BUILD_DIR)/obj_cpp_$(1)/V$(call get_module,$(1))"
endef

# Module name mapping (testbench -> RTL module)
get_module = $(if $(filter tb_dpram,$(1)),ecat_dpram,\
             $(if $(filter tb_register_map,$(1)),ecat_register_map,\
             $(if $(filter tb_al_statemachine,$(1)),ecat_al_statemachine,\
             $(if $(filter tb_fmmu tb_fmmu_error,$(1)),ecat_fmmu,\
             $(if $(filter tb_sync_manager tb_sm,$(1)),ecat_sync_manager,\
             $(if $(filter tb_dc,$(1)),ecat_dc,\
             $(if $(filter tb_frame_receiver,$(1)),ecat_frame_receiver,\
             $(if $(filter tb_sii_eeprom,$(1)),ecat_sii_controller,\
             $(if $(filter tb_coe_handler,$(1)),ecat_coe_handler,\
             $(if $(filter tb_pdi,$(1)),ecat_pdi_avalon,\
             $(if $(filter tb_mii,$(1)),ecat_phy_interface,\
             $(if $(filter tb_port_controller,$(1)),ecat_port_controller,\
             $(if $(filter tb_mem,$(1)),ecat_dpram,\
             $(if $(filter tb_epu,$(1)),ethercat_ipcore_top,\
             $(if $(filter tb_crc_validation,$(1)),ecat_frame_receiver,\
             ecat_dpram)))))))))))))))

# RTL sources mapping (testbench -> required RTL files)
get_rtl = $(if $(filter tb_dpram tb_mem,$(1)),$(LIB_DIR)/ecat_dpram.sv,\
          $(if $(filter tb_register_map,$(1)),$(RTL_DIR)/data/ecat_register_map.sv,\
          $(if $(filter tb_al_statemachine,$(1)),$(RTL_DIR)/control/ecat_al_statemachine.sv,\
          $(if $(filter tb_fmmu tb_fmmu_error,$(1)),$(RTL_DIR)/data/ecat_fmmu.sv,\
          $(if $(filter tb_sync_manager tb_sm,$(1)),$(LIB_DIR)/ecat_dpram.sv $(RTL_DIR)/data/ecat_sync_manager.sv,\
          $(if $(filter tb_dc,$(1)),$(RTL_DIR)/dc/ecat_dc.sv,\
          $(if $(filter tb_frame_receiver tb_crc_validation,$(1)),$(RTL_DIR)/frame/ecat_frame_receiver.sv,\
          $(if $(filter tb_sii_eeprom,$(1)),$(RTL_DIR)/interface/ecat_sii_controller.sv,\
          $(if $(filter tb_coe_handler,$(1)),$(RTL_DIR)/mailbox/ecat_coe_handler.sv,\
          $(if $(filter tb_pdi,$(1)),$(RTL_DIR)/interface/ecat_pdi_avalon.sv,\
          $(if $(filter tb_mii,$(1)),$(RTL_DIR)/interface/ecat_phy_interface.v,\
          $(if $(filter tb_port_controller,$(1)),$(RTL_DIR)/frame/ecat_port_controller.sv,\
          $(if $(filter tb_epu,$(1)),$(ALL_RTL),\
          $(LIB_DIR)/ecat_dpram.sv)))))))))))))

# Generate rules for each C++ test
$(foreach test,$(CPP_TESTS),$(eval $(call CPP_TEST_RULE,$(test))))

# Run all C++ tests
cpp-run: cpp-all
	@echo ""
	@echo "=========================================="
	@echo "Running Verilator C++ Tests"
	@echo "=========================================="
	@for test in $(CPP_TESTS); do \
		module=$$(echo $$test | sed 's/tb_//'); \
		echo ""; \
		echo "--- $$test ---"; \
		if [ -d $(BUILD_DIR)/obj_cpp_$$test ]; then \
			exe=$$(find $(BUILD_DIR)/obj_cpp_$$test -maxdepth 1 -type f -executable -name 'V*' | head -1); \
			if [ -n "$$exe" ]; then \
				$$exe || true; \
			else \
				echo "  [SKIP] Executable not found"; \
			fi; \
		else \
			echo "  [SKIP] Not built"; \
		fi; \
	done
	@mv -f *.vcd $(WAVE_DIR)/ 2>/dev/null || true
	@echo ""
	@echo "=========================================="
	@echo "All C++ tests complete!"
	@echo "=========================================="

# Run individual C++ test
run-cpp-%: cpp-%
	@echo "Running $*..."
	@exe=$$(find $(BUILD_DIR)/obj_cpp_$* -maxdepth 1 -type f -executable -name 'V*' | head -1); \
	if [ -n "$$exe" ]; then $$exe; fi
	@mv -f *.vcd $(WAVE_DIR)/ 2>/dev/null || true

# ============================================================================
# Verilator Verilog Testbench Targets (--binary mode)
# ============================================================================

.PHONY: verilator-all verilator-run verilator-clean

verilator-all: $(addprefix verilator-,$(VERILOG_TESTS))

verilator-tb_dpram: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_dpram (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_dpram -Mdir obj_dpram -o tb_dpram \
		$(ABS_LIB)/ecat_dpram.sv $(ABS_TB_V)/tb_dpram.v

verilator-tb_register_map: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_register_map (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_register_map -Mdir obj_register_map -o tb_register_map \
		$(ABS_RTL)/data/ecat_register_map.sv $(ABS_TB_V)/tb_register_map.v

verilator-tb_al_statemachine: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_al_statemachine (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_al_statemachine -Mdir obj_al_statemachine -o tb_al_statemachine \
		$(ABS_RTL)/control/ecat_al_statemachine.sv $(ABS_TB_V)/tb_al_statemachine.v

verilator-tb_fmmu: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_fmmu (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_fmmu -Mdir obj_fmmu -o tb_fmmu \
		$(ABS_RTL)/data/ecat_fmmu.sv $(ABS_TB_V)/tb_fmmu.v

verilator-tb_sync_manager: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_sync_manager (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_sync_manager -Mdir obj_sync_manager -o tb_sync_manager \
		$(ABS_LIB)/ecat_dpram.sv $(ABS_RTL)/data/ecat_sync_manager.sv $(ABS_TB_V)/tb_sync_manager.v

verilator-tb_dc: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_dc (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_dc -Mdir obj_dc -o tb_dc \
		$(ABS_RTL)/dc/ecat_dc.sv $(ABS_TB_V)/tb_dc.v

verilator-tb_frame_receiver: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_frame_receiver (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_frame_receiver -Mdir obj_frame_receiver -o tb_frame_receiver \
		$(ABS_RTL)/frame/ecat_frame_receiver.sv $(ABS_TB_V)/tb_frame_receiver.v

verilator-tb_sii_eeprom: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_sii_eeprom (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_sii_eeprom -Mdir obj_sii_eeprom -o tb_sii_eeprom \
		$(ABS_RTL)/interface/ecat_sii_controller.sv $(ABS_TB_V)/tb_sii_eeprom.v

verilator-tb_coe_handler: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_coe_handler (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_coe_handler -Mdir obj_coe_handler -o tb_coe_handler \
		$(ABS_RTL)/mailbox/ecat_coe_handler.sv $(ABS_TB_V)/tb_coe_handler.v

verilator-tb_pdi: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_pdi (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_pdi -Mdir obj_pdi -o tb_pdi \
		$(ABS_RTL)/interface/ecat_pdi_avalon.sv $(ABS_TB_V)/tb_pdi.v

verilator-tb_mii: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_mii (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_mii -Mdir obj_mii -o tb_mii \
		$(ABS_RTL)/interface/ecat_phy_interface.v $(ABS_TB_V)/tb_mii.v

verilator-tb_port_controller: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_port_controller (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_port_controller -Mdir obj_port_controller -o tb_port_controller \
		$(ABS_RTL)/frame/ecat_port_controller.sv $(ABS_TB_V)/tb_port_controller.v

verilator-tb_sm: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_sm (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_sm -Mdir obj_sm -o tb_sm \
		$(ABS_LIB)/ecat_dpram.sv $(ABS_RTL)/data/ecat_sync_manager.sv $(ABS_TB_V)/tb_sm.v

verilator-tb_frame_transmitter: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_frame_transmitter (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_frame_transmitter -Mdir obj_frame_transmitter -o tb_frame_transmitter \
		$(ABS_RTL)/frame/ecat_frame_transmitter.sv $(ABS_TB_V)/tb_frame_transmitter.v

verilator-tb_mailbox_handler: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_mailbox_handler (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_mailbox_handler -Mdir obj_mailbox_handler -o tb_mailbox_handler \
		$(ABS_RTL)/mailbox/ecat_mailbox_handler.sv $(ABS_TB_V)/tb_mailbox_handler.v

verilator-tb_soe_handler: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_soe_handler (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_soe_handler -Mdir obj_soe_handler -o tb_soe_handler \
		$(ABS_RTL)/mailbox/ecat_soe_handler.sv $(ABS_TB_V)/tb_soe_handler.v

verilator-tb_voe_handler: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_voe_handler (Verilator) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_voe_handler -Mdir obj_voe_handler -o tb_voe_handler \
		$(ABS_RTL)/mailbox/ecat_voe_handler.sv $(ABS_TB_V)/tb_voe_handler.v

# Integration testbench (full system)
verilator-tb_ethercat_top: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_ethercat_top (Verilator - Integration) ==="
	cd $(BUILD_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module tb_ethercat_top -Mdir obj_ethercat_top -o tb_ethercat_top \
		$(ABS_LIB)/ddr_stages.v \
		$(ABS_LIB)/synchronizer.v \
		$(ABS_LIB)/async_fifo.v \
		$(ABS_LIB)/ecat_dpram.sv \
		$(ABS_RTL)/frame/ecat_frame_receiver.sv \
		$(ABS_RTL)/frame/ecat_frame_transmitter.sv \
		$(ABS_RTL)/frame/ecat_port_controller.sv \
		$(ABS_RTL)/data/ecat_fmmu.sv \
		$(ABS_RTL)/data/ecat_sync_manager.sv \
		$(ABS_RTL)/data/ecat_register_map.sv \
		$(ABS_RTL)/mailbox/ecat_mailbox_handler.sv \
		$(ABS_RTL)/mailbox/ecat_coe_handler.sv \
		$(ABS_RTL)/mailbox/ecat_foe_handler.sv \
		$(ABS_RTL)/mailbox/ecat_eoe_handler.sv \
		$(ABS_RTL)/mailbox/ecat_soe_handler.sv \
		$(ABS_RTL)/mailbox/ecat_voe_handler.sv \
		$(ABS_RTL)/control/ecat_al_statemachine.sv \
		$(ABS_RTL)/dc/ecat_dc.sv \
		$(ABS_RTL)/interface/ecat_sii_controller.sv \
		$(ABS_RTL)/interface/ecat_mdio_master.sv \
		$(ABS_RTL)/interface/ecat_pdi_avalon.sv \
		$(ABS_RTL)/interface/ecat_pdi_spi.sv \
		$(ABS_RTL)/interface/ecat_pdi_parallel.sv \
		$(ABS_RTL)/interface/ecat_phy_interface.v \
		$(ABS_RTL)/ethercat_ipcore_top.v \
		$(ABS_TB_V)/tb_ethercat_top.v

# Run all Verilator Verilog tests
verilator-run: verilator-all
	@echo ""
	@echo "=========================================="
	@echo "Running Verilator Verilog Tests"
	@echo "=========================================="
	@for test in $(VERILOG_TESTS); do \
		echo ""; \
		echo "--- $$test ---"; \
		if [ -f $(BUILD_DIR)/obj_$${test#tb_}/$$test ]; then \
			cd $(BUILD_DIR) && ./obj_$${test#tb_}/$$test && cd ..; \
		else \
			echo "  [SKIP] Not built"; \
		fi; \
	done
	@mv -f *.vcd $(WAVE_DIR)/ 2>/dev/null || true
	@echo ""
	@echo "=========================================="
	@echo "All Verilator Verilog tests complete!"
	@echo "=========================================="

# Run individual Verilator test
run-%: verilator-%
	@echo "Running $*..."
	@cd $(BUILD_DIR) && ./obj_$${1#tb_}/$* 2>/dev/null || ./obj_$*/$* 2>/dev/null || echo "Not found"
	@mv -f *.vcd $(WAVE_DIR)/ 2>/dev/null || true

# ============================================================================
# iverilog Testbench Targets
# ============================================================================

.PHONY: iverilog-all iverilog-run iverilog-clean

iverilog-all: $(addprefix iverilog-,$(IVERILOG_TESTS))

iverilog-tb_dpram: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_dpram (iverilog) ==="
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(BUILD_DIR)/tb_dpram.iv \
		$(LIB_DIR)/ecat_dpram.sv $(TB_V_DIR)/tb_dpram.v

iverilog-tb_register_map: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_register_map (iverilog) ==="
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(BUILD_DIR)/tb_register_map.iv \
		$(RTL_DIR)/data/ecat_register_map.sv $(TB_V_DIR)/tb_register_map.v

iverilog-tb_al_statemachine: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_al_statemachine (iverilog) ==="
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(BUILD_DIR)/tb_al_statemachine.iv \
		$(RTL_DIR)/control/ecat_al_statemachine.sv $(TB_V_DIR)/tb_al_statemachine.v

iverilog-tb_mailbox_handler: $(BUILD_DIR) $(WAVE_DIR)
	@echo "=== Building tb_mailbox_handler (iverilog) ==="
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(BUILD_DIR)/tb_mailbox_handler.iv \
		$(RTL_DIR)/mailbox/ecat_mailbox_handler.sv $(TB_V_DIR)/tb_mailbox_handler.v

iverilog-run: iverilog-all
	@echo ""
	@echo "=========================================="
	@echo "Running iverilog Tests"
	@echo "=========================================="
	@for test in $(IVERILOG_TESTS); do \
		echo ""; \
		echo "--- $$test ---"; \
		cd $(BUILD_DIR) && $(VVP) $$test.iv && cd ..; \
	done
	@mv -f $(BUILD_DIR)/*.vcd $(WAVE_DIR)/ 2>/dev/null || true
	@echo ""
	@echo "=========================================="
	@echo "All iverilog tests complete!"
	@echo "=========================================="

# ============================================================================
# VCS Configuration
# ============================================================================

VCS = vcs
export VCS_ARCH_OVERRIDE = linux
export VCS_TARGET_ARCH = amd64
VCS_COMMON = +v2k -sverilog -debug_access+all +vcs+loopreport
VCS_COMMON += +incdir+$(VCS_ABS_RTL) +incdir+$(VCS_ABS_LIB)
VCS_COMMON += +incdir+$(VCS_ABS_RTL)/frame +incdir+$(VCS_ABS_RTL)/data +incdir+$(VCS_ABS_RTL)/control
VCS_COMMON += +incdir+$(VCS_ABS_RTL)/dc +incdir+$(VCS_ABS_RTL)/interface +incdir+$(VCS_ABS_RTL)/mailbox
VCS_COMMON += -timescale=1ns/1ps -notice -line +warn=noLCA_FEATURES
VCS_COV = +cover=bcesfx

VCS_BUILD = $(BUILD_DIR)/vcs

# Absolute paths for VCS (cd into build/vcs/tb_xxx breaks relative paths)
VCS_ABS_RTL  = $(shell cd $(RTL_DIR) && pwd)
VCS_ABS_LIB  = $(shell cd $(LIB_DIR) && pwd)
VCS_ABS_TB_V = $(shell cd $(TB_V_DIR) && pwd)

# VCS test list
VCS_TESTS = \
	tb_dpram tb_register_map tb_al_statemachine tb_fmmu \
	tb_sync_manager tb_dc tb_frame_receiver tb_frame_transmitter \
	tb_sii_eeprom tb_coe_handler tb_coe_enhanced \
	tb_foe_handler tb_eoe_handler tb_soe_handler tb_voe_handler \
	tb_mailbox_handler tb_pdi tb_mii tb_port_controller tb_sm \
	tb_ethercat_top

# ============================================================================
# VCS Testbench Targets
# ============================================================================

.PHONY: check-vcs vcs-all vcs-run vcs-run-nocov vcs-run-tests vcs-clean

check-vcs:
	@which $(VCS) > /dev/null 2>&1 || (echo "Error: vcs not found in PATH" && exit 1)

vcs-all: check-vcs $(addprefix vcs-,$(VCS_TESTS))

# --- VCS RTL file mapping per test ---
VCS_RTL_tb_dpram = $(VCS_ABS_LIB)/ecat_dpram.sv
VCS_RTL_tb_register_map = $(VCS_ABS_RTL)/data/ecat_register_map.sv
VCS_RTL_tb_al_statemachine = $(VCS_ABS_RTL)/control/ecat_al_statemachine.sv
VCS_RTL_tb_fmmu = $(VCS_ABS_RTL)/data/ecat_fmmu.sv
VCS_RTL_tb_sync_manager = $(VCS_ABS_LIB)/ecat_dpram.sv $(VCS_ABS_RTL)/data/ecat_sync_manager.sv
VCS_RTL_tb_dc = $(VCS_ABS_RTL)/dc/ecat_dc.sv
VCS_RTL_tb_frame_receiver = $(VCS_ABS_RTL)/frame/ecat_frame_receiver.sv
VCS_RTL_tb_frame_transmitter = $(VCS_ABS_RTL)/frame/ecat_frame_transmitter.sv
VCS_RTL_tb_sii_eeprom = $(VCS_ABS_RTL)/interface/ecat_sii_controller.sv
VCS_RTL_tb_coe_handler = $(VCS_ABS_RTL)/mailbox/ecat_coe_handler.sv
VCS_RTL_tb_coe_enhanced = $(VCS_ABS_RTL)/mailbox/ecat_coe_handler.sv
VCS_RTL_tb_foe_handler = $(VCS_ABS_RTL)/mailbox/ecat_foe_handler.sv
VCS_RTL_tb_eoe_handler = $(VCS_ABS_RTL)/mailbox/ecat_eoe_handler.sv
VCS_RTL_tb_soe_handler = $(VCS_ABS_RTL)/mailbox/ecat_soe_handler.sv
VCS_RTL_tb_voe_handler = $(VCS_ABS_RTL)/mailbox/ecat_voe_handler.sv
VCS_RTL_tb_mailbox_handler = $(VCS_ABS_RTL)/mailbox/ecat_mailbox_handler.sv
VCS_RTL_tb_pdi = $(VCS_ABS_RTL)/interface/ecat_pdi_avalon.sv
VCS_RTL_tb_mii = $(VCS_ABS_RTL)/interface/ecat_phy_interface.v
VCS_RTL_tb_port_controller = $(VCS_ABS_RTL)/frame/ecat_port_controller.sv
VCS_RTL_tb_sm = $(VCS_ABS_LIB)/ecat_dpram.sv $(VCS_ABS_RTL)/data/ecat_sync_manager.sv
VCS_RTL_tb_ethercat_top = \
	$(VCS_ABS_LIB)/ddr_stages.v $(VCS_ABS_LIB)/synchronizer.v $(VCS_ABS_LIB)/async_fifo.v \
	$(VCS_ABS_LIB)/ecat_dpram.sv \
	$(VCS_ABS_RTL)/frame/ecat_frame_receiver.sv \
	$(VCS_ABS_RTL)/frame/ecat_frame_transmitter.sv \
	$(VCS_ABS_RTL)/frame/ecat_port_controller.sv \
	$(VCS_ABS_RTL)/data/ecat_fmmu.sv \
	$(VCS_ABS_RTL)/data/ecat_sync_manager.sv \
	$(VCS_ABS_RTL)/data/ecat_register_map.sv \
	$(VCS_ABS_RTL)/mailbox/ecat_mailbox_handler.sv \
	$(VCS_ABS_RTL)/mailbox/ecat_coe_handler.sv \
	$(VCS_ABS_RTL)/mailbox/ecat_foe_handler.sv \
	$(VCS_ABS_RTL)/mailbox/ecat_eoe_handler.sv \
	$(VCS_ABS_RTL)/mailbox/ecat_soe_handler.sv \
	$(VCS_ABS_RTL)/mailbox/ecat_voe_handler.sv \
	$(VCS_ABS_RTL)/control/ecat_al_statemachine.sv \
	$(VCS_ABS_RTL)/dc/ecat_dc.sv \
	$(VCS_ABS_RTL)/interface/ecat_sii_controller.sv \
	$(VCS_ABS_RTL)/interface/ecat_mdio_master.sv \
	$(VCS_ABS_RTL)/interface/ecat_pdi_avalon.sv \
	$(VCS_ABS_RTL)/interface/ecat_pdi_spi.sv \
	$(VCS_ABS_RTL)/interface/ecat_pdi_parallel.sv \
	$(VCS_ABS_RTL)/interface/ecat_phy_interface.v \
	$(VCS_ABS_RTL)/ethercat_ipcore_top.v

# Generic VCS compile rule using eval/call
define VCS_TEST_RULE
vcs-$(1): check-vcs
	@mkdir -p $(VCS_BUILD)/$(1) $(WAVE_DIR)
	@echo "=== Compiling $(1) (VCS) ==="
	cd $(VCS_BUILD)/$(1) && $(VCS) $(VCS_COMMON) $(VCS_COV) \
		-cm_dir $(VCS_BUILD)/vcs_cov/$(1).vdb \
		-top $(1) \
		$(VCS_ABS_LIB)/ecat_pkg.vh $(VCS_ABS_LIB)/ecat_core_defines.vh \
		$(VCS_RTL_$(1)) \
		$(VCS_ABS_TB_V)/$(1).v \
		-o simv -Mdir=csrc -l compile.log
	@echo "Build complete: $(VCS_BUILD)/$(1)/simv"
endef

$(foreach test,$(VCS_TESTS),$(eval $(call VCS_TEST_RULE,$(test))))

# --- VCS run targets ---

# Run all VCS tests with coverage (via regression script)
vcs-run: check-vcs
	@echo "=========================================="
	@echo "Running VCS Regression (with coverage)"
	@echo "=========================================="
	@./vcs_regression.sh

vcs-run-nocov: check-vcs
	@echo "=========================================="
	@echo "Running VCS Regression (no coverage)"
	@echo "=========================================="
	@./vcs_regression.sh --no-cov

vcs-run-tests: check-vcs
	@if [ -z "$(TESTS)" ]; then \
		echo "Usage: make vcs-run-tests TESTS=tb_dpram,tb_pdi"; \
		exit 1; \
	fi
	@echo "Running selected VCS tests: $(TESTS)"
	@./vcs_regression.sh --tests $(TESTS)

# Run individual VCS test (compile + run)
run-vcs-%: vcs-%
	@echo "Running VCS test: $*..."
	@cd $(VCS_BUILD)/$* && ./simv +vcs+lic+wait -l sim.log \
		+cover=bcesfx -cm_dir $(VCS_BUILD)/vcs_cov/$*.vdb -cm line+cond+fsm+tgl+branch+assert
	@mv -f *.vcd *.vpd $(WAVE_DIR)/ 2>/dev/null || true
	@echo "$*: done"

vcs-clean:
	@echo "Cleaning VCS build files..."
	@rm -rf $(VCS_BUILD)

# ============================================================================
# Yosys Synthesis Targets
# ============================================================================

.PHONY: synth synth-xilinx synth-intel synth-cmos check-yosys

check-yosys:
	@which $(YOSYS) > /dev/null 2>&1 || (echo "Error: Yosys not found. Install with: apt install yosys" && exit 1)

synth: check-yosys $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Yosys Synthesis (Generic FPGA)"
	@echo "============================================"
	$(YOSYS) -p " \
		read_verilog -sv -I$(RTL_DIR) -I$(LIB_DIR) $(RTL_INCLUDES) $(ALL_RTL); \
		hierarchy -top $(TOP_MODULE); \
		proc; opt; fsm; opt; memory; opt; \
		techmap; opt; \
		stat" 2>&1 | tee $(REPORT_DIR)/synth.log
	@echo ""
	@echo "Synthesis complete. Report: $(REPORT_DIR)/synth.log"

synth-xilinx: check-yosys $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Yosys Synthesis (Xilinx target)"
	@echo "============================================"
	$(YOSYS) -p " \
		read_verilog -sv -I$(RTL_DIR) -I$(LIB_DIR) $(RTL_INCLUDES) $(ALL_RTL); \
		hierarchy -top $(TOP_MODULE); \
		synth_xilinx -top $(TOP_MODULE); \
		stat" 2>&1 | tee $(REPORT_DIR)/synth_xilinx.log
	@echo ""
	@echo "Synthesis complete. Report: $(REPORT_DIR)/synth_xilinx.log"

synth-intel: check-yosys $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Yosys Synthesis (Intel/Altera target)"
	@echo "============================================"
	$(YOSYS) -p " \
		read_verilog -sv -I$(RTL_DIR) -I$(LIB_DIR) $(RTL_INCLUDES) $(ALL_RTL); \
		hierarchy -top $(TOP_MODULE); \
		synth_intel -top $(TOP_MODULE); \
		stat" 2>&1 | tee $(REPORT_DIR)/synth_intel.log
	@echo ""
	@echo "Synthesis complete. Report: $(REPORT_DIR)/synth_intel.log"

synth-cmos: check-yosys $(REPORT_DIR)
	@echo "============================================"
	@echo "Running Yosys Synthesis (CMOS/ASIC target)"
	@echo "============================================"
	$(YOSYS) -p " \
		read_verilog -sv -I$(RTL_DIR) -I$(LIB_DIR) $(RTL_INCLUDES) $(ALL_RTL); \
		hierarchy -top $(TOP_MODULE); \
		proc; opt; fsm; opt; memory; opt; \
		flatten; opt; \
		techmap; opt; \
		abc -liberty cmos4.lib 2>/dev/null || abc; \
		stat; \
		write_verilog $(REPORT_DIR)/netlist_gates.v" 2>&1 | tee $(REPORT_DIR)/synth_cmos.log
	@echo ""
	@echo "Synthesis complete. Netlist: $(REPORT_DIR)/netlist_gates.v"

# ============================================================================
# Lint Targets
# ============================================================================

.PHONY: lint lint-all lint-strict lint-quiet

lint:
	@echo "Running Verilator lint on key RTL files..."
	@$(VERILATOR) --lint-only -Wall -Wno-fatal -I$(RTL_DIR) -I$(LIB_DIR) \
		$(RTL_DIR)/frame/ecat_frame_receiver.sv 2>&1 | head -20
	@$(VERILATOR) --lint-only -Wall -Wno-fatal -I$(RTL_DIR) -I$(LIB_DIR) \
		$(RTL_DIR)/control/ecat_al_statemachine.sv 2>&1 | head -20
	@$(VERILATOR) --lint-only -Wall -Wno-fatal -I$(RTL_DIR) -I$(LIB_DIR) \
		$(RTL_DIR)/data/ecat_register_map.sv 2>&1 | head -20
	@echo "Lint complete (showing first 20 warnings per file)"

lint-all:
	@echo "Running Verilator lint on all RTL files..."
	@for file in $(RTL_DIR)/*/*.sv $(LIB_DIR)/*.sv; do \
		echo "Checking $$file..."; \
		$(VERILATOR) --lint-only -Wall -Wno-fatal -I$(RTL_DIR) -I$(LIB_DIR) $$file 2>&1 || true; \
	done

lint-strict: $(REPORT_DIR)
	@echo "Running strict lint (pedantic)..."
	$(VERILATOR) --lint-only -Wall -Wpedantic -Wno-fatal \
		-I$(RTL_DIR) -I$(LIB_DIR) \
		$(RTL_INCLUDES) $(ALL_RTL) \
		--top-module $(TOP_MODULE) 2>&1 | tee $(REPORT_DIR)/lint_strict.log

lint-quiet:
	@echo "Running quiet lint (errors only)..."
	@$(VERILATOR) --lint-only -I$(RTL_DIR) -I$(LIB_DIR) \
		$(RTL_INCLUDES) $(ALL_RTL) \
		--top-module $(TOP_MODULE) 2>&1 | grep -E "^%Error" || echo "No errors found."

# ============================================================================
# Clean Targets
# ============================================================================

.PHONY: clean distclean

clean:
	@echo "Cleaning build directory..."
	@rm -rf $(BUILD_DIR)
	@echo "Clean complete!"

distclean: clean
	@echo "Cleaning waves and reports..."
	@rm -rf $(WAVE_DIR) $(REPORT_DIR)
	@echo "Distclean complete!"

# ============================================================================
# Help
# ============================================================================

.PHONY: help list

help:
	@echo "============================================================================"
	@echo "EtherCAT IP Core - Simulation & Synthesis Makefile"
	@echo "============================================================================"
	@echo ""
	@echo "Directory Structure:"
	@echo "  rtl/           - RTL source files (SystemVerilog)"
	@echo "  lib/           - Common libraries and defines"
	@echo "  tb/            - C++ Verilator testbenches"
	@echo "  tb_verilog/    - Pure Verilog testbenches"
	@echo "  run/build/     - Build artifacts"
	@echo "  run/waves/     - VCD waveform files"
	@echo "  run/reports/   - Synthesis and lint reports"
	@echo ""
	@echo "Verilator C++ Testbench Targets:"
	@echo "  make cpp-all             - Build all C++ testbenches"
	@echo "  make cpp-run             - Build and run all C++ tests"
	@echo "  make cpp-<name>          - Build specific C++ test"
	@echo "  make run-cpp-<name>      - Run specific C++ test"
	@echo ""
	@echo "Verilator Verilog Testbench Targets:"
	@echo "  make verilator-all       - Build all Verilog testbenches"
	@echo "  make verilator-run       - Build and run all Verilog tests"
	@echo "  make run-<name>          - Run specific Verilog test"
	@echo ""
	@echo "iverilog Targets:"
	@echo "  make iverilog-all        - Build iverilog-compatible tests"
	@echo "  make iverilog-run        - Build and run iverilog tests"
	@echo ""
	@echo "VCS Targets:"
	@echo "  make vcs-all             - Compile all VCS tests"
	@echo "  make vcs-run             - Run full VCS regression with coverage"
	@echo "  make vcs-run-nocov       - Run full VCS regression without coverage"
	@echo "  make vcs-run-tests TESTS=tb_a,tb_b - Run selected VCS tests"
	@echo "  make vcs-<test>          - Compile specific VCS test"
	@echo "  make run-vcs-<test>      - Compile and run specific VCS test"
	@echo "  make vcs-clean           - Clean VCS build files"
	@echo ""
	@echo "Yosys Synthesis Targets:"
	@echo "  make synth               - Generic FPGA synthesis"
	@echo "  make synth-xilinx        - Xilinx-targeted synthesis"
	@echo "  make synth-intel         - Intel/Altera-targeted synthesis"
	@echo "  make synth-cmos          - CMOS/ASIC synthesis with ABC"
	@echo ""
	@echo "Lint Targets:"
	@echo "  make lint                - Quick lint check (key files)"
	@echo "  make lint-all            - Lint all RTL files"
	@echo "  make lint-strict         - Pedantic lint check"
	@echo "  make lint-quiet          - Show errors only"
	@echo ""
	@echo "Utility:"
	@echo "  make clean               - Remove build artifacts"
	@echo "  make distclean           - Remove all generated files"
	@echo "  make list                - List all testbenches"
	@echo "  make help                - Show this help"
	@echo ""
	@echo "Examples:"
	@echo "  make cpp-run             # Build and run all C++ tests"
	@echo "  make verilator-run       # Build and run all Verilog tests"
	@echo "  make run-tb_fmmu         # Run FMMU Verilog test"
	@echo "  make run-cpp-tb_dpram    # Run DPRAM C++ test"
	@echo "  make synth               # Run Yosys synthesis"

list:
	@echo "============================================================================"
	@echo "Available Testbenches"
	@echo "============================================================================"
	@echo ""
	@echo "C++ Testbenches (17 tests, in tb/):"
	@for t in $(CPP_TESTS); do echo "  $$t"; done
	@echo ""
	@echo "Verilog Testbenches (14 tests, in tb_verilog/):"
	@for t in $(VERILOG_TESTS); do echo "  $$t"; done
	@echo ""
	@echo "Integration Test (full system):"
	@echo "  tb_ethercat_top  - Full IP core with PHY, PDI, DC, EEPROM"
	@echo ""
	@echo "iverilog-compatible (4 tests):"
	@for t in $(IVERILOG_TESTS); do echo "  $$t"; done
