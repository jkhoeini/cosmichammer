# Plan: Release-only stale head integration

## Scope

Resolve the TODO for stale head `zmqntpmzskkp`:

- `flake.nix`
- `TODO.org`
- `PLAN.md`

## Audit

`jj diff -s --no-pager -r zmqntpmzskkp` changes only `flake.nix`.

The stale diff:

- bumps `version = "0.5.2"` to `version = "0.5.3"`;
- updates the release DMG hash from
  `sha256-d+f7r/LiemexGdOmTy6JHe4nUpyCPI+nYWleHCzdoo0=` to
  `sha256-IDWcQpqoUKCIS1r+REWMV2BE9uESMGNfeZ6i+x36kPU=`.

Current head still has `flake.nix` at `0.5.2`, so this change is not already
represented. GitHub shows release `v0.5.3` exists and is marked latest. Local
jj tags also include `v0.5.3` at `ac54e34a7c37`.

Nix verification:

- `nix store prefetch-file --json https://github.com/jkhoeini/cosmichammer/releases/download/v0.5.3/Cosmic-Hammer-0.5.3.dmg`
  returned `sha256-IDWcQpqoUKCIS1r+REWMV2BE9uESMGNfeZ6i+x36kPU=`.
- The same command for `0.5.2` returned the current `flake.nix` hash, proving
  the prefetch path is checking the same release artifact shape.

## Decision

Integrate the stale `flake.nix` bump. It is useful because the Nix package is
currently one release behind a real, verified `v0.5.3` DMG.

This does not make `zmqntpmzskkp` worth keeping as a branch head after
integration: once the two-line flake change is in current linear history, that
head contains no remaining useful change.

## Implementation

1. Update `flake.nix` to `0.5.3` and the verified hash.
2. Mark the TODO done with the audit and verification notes.
3. Run:

```sh
zsh -ic 'nix build ".#cosmic-hammer" --no-link'
```

Claude plan review recommended `nix build ".#cosmic-hammer" --no-link` as the
single useful gate because it proves the derivation evaluates and the prefetched
hash is accepted.

## Review Questions

- Is it acceptable for current development history to point the Nix package at
  the latest released DMG even though current source now contains additional
  unreleased commits? I think yes: this flake packages upstream release assets,
  not the working tree source.
- Should this be skipped as release bookkeeping? I think no: users of the Nix
  package would otherwise install `0.5.2` even though `0.5.3` is the current
  release.
