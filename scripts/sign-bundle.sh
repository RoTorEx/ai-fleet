#!/bin/sh
set -eu
bundle=${1:?Pass the bundle path}
identity=${2:--}
codesign --force --sign "$identity" "$bundle/Contents/MacOS/fleet-session-engine"
codesign --force --sign "$identity" "$bundle"
codesign --verify --deep --strict "$bundle"
