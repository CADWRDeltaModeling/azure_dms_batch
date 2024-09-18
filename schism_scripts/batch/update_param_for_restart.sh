#!/bin/bash

# Check if a filename is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <filename>"
  exit 1
fi

# Check if the file exists
if [ ! -f "$1" ]; then
  echo "File not found!"
  exit 1
fi

# Replace "ihot = 1" with "ihot = 2", allowing for spaces around the "=" and "1"
sed -i 's/ihot[[:space:]]*=[[:space:]]*1/ihot = 2/g' "$1"

echo "Replacement done in file $1."
