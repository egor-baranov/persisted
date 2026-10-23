#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
developer_directory="$(xcode-select -p)"
# The CLT bundle includes Swift Testing, but SwiftPM does not add its framework
# and interop library paths automatically. Full Xcode needs no workaround.
testing_frameworks="$developer_directory/Library/Developer/Frameworks"
testing_libraries="$developer_directory/Library/Developer/usr/lib"
if [[ "$developer_directory" == */CommandLineTools && -d "$testing_frameworks/Testing.framework" ]]; then
  swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$testing_frameworks" \
    -Xlinker -F -Xlinker "$testing_frameworks" \
    -Xlinker -rpath -Xlinker "$testing_frameworks" \
    -Xlinker -rpath -Xlinker "$testing_libraries" "$@"
else
  swift test --disable-xctest --enable-swift-testing "$@"
fi
