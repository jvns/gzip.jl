Gunzip in Julia
================

Contary to the repo name, this actually implements `gunzip` and not `gzip` in Julia.

The coolest thing (that I know of) that you can do with this repository is visualize unzipping. 

To play with this, do

```
git checkout visualization
gzip myfile.txt
julia gunzip.jl myfile.txt.gz
```

This will unzip `myfile.txt.gz` and show which parts are represented literally and which parts are references to previous parts of the file. Do this to a text file and not a binary :)

You can see a video of this happening to "The Raven" in [this blog post](http://jvns.ca/blog/2013/10/24/day-16-gzip-plus-poetry-equals-awesome/). 

If (when!) you find bugs, let me know!
