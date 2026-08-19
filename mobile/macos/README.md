# macOS build

The desktop app uses the pinned LÖVE 12 runtime built from the LÖVE source
tree and the matching Apple dependency repository. The runtime enables Metal
and is fused into the branded `gen1recomp++.app` bundle.

Build the runtime and desktop app from the repository root:

```bash
scripts/build_love_macos.sh --fetch
LOVE_APP="$PWD/.bazinga/love12/love.app" scripts/build.sh mac --no-notarize --identity -
```

The source and dependency revisions are recorded in `LOVE_SOURCE_REF` and
`APPLE_DEPENDENCIES_REF`. Delete `.bazinga/love12/source` or use `--clean`
when changing those pins.

The packaged executable is `gen1recomp++` inside `gen1recomp++.app`, and the
bundle declares LÖVE 12.0 compatibility.
