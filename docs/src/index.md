# TarFS.jl

```@meta
CurrentModule = TarFS
```

An in-memory filesystem backed by a `.tar.gz` archive: load it once, read files
by path, stage new or modified files, and flush everything back to a
gzip-compressed POSIX tarball — without touching the host filesystem inbetween.
This is ideal for eating large text logs scattered over many files. See the
repository README for motivation and design notes; this page documents the API.

## Rationale: When is TarFS right for you?

Think about this use case: your workflow is generating a huge number of
(possibly text) files (possibly on a shared file system); and for whatever
reason, you can't switch to a better file format (nor are databases an option).

Parallel filesystems (Lustre, GPFS) and object stores are unhappy places for
directories full of ten thousand small files: metadata servers choke, inode
and block quotas fill, especially when dealing with large collections of json
records.

A single `.tar.gz` sidesteps all of that — one compressed file on disk, one
object in a bucket — at the cost of random access, and needing a place to
decompress to.

TarFS restores the random access: the archive is decompressed into memory once,
files are indexed by path, and individual entries are materialized lazily on
first read. The write side turns the same archive into a convenient container
for analysis outputs, with atomic read-modify-write on the archive itself.

A nice side-effect of using `.tar.gz` is that you don't need to maintain the
readers for any custom file format: this data will be readable as long as tar
and gzip are around

### Why not use another file format (looking at you HDF5, or Parquet, or Avro)?

Good Point! There is a problem with this approach though if:

1. Your data needs to readable long into the future. Tar and Gzip will be
   around practically forever.
2. Not everyone in your team wants to use your custom file system, and you
   don't want to use theirs. Sometimes this has good reasons (file format
   readers are hard to get right!)

### When should you just use something else?

Working on `/tmp` or using SQLite, HDF5, etc is perfectly reasonable.

1. TarFS does not give you POSIX. If you need full POSIX, then just faff around
   with `/tmp`. God help your soul.
2. If your data is columnar, then just use a mainstream collumnar file system.

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
