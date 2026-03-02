#!/bin/bash
# EtherCAT Functional Defect Checker
# Based on ETG.1000 specification requirements

echo "==========================================="
echo "EtherCAT IP Core - Functional Defect Check"
echo "==========================================="

RTL_DIR="../rtl"
REPORT_FILE="functional_defects_report.txt"

> $REPORT_FILE

echo "1. Checking for unconnected signals..."
echo "" >> $REPORT_FILE
echo "=== UNCONNECTED SIGNALS ===" >> $REPORT_FILE

# Check for hardcoded zeros that should be connected
grep -n "= 1'b0.*TODO\|= 32'h0.*TODO\|= 16'h0.*TODO" $RTL_DIR/*.v $RTL_DIR/*.sv 2>/dev/null >> $REPORT_FILE

echo "2. Checking ETG.1000 register coverage..."
echo "" >> $REPORT_FILE
echo "=== ETG.1000 REGISTER COVERAGE ===" >> $REPORT_FILE

# Required ESC registers per ETG.1000
REQUIRED_REGS=(
    "0x0000:Type"
    "0x0001:Revision"
    "0x0010:Station_Address"
    "0x0110:DL_Status"
    "0x0120:AL_Control"
    "0x0130:AL_Status"
    "0x0200:IRQ"
    "0x0300:WD"
    "0x0400:FMMU"
    "0x0500:SII"
    "0x0800:SM"
    "0x0900:DC"
    "0x0E00:EEPROM"
    "0x0F00:FMMU_Error"
)

for reg in "${REQUIRED_REGS[@]}"; do
    addr=$(echo $reg | cut -d: -f1)
    name=$(echo $reg | cut -d: -f2)
    if grep -q "$addr" $RTL_DIR/ecat_register_map.sv 2>/dev/null; then
        echo "[OK] $name ($addr) - Implemented" >> $REPORT_FILE
    else
        echo "[MISSING] $name ($addr) - NOT IMPLEMENTED" >> $REPORT_FILE
    fi
done

echo "3. Checking state machine completeness..."
echo "" >> $REPORT_FILE
echo "=== AL STATE MACHINE STATES ===" >> $REPORT_FILE

# ETG.1000 requires these AL states
for state in "INIT" "PREOP" "SAFEOP" "OP" "BOOTSTRAP"; do
    if grep -q "$state" $RTL_DIR/ecat_al_statemachine.sv 2>/dev/null; then
        echo "[OK] AL State: $state" >> $REPORT_FILE
    else
        echo "[MISSING] AL State: $state" >> $REPORT_FILE
    fi
done

echo "4. Checking CRC32 implementation..."
echo "" >> $REPORT_FILE
echo "=== CRC32 VALIDATION ===" >> $REPORT_FILE

if grep -q "0x04C11DB7\|0xEDB88320\|crc32" $RTL_DIR/ecat_frame_receiver.sv 2>/dev/null; then
    echo "[OK] CRC32 polynomial found" >> $REPORT_FILE
else
    echo "[MISSING] CRC32 polynomial not found" >> $REPORT_FILE
fi

if grep -q "0xC704DD7B\|0x2144DF1C" $RTL_DIR/ecat_frame_receiver.sv 2>/dev/null; then
    echo "[OK] CRC32 magic residue found" >> $REPORT_FILE
else
    echo "[MISSING] CRC32 magic residue not found" >> $REPORT_FILE
fi

echo "5. Checking mailbox protocol types..."
echo "" >> $REPORT_FILE
echo "=== MAILBOX PROTOCOL SUPPORT ===" >> $REPORT_FILE

for proto in "AoE" "EoE" "CoE" "FoE" "SoE"; do
    if grep -q "$proto\|0x0[2-6]" $RTL_DIR/ecat_mailbox_handler.sv 2>/dev/null; then
        echo "[OK] Mailbox: $proto referenced" >> $REPORT_FILE
    else
        echo "[PARTIAL] Mailbox: $proto not referenced" >> $REPORT_FILE
    fi
done

echo "6. Checking for combinatorial loops..."
echo "" >> $REPORT_FILE
echo "=== COMBINATORIAL LOOP RISK ===" >> $REPORT_FILE

# Check for always_comb blocks that might have loops
grep -B5 -A10 "always_comb" $RTL_DIR/*.sv 2>/dev/null | grep -E "if.*else|case" | head -20 >> $REPORT_FILE

echo "7. Checking formal assertions..."
echo "" >> $REPORT_FILE
echo "=== FORMAL ASSERTIONS ===" >> $REPORT_FILE

ASSERT_COUNT=$(grep -c "assert\|assume\|cover" $RTL_DIR/*.sv 2>/dev/null | awk -F: '{sum+=$2} END{print sum}')
echo "Total assertions in RTL: ${ASSERT_COUNT:-0}" >> $REPORT_FILE

if [ "${ASSERT_COUNT:-0}" -eq 0 ]; then
    echo "[WARNING] No formal assertions - recommend adding SVA properties" >> $REPORT_FILE
fi

echo ""
echo "Report generated: $REPORT_FILE"
cat $REPORT_FILE
