# Verilog Testbenches

Pure Verilog-2001 testbenches for EtherCAT IP Core modules.

## Building and Running

All testbenches are built and run from the `run/` directory:

```bash
cd ../run
make help              # Show available targets
make verilator-run     # Build and run all Verilator tests
make run-tb_dpram      # Run specific test
```

## Testbench Summary

| Testbench | Module | Tests | Status |
|-----------|--------|-------|--------|
| tb_dpram.v | ecat_dpram | 13 | PASSED |
| tb_register_map.v | ecat_register_map | 7 | PASSED |
| tb_al_statemachine.v | ecat_al_statemachine | 8 | PASSED |
| tb_fmmu.v | ecat_fmmu | 10 | PASSED |
| tb_sync_manager.v | ecat_sync_manager | 11 | PASSED |
| tb_dc.v | ecat_dc | 12 | PASSED |
| tb_frame_receiver.v | ecat_frame_receiver | 4 | 3 PASS |
| tb_sii_eeprom.v | ecat_sii_controller | 5 | PASSED |
| tb_coe_handler.v | ecat_coe_handler | 6 | PASSED |
| tb_pdi.v | ecat_pdi_avalon | 8 | PASSED |

## Not Yet Compatible

| Testbench | Issue |
|-----------|-------|
| tb_port_controller.v | RTL interface mismatch |
| tb_mii.v | RTL interface mismatch |
| tb_sm.v | No ecat_sm RTL module |
