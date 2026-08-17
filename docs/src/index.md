# TarFS.jl

```@meta
CurrentModule = TarFS
```

An in-memory filesystem backed by a `.tar.gz` archive: load it once, read files
by path, stage new or modified files, and flush everything back to a
gzip-compressed POSIX tarball — atomically and reproducibly. See the repository
README for motivation and design notes; this page documents the API.

## Usage

Reading — [`readfile`](@ref) returns raw bytes as a `String`, which composes
with anything that accepts an `IOBuffer`:

```julia
using TarFS

fs = InMemoryFileSystem("data.tar.gz")
csv = readfile(fs, "data/p175.csv")
```

Writing, including atomic read-modify-write of an archive in place:

```julia
open_tarball_gz("data.tar.gz"; from = "data.tar.gz") do fs
    writefile(fs, "meta/run.txt", "seed = 42\n")
end
```

## Public API

Nothing is exported; qualify names with `TarFS.`.

```@docs
InMemoryFileSystem
readfile
writefile
deletefile
open_tarball_gz
write_tarball_gz
write_tarball
write_tarball_gz_viatar
```

## Guarantees and limits

Flushes are atomic against application failure (temporary file plus
same-directory rename; no `fsync`, so power-loss durability is the filesystem's
department). Output bytes are reproducible: entries are written in sorted path
order with normalized metadata, matching `Tar.jl`'s conventions. Reads are lazy
and cached; flushing streams source-backed entries without caching them. The
in-memory writer handles regular files only, with USTAR path-length limits and
an 8 GiB per-entry cap — [`write_tarball_gz_viatar`](@ref) lifts the path
restriction at the cost of a disk round-trip. Filesystem instances are not
thread-safe.

## Docstring index

```@index
```
