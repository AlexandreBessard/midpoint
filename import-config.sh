#!/bin/sh

set -e

echo "======================================"
echo " MidPoint configuration"
echo "======================================"

echo "Objects directory:"
ls -la /opt/midpoint/objects

echo
echo "XML files:"
find /opt/midpoint/objects -type f -name "*.xml"

echo
echo "Configuration files found successfully."