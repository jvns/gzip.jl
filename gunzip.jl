include("gzip.jl")

f = open(ARGS[1])
read(f, GzipFile) # Ignore headers
bs = BitStream(f)

decoded_text = read_block(bs)
print(display_ascii(decoded_text))
