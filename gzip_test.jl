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
