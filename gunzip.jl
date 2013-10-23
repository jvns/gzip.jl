include("gzip.jl")

f = open(ARGS[1])
read(f, GzipMetadata) # Ignore headers
bs = BitStream(f)

while true
    bf = read(bs, BlockFormat)
    if bf.block_type == [false, true]
	    decoded_text = inflate_compressed_block(bs)
	    print(display_ascii(decoded_text))
	else:
		println("OH NO!")
		break
	end
    if bf.last
    	break
    end
end