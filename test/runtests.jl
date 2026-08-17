# test/runtests.jl — TarFS.jl
#
# Run via the package manager:   pkg> test
# or:  julia --project=. -e 'using Pkg; Pkg.test()'
# For fast REPL iteration, use TestEnv.jl:
#   julia> using TestEnv; TestEnv.activate(); include("test/runtests.jl")

using Test
using TarFS
using Tar, CodecZlib, TranscodingStreams
using Random
using Aqua

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const NAME_100   = "m"^100                               # exactly fills the name field
const LONG_SPLIT = "p" * "x"^60 * "/" * "y"^60 * ".txt"  # 126 B -> needs prefix split

const TREE = Dict{String, String}(
    "a.txt"            => "hello",
    "data/p175.csv"    => "x,y\n1,2\n3,4\n",
    "data/empty.bin"   => "",
    "bytes.bin"        => String(UInt8[0x00, 0xff, 0x10, 0x80, 0x0a]),
    "データ/日本語.txt"   => "unicode ✓ content",
    NAME_100           => "at the boundary",
    LONG_SPLIT         => "split me",
)

# Reference archive built by Tar.jl's own writer from a real directory —
# the independent producer for testing our read path.
function make_reference_targz(tree::Dict{String, String}, dest::AbstractString)
    mktempdir() do src
        for (p, c) in tree
            f = joinpath(src, p)
            mkpath(dirname(f))
            write(f, c)
        end
        open(dest, "w") do out
            gz = GzipCompressorStream(out)
            Tar.create(src, gz)
            write(gz, TranscodingStreams.TOKEN_END)
            flush(gz)
        end
    end
    return dest
end

# ---------------------------------------------------------------------------

@testset "TarFS.jl" begin

@testset "Aqua.jl quality checks" begin
    Aqua.test_all(TarFS)
end

@testset "read path against a Tar.create-produced archive" begin
    mktempdir() do tmp
        ref = make_reference_targz(TREE, joinpath(tmp, "ref.tar.gz"))
        fs = TarFS.InMemoryFileSystem(ref)
        @test Set(keys(fs.d)) == Set(keys(TREE))          # dirs not indexed, files all there
        @test all(f -> f.str === nothing, values(fs.d))   # nothing materialized yet
        s1 = TarFS.readfile(fs, "a.txt")
        @test s1 == TREE["a.txt"]
        @test fs.d["a.txt"].str === s1                    # cached on first read
        @test TarFS.readfile(fs, "a.txt") === s1          # second read returns the cache
        for (p, c) in TREE
            @test TarFS.readfile(fs, p) == c
        end
        @test_throws KeyError TarFS.readfile(fs, "does/not/exist")
    end
end

@testset "staging: writefile / deletefile" begin
    fs = TarFS.InMemoryFileSystem()
    @test TarFS.writefile(fs, "a.txt", "v1") == "a.txt"
    @test TarFS.readfile(fs, "a.txt") == "v1"
    TarFS.writefile(fs, "a.txt", "v2")                    # overwrite
    @test TarFS.readfile(fs, "a.txt") == "v2"

    v = UInt8[1, 2, 3]
    TarFS.writefile(fs, "b.bin", v)
    @test v == UInt8[1, 2, 3]                             # caller's buffer not stolen
    v[1] = 0x09                                           # mutate afterwards...
    @test codeunits(TarFS.readfile(fs, "b.bin")) == UInt8[1, 2, 3]   # ...stored copy unaffected

    TarFS.writefile(fs, "s.txt", SubString("xhellox", 2, 6)) # AbstractString content
    @test TarFS.readfile(fs, "s.txt") == "hello"
    TarFS.writefile(fs, "w.bin", @view v[2:3])            # AbstractVector{UInt8} content
    @test codeunits(TarFS.readfile(fs, "w.bin")) == UInt8[2, 3]

    @test TarFS.deletefile(fs, "b.bin") === nothing
    @test !haskey(fs.d, "b.bin")
    @test TarFS.deletefile(fs, "ghost") === nothing       # delete! no-op
end

@testset "staging: path validation" begin
    fs = TarFS.InMemoryFileSystem()
    for bad in ["", "/abs.txt", "a/../b", "..", ".", "./a", "a//b", "a/", "a\0b"]
        @test_throws ArgumentError TarFS.writefile(fs, bad, "x")
    end
    for good in ["a", "a.b", "a/b/c.txt", "weird name.txt", "-dash", "日本語"]
        @test TarFS.writefile(fs, good, "x") == good
    end
end

@testset "internals: _split_path" begin
    @test TarFS._split_path("short.txt") == ("short.txt", "")
    @test TarFS._split_path(NAME_100) == (NAME_100, "")   # exactly 100 B: no split
    n, p = TarFS._split_path(LONG_SPLIT)
    @test p * "/" * n == LONG_SPLIT
    @test sizeof(n) <= 100 && sizeof(p) <= 155
    upath = "α"^40 * "/" * "β"^40 * ".txt"                # 165 B, multibyte
    n, p = TarFS._split_path(upath)
    @test p * "/" * n == upath && isvalid(p) && isvalid(n)
    @test TarFS._split_path("q"^150 * "/leaf") == ("leaf", "q"^150)  # prefix side fits
    @test_throws ErrorException TarFS._split_path("q"^150)           # no slash at all
    @test_throws ErrorException TarFS._split_path("a/" * "q"^150)    # name side too long
end

@testset "internals: _ustar_header" begin
    h = TarFS._ustar_header("data/x.csv", 5)
    @test length(h) == 512
    @test h[1:10] == codeunits("data/x.csv") && h[11] == 0x00     # name @ 0
    @test parse(Int, String(h[101:107]); base = 8) == 0o644       # mode @ 100
    @test parse(Int, String(h[125:135]); base = 8) == 5           # size @ 124
    @test h[136] == 0x00                                          # NUL-terminated
    @test h[157] == UInt8('0')                                    # typeflag @ 156
    @test h[258:262] == codeunits("ustar") && h[263] == 0x00      # magic @ 257
    @test h[264] == UInt8('0') && h[265] == UInt8('0')            # version "00"

    # checksum: recompute over the header with the field blanked to spaces
    stored = parse(Int, String(h[149:154]); base = 8)
    hs = copy(h); hs[149:156] .= UInt8(' ')
    @test stored == sum(hs)
    @test h[155] == 0x00 && h[156] == UInt8(' ')                  # "dddddd\0 "

    # prefix/name land in their fields for a split path
    h2 = TarFS._ustar_header(LONG_SPLIT, 0)
    n, p = TarFS._split_path(LONG_SPLIT)
    @test h2[1:sizeof(n)] == codeunits(n)
    @test h2[346:345+sizeof(p)] == codeunits(p)                   # prefix @ 345

    # size limits: 11 octal digits => 8 GiB cap
    @test_throws ErrorException TarFS._ustar_header("big", 8^11)
    hmax = TarFS._ustar_header("ok", 8^11 - 1)
    @test parse(Int, String(hmax[125:135]); base = 8) == 8^11 - 1
end

@testset "write_tarball: structure and Tar.jl cross-validation" begin
    fs = TarFS.InMemoryFileSystem()
    for (k, v) in TREE
        TarFS.writefile(fs, k, v)
    end
    b1 = take!(TarFS.write_tarball(fs, IOBuffer()))
    b2 = take!(TarFS.write_tarball(fs, IOBuffer()))
    @test b1 == b2                                        # deterministic bytes
    @test length(b1) % 512 == 0
    @test all(==(0x00), b1[end-1023:end])                 # two zero EOF blocks

    headers = Tar.list(IOBuffer(b1))                      # strict header validation
    @test length(headers) == length(TREE)
    @test issorted([h.path for h in headers])
    hd = Dict(h.path => h for h in headers)
    for (p, c) in TREE
        @test haskey(hd, p)
        @test hd[p].type == :file
        @test hd[p].size == sizeof(c)
        @test hd[p].mode == 0o644
    end

    mktempdir() do tmp
        out = joinpath(tmp, "extracted")
        Tar.extract(IOBuffer(b1), out)                    # Tar.jl's own extractor
        for (p, c) in TREE
            @test read(joinpath(out, p), String) == c
        end
    end
end

@testset "empty filesystem" begin
    fs = TarFS.InMemoryFileSystem()
    b = take!(TarFS.write_tarball(fs, IOBuffer()))
    @test length(b) == 1024 && all(==(0x00), b)
    @test isempty(Tar.list(IOBuffer(b)))
    mktempdir() do tmp
        p = joinpath(tmp, "empty.tar.gz")
        TarFS.write_tarball_gz(fs, p)
        @test isempty(TarFS.InMemoryFileSystem(p).d)
    end
end

@testset "write_tarball_gz: round-trip, streaming, determinism" begin
    mktempdir() do tmp
        p1 = joinpath(tmp, "one.tar.gz")
        TarFS.open_tarball_gz(p1) do fs
            for (k, v) in TREE
                TarFS.writefile(fs, k, v)
            end
        end
        fsr = TarFS.InMemoryFileSystem(p1)
        for (k, v) in TREE
            @test TarFS.readfile(fsr, k) == v
        end

        # flushing a seeded fs streams source-backed entries without caching...
        fs2 = TarFS.InMemoryFileSystem(p1)
        p2 = joinpath(tmp, "two.tar.gz")
        TarFS.write_tarball_gz(fs2, p2)
        @test all(f -> f.str === nothing, values(fs2.d))
        # ...and the fs stays fully readable afterwards (readfile re-seeks)
        @test TarFS.readfile(fs2, "a.txt") == TREE["a.txt"]
        fs3 = TarFS.InMemoryFileSystem(p2)
        for (k, v) in TREE
            @test TarFS.readfile(fs3, k) == v
        end

        # same content + same zlib => identical bytes on this machine
        p3 = joinpath(tmp, "three.tar.gz")
        TarFS.write_tarball_gz(fs2, p3)
        @test read(p2) == read(p3)

        # no temp-file litter after successful writes
        @test Set(readdir(tmp)) == Set(["one.tar.gz", "two.tar.gz", "three.tar.gz"])
    end
end

@testset "atomicity: mid-write failure preserves the target" begin
    mktempdir() do tmp
        p = joinpath(tmp, "t.tar.gz")
        TarFS.open_tarball_gz(p) do fs
            TarFS.writefile(fs, "a.txt", "original")
        end
        fs = TarFS.InMemoryFileSystem(p)
        # Poison an entry that (a) sorts last and (b) fails header creation,
        # so the failure happens mid-stream, after "a.txt" already went out.
        fs.d["zzz" * "q"^200] = TarFS.InMemoryFile(3, -1, "abc")
        @test_throws ErrorException TarFS.write_tarball_gz(fs, p)
        @test Set(readdir(tmp)) == Set(["t.tar.gz"])      # temp file cleaned up
        @test TarFS.readfile(TarFS.InMemoryFileSystem(p), "a.txt") == "original"
    end
end

@testset "open_tarball_gz: block semantics and read-modify-write" begin
    mktempdir() do tmp
        # exception in the block => no archive is created at all
        p = joinpath(tmp, "never.tar.gz")
        @test_throws ErrorException TarFS.open_tarball_gz(p) do fs
            TarFS.writefile(fs, "x.txt", "y")
            error("boom")
        end
        @test !isfile(p)

        # seeded read-modify-write onto the same path
        q = joinpath(tmp, "rmw.tar.gz")
        TarFS.open_tarball_gz(q) do fs
            TarFS.writefile(fs, "a.txt", "v1")
            TarFS.writefile(fs, "keep.txt", "kept")
        end
        TarFS.open_tarball_gz(q; from = q) do fs
            @test TarFS.readfile(fs, "a.txt") == "v1"
            TarFS.writefile(fs, "a.txt", "v2")
            TarFS.deletefile(fs, "keep.txt")
            TarFS.writefile(fs, "new.txt", "n")
        end
        fs = TarFS.InMemoryFileSystem(q)
        @test TarFS.readfile(fs, "a.txt") == "v2"
        @test TarFS.readfile(fs, "new.txt") == "n"
        @test !haskey(fs.d, "keep.txt")

        # ...and a failing block leaves the seeded original untouched
        @test_throws ErrorException TarFS.open_tarball_gz(q; from = q) do fs
            TarFS.writefile(fs, "a.txt", "SHOULD NOT LAND")
            error("boom")
        end
        @test TarFS.readfile(TarFS.InMemoryFileSystem(q), "a.txt") == "v2"
    end
end

@testset "write_tarball_gz_viatar: directory entries and long paths" begin
    mktempdir() do tmp
        fs = TarFS.InMemoryFileSystem()
        for (k, v) in TREE
            TarFS.writefile(fs, k, v)
        end
        longpath = "L/" * join(fill("s"^40, 7), "/") * "/leaf.txt"  # ~297 B: unsplittable
        TarFS.writefile(fs, longpath, "leafdata")

        # the in-memory USTAR writer must refuse it...
        @test_throws ErrorException TarFS.write_tarball_gz(fs, joinpath(tmp, "mem.tar.gz"))

        # ...the Tar.create-backed writer handles it (extended headers)
        pv = joinpath(tmp, "via.tar.gz")
        TarFS.write_tarball_gz_viatar(fs, pv)
        fsr = TarFS.InMemoryFileSystem(pv)
        @test TarFS.readfile(fsr, longpath) == "leafdata"
        for (k, v) in TREE
            @test TarFS.readfile(fsr, k) == v
        end
        headers = open(pv) do f
            Tar.list(GzipDecompressorStream(f))
        end
        @test any(h -> h.type == :directory, headers)     # explicit dir entries
        @test Set(readdir(tmp)) == Set(["via.tar.gz"])    # failed write left no litter
    end
end

@testset "large content streams across buffer boundaries" begin
    n = 3 * Tar.DEFAULT_BUFFER_SIZE + 17
    big = String(rand(MersenneTwister(42), UInt8, n))
    mktempdir() do tmp
        p1 = joinpath(tmp, "big.tar.gz")
        TarFS.open_tarball_gz(p1) do fs
            TarFS.writefile(fs, "big.bin", big)
        end
        fs = TarFS.InMemoryFileSystem(p1)
        @test sizeof(TarFS.readfile(fs, "big.bin")) == n
        @test TarFS.readfile(fs, "big.bin") == big

        # seeded flush: streamed via read_data + buf, never materialized
        fs2 = TarFS.InMemoryFileSystem(p1)
        p2 = joinpath(tmp, "big2.tar.gz")
        TarFS.write_tarball_gz(fs2, p2)
        @test fs2.d["big.bin"].str === nothing
        @test TarFS.readfile(TarFS.InMemoryFileSystem(p2), "big.bin") == big
    end
end

if Sys.which("tar") !== nothing
    @testset "system tar can list our output" begin
        mktempdir() do tmp
            p = joinpath(tmp, "sys.tar.gz")
            TarFS.open_tarball_gz(p) do fs
                TarFS.writefile(fs, "data/x.csv", "1,2\n")
                TarFS.writefile(fs, "a.txt", "hi")
            end
            listing = read(`$(Sys.which("tar")) -tzf $p`, String)
            @test occursin("data/x.csv", listing)
            @test occursin("a.txt", listing)
        end
    end
end


# ---- round-trip smoke test ---------------------------------------------------

"""
Write -> flush -> re-read through the existing read path (i.e. our headers must
parse via Tar.read_tarball); also checks the prefix-split path and a seeded
overwrite onto the same file. Returns `true` or throws.
"""
function selftest()
    long = "p" * "x"^60 * "/" * "y"^60 * ".txt"   # 126 B: exercises prefix split
    payload = Dict(
        "a.txt"          => "hello",
        "data/p175.csv"  => "x,y\n1,2\n",
        "data/empty.bin" => "",
        "bytes.bin"      => String(UInt8[0x00, 0xff, 0x10, 0x80]),
        long             => "deep",
    )
    mktempdir() do dir
        p = joinpath(dir, "t.tar.gz")
        open_tarball_gz(p) do fs
            for (k, v) in payload
                writefile(fs, k, v)
            end
        end
        fs = InMemoryFileSystem(p)
        for (k, v) in payload
            readfile(fs, k) == v || error("round-trip mismatch: $k")
        end
        # read-modify-write, seeded from the archive we just wrote
        open_tarball_gz(p; from = p) do fs2
            writefile(fs2, "a.txt", "hello, again")
        end
        fs3 = InMemoryFileSystem(p)
        readfile(fs3, "a.txt") == "hello, again"                    || error("overwrite failed")
        readfile(fs3, "data/p175.csv") == payload["data/p175.csv"]  || error("carry-over failed")
        readfile(fs3, long) == "deep"                               || error("prefix-split entry failed")
    end
    return true
end

@testset "built-in smoke test still passes" begin
    @test selftest()
end

end # @testset "TarFS.jl"
