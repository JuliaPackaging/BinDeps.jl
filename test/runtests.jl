#

using Base.Test
using Compat

Pkg.add("Cairo")  # Tests apt-get code paths
using Cairo
Pkg.add("HttpParser")  # Tests build-from-source code paths
using HttpParser

# PR 171
@test BinDeps.lower(nothing, nothing) === nothing
