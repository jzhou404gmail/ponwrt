#!/bin/sh
# Install the system-wide systemd-oomd override for user@.service.
#
# If you are running inside a restricted sandbox with no_new_privs, sudo
# cannot be used from inside it.  Run this from a normal terminal:
#
#     sudo ./scripts/systemd/install-oomd-override.sh
#
# It only writes a drop-in and reloads systemd; it does not restart the
# graphical session.  Undo with:
#     sudo rm /etc/systemd/system/user@.service.d/99-oomd-user-service.conf
#     sudo systemctl daemon-reload
#     sudo systemctl restart systemd-oomd

set -eu

if [ "$(id -u)" -ne 0 ]; then
	echo "请用 sudo 运行：sudo $0" >&2
	exit 1
fi

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dst=/etc/systemd/system/user@.service.d/99-oomd-user-service.conf

install -Dm644 "$here/99-oomd-user-service.conf" "$dst"
systemctl daemon-reload
systemctl try-restart systemd-oomd 2>/dev/null || true

echo "已安装：$dst"
echo
systemctl show user@1000.service -p ManagedOOMMemoryPressure -p ManagedOOMMemoryPressureLimit
