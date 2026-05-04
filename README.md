# pj-rust-cli

Rust **CLI** extras for [kata](https://github.com/yukimemi/kata)
templates. Compose **above** [`pj-rust`](https://github.com/yukimemi/pj-rust)
in the preset order so its files take precedence on conflict.

## Status

Currently empty by design — used during kata Phase 1 dogfood to
demonstrate "templates can grow new files later, and `kata apply`
brings them down to every registered project".

Planned additions (Phase 2+):

- `.github/workflows/release.yml` — tagged-release publish to
  crates.io with tag/Cargo.toml version cross-check
- `src/main.rs` — clap derive + tokio + tracing-subscriber
  scaffolding (`when = "once"`)
- `src/lib.rs` — minimal `mod cli; pub use error::*;` (`when = "once"`)

## Composition

```sh
kata init github.com/yukimemi/pj-presets:rust-cli ./your-new-pj
```

## License

MIT.
