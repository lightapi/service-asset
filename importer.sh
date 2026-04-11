#!/bin/bash

set -ex

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
JARFILE=$CURRENT_DIR/target/event-importer.jar
if [ ! -f "$JARFILE" ]; then
    echo "event-importer.jar cannot be found in target!"
    exit 1
fi

if [ -z "$JAVA_HOME" ]; then
    echo "JAVA_HOME is not set"
    exit 1
fi

# Note: please point JAVA_HOME to a JDK installation. JRE is not sufficient.
"$JAVA_HOME/bin/java" -Dlight-4j-config-dir="$CURRENT_DIR/config/local" -jar "$JARFILE" "$@"

exit 0
