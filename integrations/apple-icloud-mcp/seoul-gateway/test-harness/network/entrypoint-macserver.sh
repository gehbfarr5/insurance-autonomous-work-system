#!/bin/bash
set -e

# Write sshd_config
cat << 'EOF' > /etc/ssh/sshd_config
Port 2222
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
AuthorizedKeysFile /root/.ssh/authorized_keys
AllowTcpForwarding yes
PermitOpen 127.0.0.1:18765
GatewayPorts no
X11Forwarding no
PrintMotd no
Subsystem sftp internal-sftp
EOF

if [ -f /root/.ssh/authorized_keys ]; then
  chmod 600 /root/.ssh/authorized_keys
fi

# Start sshd
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# Start Fake Bridge
node /app/fake-macserver.js &
BRIDGE_PID=$!

trap "kill $SSHD_PID $BRIDGE_PID 2>/dev/null; exit 0" SIGTERM SIGINT

wait -n $SSHD_PID $BRIDGE_PID
