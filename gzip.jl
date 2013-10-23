type BitStream
    stream::IO
    bv::BitVector
end
BitStream(io::IO) = BitStream(io, BitVector(0))

typealias GzipFlags Uint8

type GzipHeader
  id::Vector{Uint8} # length 2
  compression_method::Uint8
  flags::GzipFlags
  mtime::Vector{Uint8} # length 4
  extra_flags::Uint8
  os::Uint8
end

type GzipMetadata
  header::GzipHeader
  xlen::Uint16
  extra::ASCIIString
  fname::ASCIIString
  fcomment::ASCIIString
  crc16::Uint16
end

type BlockFormat
  last::Bool
  block_type::BitVector # length 2
end

type HuffmanHeader
    hlit::Uint8
    hdist::Uint8
    hclen::Uint8
end

Base.read(bs::BitStream, ::Type{HuffmanHeader}) = HuffmanHeader(
    convert(Uint8, read_bits_inv(bs, 5)), 
    convert(Uint8, read_bits_inv(bs, 5)), 
    convert(Uint8, read_bits_inv(bs, 4)))



has_ext(flags::GzipFlags)     = bool(0x01 & flags)
has_crc(flags::GzipFlags)     = bool(0x02 & flags)
has_extra(flags::GzipFlags)   = bool(0x04 & flags)
has_name(flags::GzipFlags)    = bool(0x08 & flags)
has_comment(flags::GzipFlags) = bool(0x10 & flags)

function Base.read(bs::BitStream, ::Type{BlockFormat})
    bits = read_bits(bs, 3)
    return BlockFormat(bits[1], bits[2:3])
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

function Base.read(file::IO, ::Type{GzipMetadata})
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
    return GzipMetadata(header, xlen, extra, fname, fcomment, crc16)
end


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

function read_bits_inv(bs::BitStream, n)
    bits = reverse!(read_bits(bs, n))
    return make_int(bits)
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

function create_code_table(hclens, labels)
    nonzero_indices = hclens .!= 0x00
    labels = labels[1:length(hclens)]
    hclens = hclens[nonzero_indices]
    labels = labels[nonzero_indices]

    sorted_pairs = sort([x for x=zip(hclens, labels)])
    answer = Array(Uint16, length(hclens))
    prev_code_len = 0
    for (i, (code_len, label)) = enumerate(sorted_pairs)
        if i == 1
            answer[i] = 0
        elseif code_len == prev_code_len
            answer[i] = answer[i-1] + 1
        else
            answer[i] = (answer[i-1] + 1) << (code_len - prev_code_len)
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
Base.getindex(node::InternalNode, dir::Integer) = bool(dir) ? node.one : node.zero
function Base.getindex(node::InternalNode, code)
    for (i, bit) = enumerate(code)
        node = node[bit]
    end
    return node.label
end

function add_item!(root::InternalNode, label, code::BitVector)
    if length(code) == 1
        root[code[1]] = LeafNode(label)
        return
    end
    if root[code[1]] != EmptyNode()
        add_item!(root[code[1]], label, code[2:end]) 
        return
    end
    child = InternalNode()
    root[code[1]] = child
    add_item!(child, label, code[2:end])
    
end
function create_huffman_tree(code_table)
    root = InternalNode()
    for (label, codes) = code_table
        add_item!(root, label, codes)
    end
    return root
end

function read_first_tree(bs::BitStream, hclen)
    hclens = [read_bits_inv(bs, 3) for i=1:(hclen+4)]
    # List of labels from the gzip spec. I know right.
    labels = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    code_table = create_code_table(hclens, labels)
    first_tree = create_huffman_tree(code_table)
    return first_tree
end

typealias HuffmanTree InternalNode

function read_huffman_bits(bs::BitStream, tree::HuffmanTree)
    node = tree
    while typeof(node) != LeafNode
        bit = read_bits(bs, 1)[1]
        node = node[bit]
    end
    return node.label
end

function read_second_tree_codes(bs::BitStream, head::HuffmanHeader, tree::HuffmanTree)
    n_to_read = head.hlit + head.hdist + 258
    vals = Array(Uint8, n_to_read)
    i = 1
    while i <= n_to_read
        code_len = read_huffman_bits(bs, tree)
        if code_len == 16
            n_repeat = read_bits_inv(bs, 2) + 3
            vals[i:i+n_repeat-1] = vals[i-1]
            i += n_repeat
        elseif code_len == 17
            n_zeros = read_bits_inv(bs, 3) + 3
            vals[i:i+n_zeros-1] = 0
            i += n_zeros
        elseif code_len == 18
            n_zeros = read_bits_inv(bs, 7) + 11
            vals[i:i+n_zeros-1] = 0
            i += n_zeros
        else
            vals[i] = code_len
            i += 1
        end
    end
    return vals
end

function read_distance_code(bs::BitStream, distance_tree)
    extra_dist_addend = [
        4, 6, 8, 12, 16, 24, 32, 48,
        64, 96, 128, 192, 256, 384,
        512, 768, 1024, 1536, 2048,
        3072, 4096, 6144, 8192,
        12288, 16384, 24576
    ]
    distance = read_huffman_bits(bs, distance_tree)
    if distance > 3
      extra_dist = read_bits_inv(bs, div(distance - 2, 2))
      distance = extra_dist + extra_dist_addend[ distance - 4 + 1]
    end
    return distance + 1
end

function read_length_code(bs::BitStream, length_code)
    extra_length_addend = [
        11, 13, 15, 17, 19, 23, 27,
        31, 35, 43, 51, 59, 67, 83,
        99, 115, 131, 163, 195, 227
    ]
    len = 0
    if (length_code < 265)
        return length_code - 254
    else
        extra_bits = read_bits_inv(bs, div(length_code - 261,  4))
        return  extra_bits + extra_length_addend[length_code - 265 + 1]
    end
end

function copy_text!(decoded_text, distance, len)
    j = length(decoded_text) - distance + 1
    i = length(decoded_text) + 1
    append!(decoded_text, zeros(Uint8, len))
    while len > 0
        decoded_text[i] = decoded_text[j]
        i += 1
        j += 1
        len -= 1
    end
    return decoded_text
end

function inflate(file::IO, out::IO=STDOUT)
    read(file, GzipMetadata) # Ignore headers
    bs = BitStream(file)

    decoded_text = Uint8[]
    while true
        bf = read(bs, BlockFormat)
        if bf.block_type == [false, true]
            inflate_block!(decoded_text, bs)
        else
            println("OH NO!")
            break
        end
        if bf.last
            break
        end
    end
    write(out, decoded_text)
end

function inflate_block!(decoded_text, bs::BitStream)
    head = read(bs, HuffmanHeader)
    
    first_tree = read_first_tree(bs, head.hclen)
    codes = read_second_tree_codes(bs, head, first_tree)
    
    literal_codes = codes[1:257 + head.hlit]
    lit_code_table = create_code_table(literal_codes, [0:length(literal_codes)-1])
    literal_tree = create_huffman_tree(lit_code_table)
    
    distance_codes = codes[end-head.hdist:end]
    dist_code_table = create_code_table(distance_codes, [0:length(distance_codes)-1])
    distance_tree = create_huffman_tree(dist_code_table)
    
    return inflate_block!(decoded_text, bs, literal_tree, distance_tree)
end

function inflate_block!(decoded_text, bs::BitStream, literal_tree::HuffmanTree, distance_tree::HuffmanTree)
    while true
        code = read_huffman_bits(bs, literal_tree)
        if code == 256 # Stop code; end of block
            break
        end
        if code <= 255 # ASCII character
            append!(decoded_text, [convert(Uint8, code)])
        else # Pointer to previous text
            len = read_length_code(bs, code)
            distance = read_distance_code(bs, distance_tree)
            copy_text!(decoded_text, distance, len)
        end
    end
    return decoded_text
end

display_ascii(arr) = ASCIIString(convert(Vector{Uint8}, arr))
