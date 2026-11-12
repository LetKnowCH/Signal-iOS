# Building

The project specifies Xcode 26.3 in `.xcode-version`.

## 1. Clone

Clone the repo to a working directory:

```
git clone --branch dev --recurse-submodules https://github.com/LetKnowCH/Signal-iOS.git
```

Since we make use of sub-modules, you must use `git clone`, rather than
downloading a prepared zip file from Github.

## 2. Dependencies

The app uses CocoaPods 1.16.2 and the LetKnow libsignal checkout at `../libsignal`.
Run these commands from the iOS repository for a new Apple silicon simulator setup.

```sh
git clone --branch v0.94.1-letknow.1 https://github.com/LetKnowCH/libsignal.git ../libsignal
(cd ../libsignal && CARGO_BUILD_TARGET=aarch64-apple-ios-sim swift/build_ffi.sh --release)
```

If you already have this checkout and its release library for your target, reuse them.
For a physical iPhone, use `aarch64-apple-ios` as the Cargo target.
Then install the dependencies from the lockfile.

```
make dependencies
```

## 3. Xcode

With Xcode 27.2, install the Metal toolchain with `xcodebuild -downloadComponent MetalToolchain`.
For local builds with this compiler, copy `Config/User.xcconfig.sample` to `Config/User.xcconfig` to allow Swift warnings.

Open the `Signal.xcworkspace` in Xcode.

```
open Signal.xcworkspace
```

In the TARGETS area of the General tab, change the Team drop down to
your own. You will need to do that for all the listed targets, for ex.
Signal, SignalShareExtension, and SignalNSE. You will need an Apple
Developer account for this.

On the Capabilities tab, turn off Push Notifications, Apple Pay,
Communication Notifications, and Data Protection, while keeping Background Modes
on. The App Groups capability will need to remain on in order to access the
shared data storage. The best way to change the bundle ID for the app groups is
setting `SIGNAL_BUNDLEID_PREFIX` in the project's settings.

If you wish to test the Documents API, the iCloud capability will need to
be on with the iCloud Documents option selected.

Build and Run and you are ready to go!

## Known issues

Features related to push notifications are known to be not working for
third-party contributors since Apple's Push Notification service pushes
will only work with Open Whisper Systems production code signing
certificate.

Turn on Push Notifications on the Capabilities tab if you want to register a new Signal account using the application installed via XCode.

If you have any other issues, please ask on the [community forum](https://community.signalusers.org/).
