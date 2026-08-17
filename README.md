# TarFS

[![Build Status](https://github.com/JBlaschke/TarFS.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JBlaschke/TarFS.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://jblaschke.github.io/TarFS.jl/dev/)

An in-memory filesystem backed by a `.tar.gz` archive: load it once, read files
by path, stage new or modified files, and flush everything back to a
gzip-compressed POSIX tarball — atomically, reproducibly, and without touching
the disk in between.

Despite the name, nothing gets mounted. TarFS is a library-level view of an
archive, not a FUSE filesystem: it gives your Julia code `readfile`/`writefile`
semantics over a single `.tar.gz` on disk.

## Why

Parallel filesystems (Lustre, GPFS) and object stores are unhappy places for
directories full of ten thousand small files: metadata servers melt, inode
quotas fill, and each object is another request. A single `.tar.gz` sidesteps
all of that — one file on disk, one object in a bucket — at the cost of random
access. TarFS restores the random access: the archive is decompressed into
memory once, files are indexed by path, and individual entries are materialized
lazily on first read. The write side turns the same archive into a convenient
container for analysis outputs, with atomic read-modify-write on the archive
itself.

## Installation

Until the package is registered:

```julia
pkg> add https://github.com/JBlaschke/TarFS.jl
```

Requires Julia ≥ 1.8. Depends on the `Tar` standard library plus `CodecZlib`
and `TranscodingStreams`.

## Quick start

Reading — `readfile` returns the entry's raw bytes as a `String`, which
composes with anything that accepts an `IOBuffer`:

```julia
using TarFS
using CSV, DataFrames

fs = InMemoryFileSystem("data.tar.gz")
df = DataFrame(CSV.File(IOBuffer(TarFS.readfile(fs, "data/p175.csv"))))
```

Writing — stage files against an empty filesystem, flush on clean exit from
the block:

```julia
open_tarball_gz("results.tar.gz") do fs
    writefile(fs, "summary.csv", sprint(CSV.write, df))
    writefile(fs, "meta/run.txt", "seed = 42\n")
end
```

Read-modify-write — seed from an existing archive and overwrite it in place.
This is safe: the flush is atomic, so a failure anywhere leaves the original
archive untouched.

```julia
TarFS.open_tarball_gz("data.tar.gz"; from = "data.tar.gz") do fs
    df = DataFrame(CSV.File(IOBuffer(TarFS.readfile(fs, "data/p175.csv"))))
    transform!(df, :x => ByRow(log) => :logx)
    TarFS.writefile(fs, "data/p175.csv", sprint(CSV.write, df))
end
```

## API

Nothing is exported; qualify with `TarFS.`.

| Function                                   | Description                                                                                                         |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `InMemoryFileSystem(path)`                 | Load and decompress a `.tar.gz` into memory and index its files.                                                    |
| `InMemoryFileSystem()`                     | Create an empty, writable filesystem.                                                                               |
| `readfile(fs, path)`                       | Return an entry's contents as a `String` (raw bytes; materialized lazily, cached).                                  |
| `writefile(fs, path, content)`             | Stage or overwrite an entry; `content` is an `AbstractString` or `AbstractVector{UInt8}` (byte vectors are copied). |
| `deletefile(fs, path)`                     | Remove an entry.                                                                                                    |
| `open_tarball_gz(f, path; from = nothing)` | Run `f(fs)` and flush to `path` on normal return; `from` seeds from an existing archive.                            |
| `write_tarball_gz(fs, path)`               | Flush to a `.tar.gz` at `path`, atomically.                                                                         |
| `write_tarball(fs, io)`                    | Write an uncompressed POSIX tarball to any `IO`.                                                                    |
| `write_tarball_gz_viatar(fs, path)`        | Flush via `Tar.create` through a temporary directory (see below).                                                   |

Member paths must be relative, `/`-separated, and free of `..`, `.`, empty
segments, and NUL bytes; `writefile` enforces this. Julia `String`s hold
arbitrary bytes, so binary content round-trips exactly — use `codeunits` or
wrap in `IOBuffer` on the way out as needed.

## Guarantees

**Atomic flushes.** `write_tarball_gz` writes to a temporary file in the
destination directory and renames it into place only once complete. An
exception or crash mid-flush leaves any existing archive at the target path
untouched, which is what makes `from = path` read-modify-write safe. This is
atomicity against application failure; there is deliberately no `fsync`, so
power-loss durability remains your filesystem's department.

**Reproducible bytes.** Entries are written in sorted path order with
normalized metadata (mode `0o644`, uid/gid/mtime `0` — the same normalization
`Tar.jl` applies). The same filesystem contents always produce byte-identical
tarballs. The gzip layer is deterministic for a given zlib build; the gzip
header's OS byte varies across platforms, so cross-platform byte-identity holds
at the tar layer and per-machine at the `.tar.gz` layer.

**Lazy in, streaming out.** Loading an archive indexes headers without
materializing contents; a file's bytes are decoded on first `readfile` and
cached thereafter. Flushing streams source-backed entries directly from the
in-memory archive without caching them, so writing out a large seeded
filesystem does not double its footprint.

**Cross-validated.** The test suite checks the writer's output against
`Tar.list` (strict header validation), `Tar.extract`, and the system `tar`
binary, and checks the reader against archives produced by `Tar.create`.

## Two writers

The default writer emits USTAR headers by hand, entirely in memory. It handles
regular files with paths up to the USTAR name/prefix limits (100 bytes, or
longer when splittable at a `/` into a ≤155-byte prefix and ≤100-byte name) and
entries under 8 GiB (the 11-octal-digit size field); it errors loudly rather
than emit a malformed header, and it does not write explicit directory entries.

`write_tarball_gz_viatar` round-trips through a temporary directory and lets
`Tar.create` do the writing. It costs disk I/O but handles arbitrarily long
paths via extended headers and emits explicit directory entries — use it when
the archive will be consumed by tools that care about those, such as `tar -x`
or docker. For archives read back through TarFS itself, the two are
interchangeable.

## Limitations

TarFS is not a general archiver, and does not intend to become one. It handles
regular files only: no symlinks, no hardlinks, no permission preservation (not
even the executable bit — everything is normalized to `0o644`), no GNU sparse
members. The whole decompressed archive lives in RAM for the lifetime of the
filesystem, plus cached reads, plus staged writes — if the archive does not fit
in memory, this is the wrong tool, on purpose. A filesystem instance is not
thread-safe (shared scratch buffers, seek-based reads); use one per task.
Finally, the reader is built on `Tar.jl` internal helpers (`read_tarball`,
`read_data`, `skip_data`, `arg_read`), which live in a standard library whose
internals track the Julia version — run CI on every Julia version you intend to
support.

## Testing

```julia
pkg> test
```

The suite includes Aqua.jl quality checks alongside the behavioral tests. For a
quick smoke check in a running session, `TarFS._selftest()` round-trips a small
archive through write, re-read, and in-place overwrite.

## License

BSD-3-Clause — see `LICENSE`.
