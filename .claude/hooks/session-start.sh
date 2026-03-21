#!/bin/bash
set -euo pipefail

# Only run in remote (Claude Code on the web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Install SuperCollider language for syntax checking
if ! command -v sclang &> /dev/null; then
  apt-get update -qq
  apt-get install -y -qq supercollider-language
fi

echo "SuperCollider language (sclang) is available at: $(command -v sclang)"
