#!/bin/sh
# No-root fallback: protect the *current* terminal scope from systemd-oomd.
#
# Ubuntu's /usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf
# sets a 50% memory-pressure limit.  If a build pushes the user manager over
# that limit, systemd-oomd kills the whole terminal scope.  Setting the scope's
# own limit to 100% makes it effectively ineligible while keeping the setting
# local to this terminal (no root needed).
#
# Usage:
#   . /home/jzhou/work/ponwrt/scripts/systemd/protect-terminal-scope.sh
#
# To make it apply to every new interactive bash shell, add the line above to
# ~/.bashrc.  For a system-wide permanent fix use install-oomd-override.sh.

__oomd_scope=$(sed -n 's|.*/\([^/]*\.scope\)$|\1|p' /proc/self/cgroup 2>/dev/null)
if [ -n "$__oomd_scope" ]; then
	systemctl --user set-property "$__oomd_scope" \
		ManagedOOMMemoryPressure=kill \
		ManagedOOMMemoryPressureLimit=100% >/dev/null 2>&1 || true
fi
unset __oomd_scope
