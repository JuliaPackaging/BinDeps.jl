#### Test Harness

using Morsel
app = Morsel.app()

route(app, GET, "/liba.tar") do req,sys
    path = dirname(@__FILE__)
    path = joinpath(path,"files")
    readall(`tar c liba`)
end

@async start(app, 4653)

#### Test script
using BinDeps

const testuri = URI("http://localhost:4653/liba.tar")

@BinDeps.setup

deps = [
    liba = library_dependency("liba", aliases = ["liba","liba1","liba.1"])
]

provides(Sources,testuri,liba,SHA="769c43644f239d8825cefc998124060cf9f477f94e8e338f6c3e17839470229d")
provides(BuildProcess,Autotools(libtarget = "liba.$(Libdl.dlext)"),liba)

@BinDeps.install Dict(:liba => :jl_liba)
