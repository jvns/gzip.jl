type BitStream
    stream::IOStream
    bv::BitVector
end

typealias GzipFlags Uint8

type GzipHeader
  id::Vector{Uint8} # length 2
  compression_method::Uint8
  flags::GzipFlags
  mtime::Vector{Uint8} # length 4
  extra_flags::Uint8
  os::Uint8
end

type HuffmanHeader
    hlit::Uint8
    hdist::Uint8
    hclen::Uint8
end

Base.read(bs::BitStream, ::Type{HuffmanHeader}) = HuffmanHeader(
    read_gzip_byte(bs, 5), 
    read_gzip_byte(bs, 5), 
    read_gzip_byte(bs, 4))

type BlockFormat
  last::Bool
  block_type::BitArray{1} # length 2
end

has_ext(flags::GzipFlags)     = bool(0x01 & flags)
has_crc(flags::GzipFlags)     = bool(0x02 & flags)
has_extra(flags::GzipFlags)   = bool(0x04 & flags)
has_name(flags::GzipFlags)    = bool(0x08 & flags)
has_comment(flags::GzipFlags) = bool(0x10 & flags)

function Base.read(bs::BitStream, ::Type{BlockFormat})
    bits = read_bits(bs, 3)
    return BlockFormat(bits[1], bits[2:3])
end

type GzipFile
  header::GzipHeader
  xlen::Uint16
  extra::ASCIIString
  fname::ASCIIString
  fcomment::ASCIIString
  crc16::Uint16
end

function Base.read(file::IO, ::Type{GzipHeader})
    id = readbytes(file, 2)
    compression_method = read(file, Uint8)
    flags = read(file, GzipFlags)
    mtime = readbytes(file, 4)
    extra_flags = read(file, Uint8)
    os = read(file, Uint8)
    assert(id == [0x1f, 0x8b], "Gzip magic bytes not present")
    assert(compression_method == 8, "Unknown compression method")
    return GzipHeader(id, compression_method, flags, mtime, extra_flags, os)
end

function Base.read(file::IO, ::Type{GzipFile})
    header = read(file, GzipHeader)
    xlen::Uint16 = 0
    extra::ASCIIString = ""
    fname::ASCIIString = ""
    fcomment::ASCIIString = ""
    crc16::Uint16 = 0
    # TODO: There are only 4 checks here. WHY?!?? Is this a bug?
    if has_extra(header.flags)
        xlen = read(file, Uint16)
        extra = ASCIIString(readbytes(file, xlen))
    end
    if has_name(header.flags)
        fname = ASCIIString(readuntil(file, 0x00)[1:end-1])
    end
    if has_comment(header.flags)
        fname = ASCIIString(readuntil(file, 0x00)[1:end-1])
    end
    if has_crc(header.flags)
        crc16 = read(file, Uint16)
    end
    return GzipFile(header, xlen, extra, fname, fcomment, crc16)
end

BitStream(io::IOStream) = BitStream(io, BitVector(0))

function make_bitvector(n::Uint8)
    bits = BitVector(8)
    for i=1:8
        bits[i] = n & 0x1
        n >>= 1
    end
    return bits
end

function read_bits(stream::BitStream, n)
    cached_bits = stream.bv
    while n > length(cached_bits)
        byte = read(stream.stream, Uint8)
        new_bits = make_bitvector(byte)
        cached_bits = vcat(cached_bits, new_bits)
    end
    stream.bv = cached_bits[n+1:end]
    return cached_bits[1:n]
end

function read_gzip_byte(bs::BitStream, n)
    bits = reverse!(read_bits(bs, n))
    x::Uint8 = make_int(bits)
    return x
end

function make_int(bv::BitVector)
    num = 0x00
    for i=1:length(bv)
        num = (num << 1) + bv[i]
    end
    return num
end

function read_huffman_stream(stream)
    n_lit  = make_int(read_bits(stream, 5))
    n_dist = make_int(read_bits(stream, 5))
    n_len  = make_int(read_bits(stream, 4))
    return (n_lit, n_dist, n_len)
end

function create_code_table(hclens)
    # List of labels from the gzip spec. I know right.
    labels = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    sorted_pairs = sort([x for x=zip(hclens, labels)])
    answer = Array(Uint16, length(hclens))
    prev_code_len = 0
    for (i, (code_len, label)) = enumerate(sorted_pairs)
        if i == 1
            answer[i] = 0
        elseif code_len == prev_code_len
            answer[i] = answer[i-1] + 1
        else
            answer[i] = (answer[i-1] + 1) << 1
        end
        prev_code_len = code_len
    end
    # Sorry =(
    code_table = [(label, make_bit_vector(ans, code_len)) for (ans, (code_len, label)) = zip(answer, sorted_pairs)]
    return code_table
end

function make_bit_vector(n::Any, len::Any)
    vec = BitVector(int(len))
    for i=1:len
        vec[len - i + 1] = n & 1
        n >>= 1
    end
    return vec
end
#read_huffman_stream(file)

abstract Node
type InternalNode <: Node
    one::Node
    zero::Node
end
type EmptyNode <:Node end
type LeafNode <:Node
    label
end

InternalNode() = InternalNode(EmptyNode(), EmptyNode())
function Base.setindex!(node::InternalNode, value::Node, dir::Bool)
    if dir == 0
        node.zero = value
    else
        node.one = value
    end
end
Base.getindex(node::InternalNode, dir::Bool) = dir ? node.one : node.zero
function Base.getindex(node::InternalNode, code::BitArray)
    for (i, bit) = enumerate(code)
        node = node[bit]
    end
    return node.label
end
