# =========================================================================
# A written file OWNS its bytes: pos = -1 marks "not backed by the source
# tarball", and readfile's `str === nothing || return str` short-circuit
# means the seek path is never taken for it.
#
# Changes vs v1:
# =========================================================================

module TarFS

using Tar, CodecZlib, TranscodingStreams

mutable struct InMemoryFile
    size::Int
    pos::Int
    str::Union{Nothing, String}
end

"""
    InMemoryFileSystem

An in-memory filesystem backed by a `.tar.gz` archive. Construct it empty
with `InMemoryFileSystem()` or from an archive with `InMemoryFileSystem(path)`;
read entries with [`readfile`](@ref), stage changes with [`writefile`](@ref),
and flush with [`write_tarball_gz`](@ref) or [`open_tarball_gz`](@ref).
"""
mutable struct InMemoryFileSystem
    d::Dict{String, InMemoryFile}
    tarball_io::IOBuffer
    out_io::IOBuffer
    buf::Vector{UInt8}
end

export InMemoryFileSystem

"""
    readfile(fs, path) -> String

Contents of `path` as raw bytes in a `String`, decoded from the in-memory
archive on first access and cached thereafter. Throws `KeyError` for
unknown paths.
"""
function readfile(ref::InMemoryFileSystem, path::AbstractString)
    file = ref.d[path]
    file.str === nothing || return file.str
    seek(ref.tarball_io, file.pos)
    Tar.read_data(ref.tarball_io, ref.out_io; size=file.size, buf=ref.buf)
    file.str = String(take!(ref.out_io))
end

export readfile

# ---- staging files in memory ---------------------------------------------

const true_predicate = _ -> true

"""
    InMemoryFileSystem(path::AbstractString)

Load the `.tar.gz` at `path` into memory, decompress it, and index its
regular-file entries. Contents are materialized lazily by [`readfile`](@ref).
"""
function InMemoryFileSystem(path::AbstractString)::InMemoryFileSystem
    # Load and decompress archive into memory
    tarball_io = open(path) do tarball_gz
        tarball_io = IOBuffer()
        gz_stream  = GzipDecompressorStream(tarball_io)
        write(gz_stream, tarball_gz, TranscodingStreams.TOKEN_END)
        flush(gz_stream)
        seekstart(tarball_io)
        tarball_io
    end
    # In-memory file system
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    system = InMemoryFileSystem(
        Dict{String, InMemoryFile}(), tarball_io, IOBuffer(), buf
    )
    # Unpack decompressed archive in-memory file system
    Tar.arg_read(tarball_io) do tar
        Tar.read_tarball(true_predicate, tar; buf=buf) do hdr, _
            if hdr.type == :file
                p = position(tar)
                Tar.skip_data(tar, hdr.size)
                system.d[hdr.path] = InMemoryFile(hdr.size, p, nothing)
            end
        end
    end
    return system
end

"""
    InMemoryFileSystem()

Empty, writable filesystem with no backing tarball.
"""
function InMemoryFileSystem()::InMemoryFileSystem
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    InMemoryFileSystem(Dict{String, InMemoryFile}(), IOBuffer(), IOBuffer(), buf)
end

# Tar member paths must be relative, '/'-separated, with no "", "." or ".."
# segments. Also defends `joinpath(dir, p)` in write_tarball_gz_viatar:
# an absolute `p` would *replace* dir entirely and write outside it.
function _check_path(path::AbstractString)
    isempty(path)         && throw(ArgumentError("empty path"))
    occursin('\0', path)  && throw(ArgumentError("NUL byte in path"))
    startswith(path, '/') && throw(ArgumentError("absolute path: $path"))
    for seg in eachsplit(path, '/')
        seg in ("", ".", "..") &&
            throw(ArgumentError("bad segment $(repr(seg)) in path: $path"))
    end
    return path
end

"""
Stage (or overwrite) a file. `content` may be a string or a byte vector;
byte vectors are copied, so the caller's buffer is left intact.
Overwriting a source-backed path replaces the entry, so
read -> transform -> writefile is read-modify-write.
"""
function writefile(fs::InMemoryFileSystem, path::AbstractString,
                   content::Union{AbstractString, AbstractVector{UInt8}})
    _check_path(path)
    s = content isa AbstractString ? String(content) : String(copy(content))
    fs.d[path] = InMemoryFile(sizeof(s), -1, s)   # pos = -1: owns its bytes
    return path
end

export writefile

"""
    deletefile(fs, path) -> Nothing

Remove `path` from the filesystem; a no-op if absent.
"""
deletefile(fs::InMemoryFileSystem, path::AbstractString) =
    (delete!(fs.d, path); nothing)

# ---- in-memory USTAR writer -----------------------------------------------

const _ZERO_BLOCK = zeros(UInt8, 512)

# Split a path into (name <= 100 B, prefix <= 155 B) on a '/', per USTAR.
# Byte-level on ASCII '/', so UTF-8 names are handled correctly.
function _split_path(path::AbstractString)
    sizeof(path) <= 100 && return (String(path), "")
    b = Vector{UInt8}(codeunits(path))
    split = 0
    for i in eachindex(b)
        b[i] == UInt8('/') || continue
        if (i - 1) <= 155 && (length(b) - i) <= 100
            split = i                       # rightmost valid split
        end
    end
    split == 0 && error("path too long for USTAR (use write_tarball_gz_viatar): $path")
    return (String(b[split+1:end]), String(b[1:split-1]))
end

# One 512 B header for a regular file. Mirrors Tar.jl's normalization
# (mode 0o644, uid/gid/mtime 0, "ustar\0" + version "00") so it
# round-trips through Tar.read_tarball.
function _ustar_header(path::AbstractString, size::Integer)
    0 <= size < 8^11 ||                     # 11 octal digits -> 8 GiB cap
        error("entry too large for USTAR (needs PAX; use an external tool): $path ($size bytes)")
    name, prefix = _split_path(path)
    h = zeros(UInt8, 512)
    putstr!(off, len, s) = (b = codeunits(s); copyto!(h, off + 1, b, 1, min(length(b), len)))
    putoct!(off, len, v) = putstr!(off, len, string(v; base = 8, pad = len - 1))

    putstr!(0,   100, name)
    putoct!(100,   8, 0o644)                # mode
    putoct!(108,   8, 0)                    # uid
    putoct!(116,   8, 0)                    # gid
    putoct!(124,  12, size)                 # size (11 octal digits + NUL)
    putoct!(136,  12, 0)                    # mtime
    fill!(view(h, 149:156), UInt8(' '))     # chksum field = spaces while summing
    h[157] = UInt8('0')                     # typeflag: regular file
    putstr!(257,   6, "ustar")              # magic "ustar\0" (NUL from zeros)
    h[264] = h[265] = UInt8('0')            # version "00"
    putstr!(345, 155, prefix)

    chksum = sum(h)                         # sum() widens UInt8 -> UInt: no overflow
    putstr!(148, 6, string(chksum; base = 8, pad = 6))  # max 130560 < 8^6
    h[155] = 0x00                           # field encoding: "dddddd\0 "
    h[156] = UInt8(' ')
    return h
end

# Emit one file's bytes to `io` WITHOUT caching them on the entry.
function _write_filedata(fs::InMemoryFileSystem, io::IO, file::InMemoryFile)
    if file.str !== nothing
        write(io, file.str)                 # raw bytes of the String
    else
        seek(fs.tarball_io, file.pos)       # stream from source tarball
        Tar.read_data(fs.tarball_io, io; size = file.size, buf = fs.buf)
    end
    return nothing
end

"""
Write the whole filesystem as a POSIX tarball to `io` (uncompressed).
Source-backed files are streamed, not cached; `fs.tarball_io`'s position
is clobbered, which is fine — readfile always seeks first.
"""
function write_tarball(fs::InMemoryFileSystem, io::IO)
    for path in sort!(collect(keys(fs.d)))  # sorted => reproducible bytes
        file = fs.d[path]
        sz = file.str === nothing ? file.size : sizeof(file.str)
        write(io, _ustar_header(path, sz))
        _write_filedata(fs, io, file)
        pad = (-sz) & 511                   # pad data to a 512 B boundary
        pad == 0 || write(io, view(_ZERO_BLOCK, 1:pad))
    end
    write(io, _ZERO_BLOCK)                  # two zero blocks = EOF
    write(io, _ZERO_BLOCK)
    return io
end

# Write one complete gzip member to `path` atomically: temp file in the
# same directory, rename over the target only once complete. Atomic
# w.r.t. application failure (no fsync, so not power-loss durable).
function _atomic_gz(f, path::AbstractString)
    tmp, tmpio = mktemp(dirname(abspath(path)); cleanup = false)
    try
        gz = GzipCompressorStream(tmpio)
        f(gz)
        write(gz, TranscodingStreams.TOKEN_END)
        flush(gz)                           # finalize gzip member + trailer
        close(tmpio)
        chmod(tmp, 0o644)                   # mktemp creates 0o600
        mv(tmp, path; force = true)         # same-dir rename: atomic
    catch
        close(tmpio)
        rm(tmp; force = true)
        rethrow()
    end
    return path
end

"""
Flush the filesystem to a gzip-compressed tarball at `path`. Atomic: a
failure mid-write leaves any existing archive at `path` untouched, so
seeding `from = path` (read-modify-write) cannot destroy the source.
"""
write_tarball_gz(fs::InMemoryFileSystem, path::AbstractString) =
    _atomic_gz(gz -> write_tarball(fs, gz), path)

# ---- ergonomic "close => write" entry point --------------------------------

"""
    open_tarball_gz(f, path; from = nothing)

Run `f(fs)` on a writable filesystem, then flush it to `path`. Pass
`from = "in.tar.gz"` to seed from an existing archive; `from == path` is
fine — the source is fully loaded up front and the write is atomic.
The flush happens only if `f` returns normally.
"""
function open_tarball_gz(f, path::AbstractString;
                         from::Union{Nothing, AbstractString} = nothing)
    fs = from === nothing ? InMemoryFileSystem() :
                            InMemoryFileSystem(from)
    f(fs)
    write_tarball_gz(fs, path)
    return fs
end

export open_tarball_gz

# ---- alternative writer: Tar.jl via a temp dir ------------------------------

# Costs disk I/O, but handles arbitrary path lengths (PAX/GNU long names)
# and emits explicit directory entries — relevant if the archive is later
# consumed by `tar -x`, docker, etc.

"""
    write_tarball_gz_viatar(fs, path)

Flush to `path` via a temporary directory and `Tar.create`: slower than
[`write_tarball_gz`](@ref), but supports arbitrarily long member paths and
emits explicit directory entries. Same atomic temp-file + rename discipline.
"""
function write_tarball_gz_viatar(fs::InMemoryFileSystem, path::AbstractString)
    mktempdir() do dir
        for p in keys(fs.d)
            _check_path(p)                  # defends joinpath below
            dst = joinpath(dir, p)
            mkpath(dirname(dst))
            open(io -> _write_filedata(fs, io, fs.d[p]), dst, "w")
        end
        _atomic_gz(gz -> Tar.create(dir, gz), path)  # handle left open
    end
    return path
end


end
