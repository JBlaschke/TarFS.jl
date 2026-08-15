using TarFS
using Test

# ---- round-trip smoke test ---------------------------------------------------

"""
Write -> flush -> re-read through the existing read path (i.e. our headers
must parse via Tar.read_tarball); also checks the prefix-split path and a
seeded overwrite onto the same file. Returns `true` or throws.
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
        fs = create_inmemory_filesystem(p)
        for (k, v) in payload
            readfile(fs, k) == v || error("round-trip mismatch: $k")
        end
        # read-modify-write, seeded from the archive we just wrote
        open_tarball_gz(p; from = p) do fs2
            writefile(fs2, "a.txt", "hello, again")
        end
        fs3 = create_inmemory_filesystem(p)
        readfile(fs3, "a.txt") == "hello, again"                    || error("overwrite failed")
        readfile(fs3, "data/p175.csv") == payload["data/p175.csv"]  || error("carry-over failed")
        readfile(fs3, long) == "deep"                               || error("prefix-split entry failed")
    end
    return true
end

@testset "TarFS.jl" begin
    @test selftest()
end
