using Base.Test
include("gzip.jl")

let
  file = open("gunzip.c.gz", "r")
  bs = BitStream(file)
  @test read_gzip_byte(bs, 5) == 31
  @test read_gzip_byte(bs, 5) == 24
  @test read_gzip_byte(bs, 4) == 2
  close(file)
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
  file = open("gunzip.c.gz", "r")
  h = read(file, GzipHeader)
  close(file)
end

let
  file = open("gunzip.c.gz", "r")
  h = read(file, GzipFile)
  @test h.fname == "gunzip.c"
  close(file)
end

let
  file = open("gunzip.c.gz", "r")
  h = read(file, GzipFile)
  bs = BitStream(file)
  bf = read(bs, BlockFormat)
  @test bf.last
  @test bf.block_type == [0,1]
  close(file)
end

let
  file = open("gunzip.c.gz", "r")
  read(file, GzipFile)
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
    file = open("gunzip.c.gz", "r")
    read(file, GzipFile)
    bs = BitStream(file)
    bf = read(bs, BlockFormat)

    head = read(bs, HuffmanHeader)
    hclens = [read_gzip_byte(bs, 3) for i=1:(head.hclen+4)]
  
    code_table = create_code_table(hclens)
    tree = create_huffman_tree(code_table)

    for (label, code) = code_table
         assert(tree[code] == label)
    end
end

let 
    file = open("/home/bork/work/hackerschool/gzip.jl/gunzip.c.gz")
    read(file, GzipFile)
    bs = BitStream(file)
    read(bs, BlockFormat)
    head = read(bs, HuffmanHeader)
    tree = read_first_tree(bs, head.hclen)
end