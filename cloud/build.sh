#!/bin/sh
# Build the website assets shared with the local personal setup.
set -e
cd "$(dirname "$0")/.."
exec ./local/build.sh
