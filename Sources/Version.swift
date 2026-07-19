// Version.swift — build-time version stamp.
//
// Local `./build.sh` runs leave the default below, and the updater treats any
// 0.0.0-dev build as "not a distributed release" and never nags about updates.
// The release workflow exports VERSION=<tag>, which build.sh stamps in here
// (and into the bundle's CFBundleShortVersionString) before compiling.
let appVersion = "0.0.0-dev"
