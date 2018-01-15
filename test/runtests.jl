using Compat
using Compat.Test, Compat.Unicode
using BinDeps

if VERSION >= v"0.7.0-DEV.3382"
    using Libdl
end

Pkg.build("Cairo")  # Tests apt-get code paths
using Cairo
Pkg.build("HttpParser")  # Tests build-from-source code paths
using HttpParser
Pkg.build("GSL")
using GSL


Pkg.build("Gumbo") # Test Autotools code paths
using Gumbo



# PR 171
@test BinDeps.lower(nothing, nothing) === nothing

# PR 271
BinDeps.debug("Cairo")

let gv = glibc_version()
    if Compat.Sys.islinux()
        lddv = lowercase(readchomp(`ldd --version`))
        if contains(lddv, "gnu") || contains(lddv, "glibc")
            @test isa(gv, VersionNumber)
            @test gv >= v"1.0.0"
        else
            # Assume non-glibc
            @test gv === nothing
        end
    else
        @test gv === nothing
    end
end
