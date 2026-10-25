#!/bin/sh
# M4: generate ~100% CPU on a 1-vCPU VM for a fixed time, in the background, then stop by itself.
# Run on the VM via Azure Run Command:
#   az vm run-command invoke -g rg-hubspoke-vms -n vm-spoke-lab2 --command-id RunShellScript --scripts "@scripts/cpu-load.sh"
DURATION=720   # seconds (12 minutes): long enough for a 5-minute average to cross 80%
setsid nohup timeout "$DURATION" sh -c 'while :; do :; done' >/dev/null 2>&1 &
echo "cpu load started for ${DURATION}s at $(date -u +%H:%M:%SZ)"
