#

using Base.Test
using Compat
using BinDeps

Pkg.add("Cairo")  # Tests apt-get code paths
Pkg.build("Cairo")
using Cairo
Pkg.add("HttpParser")  # Tests build-from-source code paths
Pkg.build("HttpParser")
using HttpParser

# PR 171
@test BinDeps.lower(nothing, nothing) === nothing
