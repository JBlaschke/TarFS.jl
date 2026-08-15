module TarFS

using Tar, CodecZlib, TranscodingStreams


mutable struct InMemoryFile
    size::Int
    pos::Int
    str::Union{Nothing, String}
end


mutable struct InMemoryFileSystem
    d::Dict{String, InMemoryFile}
    tarball_io::IOBuffer
    out_io::IOBuffer
    buf::Vector{UInt8}
end


function readfile(ref::InMemoryFileSystem, path::AbstractString)
    file = ref.d[path]
    file.str === nothing || return file.str
    seek(ref.tarball_io, file.pos)
    Tar.read_data(ref.tarball_io, ref.out_io; size=file.size, buf=ref.buf)
    file.str = String(take!(ref.out_io))
end


const true_predicate = _ -> true


function create_inmemory_filesystem(path::AbstractString)
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

end
