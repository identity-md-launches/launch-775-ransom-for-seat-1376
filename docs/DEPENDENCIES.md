# Vendored dependencies

All build and test dependencies are ordinary files under `lib/`. There are no
submodules, runtime downloads, package-install steps, or compiler binaries in
the deliverable. The independent build environment supplies the compiler
version pinned in `foundry.toml`.

| Dependency | Source | Archive SHA-256 |
| --- | --- | --- |
| v4-core 1.0.2 | `https://registry.npmjs.org/@uniswap/v4-core/-/v4-core-1.0.2.tgz` | `f3db3af55f3d0c52f16abe96e7db12443f243bca1f334962373f95c57611de49` |
| forge-std v1.9.7 | `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7` | `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94` |

The v4-core archive supplies the `src` tree and its bundled Solmate sources.
Upstream test directories are omitted. The v4 package version record is
`lib/v4-core/package.json`; license texts are under `lib/v4-core/licenses/` and
`lib/v4-core/lib/solmate/LICENSE`. Upstream source licenses remain in their files.
forge-std's `src` tree and its MIT/Apache licenses are retained. Vendored source
is unmodified. This project's authored Solidity is MIT-licensed.
