#!/bin/sh -e

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is not installed. Install it with:"
    echo "  brew install xcodegen"
    exit 1
fi

xcodegen generate
