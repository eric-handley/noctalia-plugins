#!/bin/bash
# Helper script to receive Taildrop files
# The window will stay open now since it's a Popup, not a SmartPanel

TAILDROP_DIR="$1"

# Run pkexec to download files
pkexec sh -c "tailscale file get '$TAILDROP_DIR' && chown -R \$SUDO_UID:\$SUDO_GID '$TAILDROP_DIR'"

exit 0
