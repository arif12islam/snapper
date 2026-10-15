#!/bin/bash
cd "$(dirname "$0")"
./build.sh --dmg && open build
echo
read -n 1 -s -r -p "Press any key to close"
