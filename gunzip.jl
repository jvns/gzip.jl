include("gzip.jl")

f = open(ARGS[1])
out = length(ARGS) >= 2 ? open(ARGS[2]) : STDOUT
inflate(f, out)
close(f)
close(out)
