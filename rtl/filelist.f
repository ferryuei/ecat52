// ============================================================================
// EtherCAT IP Core - File List
// Verilog/SystemVerilog RTL synthesis/simulation file list
// Updated: 2026-02-06 - Reorganized directory structure
// ============================================================================

// Include directories
+incdir+../lib
+incdir+../rtl

// ============================================================================
// Library modules (lib/)
// ============================================================================
../lib/ecat_pkg.vh
../lib/ecat_core_defines.vh
../lib/ddr_stages.v
../lib/synchronizer.v
../lib/async_fifo.v
../lib/ecat_dpram.sv

// ============================================================================
// Frame processing (rtl/frame/)
// ============================================================================
../rtl/frame/ecat_frame_receiver.sv
../rtl/frame/ecat_frame_transmitter.sv
../rtl/frame/ecat_port_controller.sv

// ============================================================================
// Data path (rtl/data/)
// ============================================================================
../rtl/data/ecat_fmmu.sv
../rtl/data/ecat_sync_manager.sv
../rtl/data/ecat_register_map.sv

// ============================================================================
// Mailbox protocols (rtl/mailbox/)
// ============================================================================
../rtl/mailbox/ecat_mailbox_handler.sv
../rtl/mailbox/ecat_coe_handler.sv
../rtl/mailbox/ecat_foe_handler.sv
../rtl/mailbox/ecat_eoe_handler.sv
../rtl/mailbox/ecat_soe_handler.sv
../rtl/mailbox/ecat_voe_handler.sv

// ============================================================================
// Control (rtl/control/)
// ============================================================================
../rtl/control/ecat_al_statemachine.sv

// ============================================================================
// Distributed Clock (rtl/dc/)
// ============================================================================
../rtl/dc/ecat_dc.sv

// ============================================================================
// External interfaces (rtl/interface/)
// ============================================================================
../rtl/interface/ecat_sii_controller.sv
../rtl/interface/ecat_mdio_master.sv
../rtl/interface/ecat_pdi_avalon.sv
../rtl/interface/ecat_phy_interface.v

// ============================================================================
// Top-level modules (rtl/)
// ============================================================================
../rtl/ethercat_ipcore_top.v
