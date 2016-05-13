#

using Base.Test
using Compat
using BinDeps

Pkg.build("Cairo")  # Tests apt-get code paths
using Cairo
Pkg.build("HttpParser")  # Tests build-from-source code paths
using HttpParser

# PR 171
@test BinDeps.lower(nothing, nothing) === nothing
