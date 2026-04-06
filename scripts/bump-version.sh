#!/bin/bash
# Usage: ./scripts/bump-version.sh <new-version>
# Example: ./scripts/bump-version.sh 2.1
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
  CURRENT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" src-swift/Info.plist)
  echo "Current version: $CURRENT"
  echo "Usage: $0 <new-version>  (e.g. $0 2.1)"
  exit 1
fi

PLIST="src-swift/Info.plist"

/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${VERSION}.0" "$PLIST"

echo "Bumped to v$VERSION"
echo ""

# Show diff
git diff "$PLIST"
