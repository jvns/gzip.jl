using Base.Test
include("gzip.jl")

let
  # TODO: I don't like this dependence on the file
  file = IOBuffer([0b11111010, 0b11110100])
  bs = BitStream(file)
  @test read_bits_inv(bs, 5) == 0b11010
  @test read_bits_inv(bs, 5) == 0b00111
  @test read_bits_inv(bs, 4) == 0b1101
end

let 
    file = IOBuffer([0xff for i=1:100])
    bs = BitStream(file)
    @test read_bits_inv(bs, 32) == 2^32 - 1
end

let
    flags = 0b10001
    @test has_ext(flags)
    @test !has_crc(flags)
    @test !has_extra(flags)
    @test !has_name(flags)
    @test has_comment(flags)
end

let
  file = open("test/gunzip.c.gz", "r")
  h = read(file, GzipHeader)
  close(file)
end

let
  file = open("test/gunzip.c.gz", "r")
  h = read(file, GzipMetadata)
  @test h.fname == "gunzip.c"
  close(file)
end

let
  file = open("test/gunzip.c.gz", "r")
  h = read(file, GzipMetadata)
  bs = BitStream(file)
  bf = read(bs, BlockFormat)
  @test bf.last
  @test bf.block_type == [0,1]
  close(file)
end

let
  file = open("test/gunzip.c.gz", "r")
  read(file, GzipMetadata)
  bs = BitStream(file)
  bf = read(bs, BlockFormat)

  # These are the real values!
  huff_head = read(bs, HuffmanHeader)
  @test huff_head.hlit == 23
  @test huff_head.hdist == 27
  @test huff_head.hclen == 8
  close(file)
end


let
    file = open("test/gunzip.c.gz", "r")
    read(file, GzipMetadata)
    bs = BitStream(file)
    bf = read(bs, BlockFormat)

    head = read(bs, HuffmanHeader)
    hclens = [read_bits_inv(bs, 3) for i=1:(head.hclen+4)]
  
    labels = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    code_table = create_code_table(hclens, labels)
    tree = create_huffman_tree(code_table)

    for (label, code) = code_table
         assert(tree[code] == label)
    end
end

let 
    file = open("test/gunzip.c.gz")
    read(file, GzipMetadata)
    bs = BitStream(file)
    read(bs, BlockFormat)
    head = read(bs, HuffmanHeader)
    tree = read_first_tree(bs, head.hclen)
end

let 
    code_f = open("test/code_lengths.txt")
    real_code_strs = split(readall(code_f), '\n')
    real_codes = [convert(Uint8, int(x)) for x=real_code_strs[1:308]]
    file = open("test/gunzip.c.gz")
    read(file, GzipMetadata)
    bs = BitStream(file)
    read(bs, BlockFormat)
    head = read(bs, HuffmanHeader)
    tree = read_first_tree(bs, head.hclen)
    codes = read_second_tree_codes(bs, head, tree)
    @test codes == real_codes
end

let
    @test copy_text!([1,2,3], 2, 4) == [1,2,3,2,3,2,3]
    @test copy_text!([1,2,3], 3, 3) == [1,2,3,1,2,3]
end

let 
    file = open("test/gunzip.c.gz")
    output_file = open("test/gunzip.c")
    bs = BitStream(file)
    read(file, GzipMetadata)
    read(bs, BlockFormat)
    decoded_text = convert(ASCIIString, inflate_block!(Uint8[], bs))
    actual_text = readall(output_file)
    @test actual_text == decoded_text
end

let
    codes = [3,3,3,4,4,4,6,6]
    code_table = create_code_table(codes, [1:length(codes)])
    tree = create_huffman_tree(code_table)
    for (label, code) = code_table
         @test tree[code] == label
    end
end

let 
    file = open("test/american-english.gz")
    output_file = open("test/american-english")
    buf = IOBuffer()
    inflate(file, buf)
    seek(buf, 0)
    decoded_text = readall(buf)
    actual_text = readall(output_file)
    @test actual_text == decoded_text
end