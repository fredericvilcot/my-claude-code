Vendored [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.8.0 (MIT licence, see LICENSE): the last release
that builds with Swift 5.10 and plain `swiftc`. Only the shared and macOS sources are kept (no iOS).
`build.sh` compiles it once into a separate `SwiftTerm` module (build/swiftterm), rebuilt only when these sources change.
