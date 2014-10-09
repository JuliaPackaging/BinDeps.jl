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
const shlib_ext = BinDeps.shlib_ext

@BinDeps.setup

deps = [
    liba = library_dependency("liba", aliases = ["liba","liba1","liba.1"])
]

provides(Sources,testuri,liba,SHA="9ea5c0400e74dc95dfb75752cfd6955d80929ec3a4a6eac2f9b38d45a14a184c")
provides(BuildProcess,Autotools(libtarget = "liba.$shlib_ext"),liba)

@BinDeps.install [:liba => :jl_liba]
