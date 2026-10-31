#!/bin/zsh
set -eu
cd -- "${0:A:h}"
build_dir=$(mktemp -d -t kdtouch.XXXXXXXXXX)
trap 'rm -rf "$build_dir"' EXIT
: "${SDKROOT:?Enter the development environment with nix develop}"
swift_flags=(-sdk "$SDKROOT" -target arm64-apple-macosx26.0 -no-toolchain-stdlib-rpath)
mkdir -p "$build_dir/KDTouch.app/Contents/MacOS" "$build_dir/KDTouch.app/Contents/Resources" build
swiftc "${swift_flags[@]}" Sources/Touch.swift Tests/main.swift -o "$build_dir/selfcheck"
"$build_dir/selfcheck" Tests/captured-reports.txt
swiftc "${swift_flags[@]}" -O Sources/Touch.swift Sources/main.swift -o "$build_dir/KDTouch.app/Contents/MacOS/KDTouch"
cp Resources/SW4101C.bin "$build_dir/KDTouch.app/Contents/Resources/"
cp Info.plist "$build_dir/KDTouch.app/Contents/"
/usr/bin/codesign --force --sign "${KDTOUCH_SIGN_IDENTITY:--}" --timestamp=none "$build_dir/KDTouch.app"
/usr/bin/codesign --verify --strict "$build_dir/KDTouch.app"
/usr/bin/ditto --norsrc --noextattr "$build_dir/KDTouch.app" build/KDTouch.app
/usr/bin/ditto -c -k --keepParent "$build_dir/KDTouch.app" build/KDTouch.zip
