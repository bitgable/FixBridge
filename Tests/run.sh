#!/bin/sh
set -eu
umask 077
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
test_dir=$(mktemp -d -t fixbridge-regression)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -enable-bare-slash-regex \
  FixBridge/Models/FixBridgeError.swift \
  FixBridge/Models/Location.swift \
  FixBridge/Models/GPXRoute.swift \
  FixBridge/ViewModels/GPXRouteViewModel.swift \
  FixBridge/Models/SessionLocation.swift \
  FixBridge/Models/LocationSubscription.swift \
  FixBridge/Services/BackgroundTask.swift \
  FixBridge/Services/USBSessionRecovery.swift \
  FixBridge/Services/ToolProcess.swift \
  FixBridge/Services/SavedLocationStore.swift \
  FixBridge/Services/SavedRouteStore.swift \
  FixBridge/Services/ApplicationIdentity.swift \
  FixBridge/Services/MapCoordinateProjection.swift \
  FixBridge/ViewModels/FixBridgeViewModel.swift \
  FixBridge/Models/LocationInput.swift \
  FixBridge/ViewModels/SavedLocationEditorViewModel.swift \
  FixBridge/ViewModels/RouteEditorViewModel.swift \
  FixBridge/ViewModels/RouteMapViewModel.swift \
  FixBridge/ViewModels/TargetLocationViewModel.swift \
  Tests/EditorViewModelChecks.swift Tests/SessionTestDoubles.swift Tests/GPXChecks.swift Tests/RouteLibraryChecks.swift Tests/MapProjectionChecks.swift Tests/RegressionChecks.swift \
  -o "$test_dir/session-checks"
"$test_dir/session-checks"

# Generate throwaway fixtures; never read real MFi files or write to the keychain.
/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$test_dir/key.pem"
/usr/bin/openssl req -new -x509 -key "$test_dir/key.pem" -subj /CN=FixBridge-Test \
  -days 1 -out "$test_dir/certificate.pem"
/usr/bin/openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -subj /CN=FixBridge-Unmatched -days 10 -keyout "$test_dir/unmatched-key.pem" \
  -out "$test_dir/unmatched.pem" 2>/dev/null
/usr/bin/openssl crl2pkcs7 -nocrl -certfile "$test_dir/unmatched.pem" -certfile "$test_dir/certificate.pem" \
  -outform DER -out "$test_dir/certificate.p7b"
/usr/bin/openssl pkcs8 -topk8 -nocrypt -in "$test_dir/key.pem" \
  -outform DER -out "$test_dir/identity.pk8"
/usr/bin/mkfifo "$test_dir/not-a-file"
xcrun swiftc -parse-as-library \
  FixBridge/Models/FixBridgeError.swift FixBridge/Services/ApplicationIdentity.swift FixBridge/Services/MFIIdentity.swift \
  Tests/CredentialChecks.swift -o "$test_dir/credential-checks"
"$test_dir/credential-checks" "$test_dir"
xcrun clang Tests/USBIOChecks.c -framework CoreFoundation -o "$test_dir/usb-io-checks"
"$test_dir/usb-io-checks"
xcrun swiftc -parse-as-library \
  FixBridge/Models/FixBridgeError.swift FixBridge/Models/Location.swift \
  FixBridge/Services/TerrainElevation.swift Tests/TerrainElevationChecks.swift \
  -o "$test_dir/elevation-checks"
"$test_dir/elevation-checks"

# Exercise the actual wire codec and detection exchange without opening any device.
xcrun swiftc -parse-as-library \
  FixBridge/Models/FixBridgeError.swift FixBridge/Models/LocationSubscription.swift \
  FixBridge/Models/IAP2Protocol.swift Tests/IAP2ProtocolChecks.swift \
  -o "$test_dir/iap2-checks"
"$test_dir/iap2-checks"
xcrun swiftc -parse-as-library -enable-bare-slash-regex \
  FixBridge/Models/FixBridgeError.swift FixBridge/Models/Location.swift \
  FixBridge/Models/GPXRoute.swift FixBridge/Models/SessionLocation.swift \
  FixBridge/Models/LocationSubscription.swift FixBridge/Models/IAP2Protocol.swift \
  FixBridge/Services/USBSessionRecovery.swift FixBridge/Services/AccessorySession.swift \
  Tests/AccessorySessionChecks.swift -o "$test_dir/accessory-session-checks"
"$test_dir/accessory-session-checks"
