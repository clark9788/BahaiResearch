#!/bin/bash
# Resolution order for KEY_PATH:
# 1) Existing KEY_PATH environment variable (preferred for secret key storage)
# 2) Optional first argument to this script
# 3) Local packaged file: ./bahai-research.properties

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$KEY_PATH" ]; then
  if [ -n "$1" ]; then
    export KEY_PATH="$1"
  elif [ -f "$SCRIPT_DIR/bahai-research.properties" ]; then
    export KEY_PATH="$SCRIPT_DIR/bahai-research.properties"
  else
    echo "ERROR: No KEY_PATH was provided."
    echo "Set environment variable KEY_PATH, or pass a properties path argument,"
    echo "or place bahai-research.properties next to run-app.sh."
    exit 1
  fi
fi

if [ ! -f "$KEY_PATH" ]; then
  echo "ERROR: KEY_PATH file not found: $KEY_PATH"
  exit 1
fi

JAVA_EXE="$SCRIPT_DIR/runtime/bin/java"
if [ ! -f "$JAVA_EXE" ]; then
  JAVA_EXE="java"
fi

# Dynamically locate the fat JAR under build/libs or target
JAR_PATH=$(find "$SCRIPT_DIR/build/libs" "$SCRIPT_DIR/target" -name "BahaiResearch-*-all.jar" 2>/dev/null | head -n 1)

# Fall back to the jar staged in the Windows payload, which has no version in its name
if [ -z "$JAR_PATH" ] && [ -f "$SCRIPT_DIR/dist/installer/BahaiResearch/app/BahaiResearch-all.jar" ]; then
  JAR_PATH="$SCRIPT_DIR/dist/installer/BahaiResearch/app/BahaiResearch-all.jar"
fi

if [ -z "$JAR_PATH" ]; then
  echo "ERROR: No application jar found. Run ./gradlew shadowJar, or build the payload."
  exit 1
fi

echo "Using KEY_PATH=$KEY_PATH"
echo "Running: $JAVA_EXE ${JAVA_OPTS:-} -jar $JAR_PATH"
# shellcheck disable=SC2086
"$JAVA_EXE" ${JAVA_OPTS:-} -jar "$JAR_PATH"
