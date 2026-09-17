#!/bin/bash
# Run the startup regression suite; the cases live in the focused rotation file.
exec bash "$(dirname "$0")/docker-macaroon-password-rotation-tests.sh" "$@"
