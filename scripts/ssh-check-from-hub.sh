#!/bin/sh
# M3: test TCP 22 from the hub VM to the spoke VM.
# NSG drop = "timed out" (packet never answered); closed port = "Connection refused" (packet reached the VM).
# Run on the hub VM via Azure Run Command:
#   az vm run-command invoke -g rg-hubspoke-vms -n vm-hub-lab2 --command-id RunShellScript --scripts "@scripts/ssh-check-from-hub.sh"
echo "check at $(date -u +%H:%M:%SZ)"
nc -zv -w 5 10.21.1.4 22
echo "RESULT_tcp22=$?"
