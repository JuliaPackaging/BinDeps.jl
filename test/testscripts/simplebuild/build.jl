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

provides(Sources,testuri,liba,SHA="7144ab4215ffe96b28d954b68e02b84b61a3e5b6aa078bf036cafc45b1cfe3aa")
provides(BuildProcess,Autotools(libtarget = "liba.$shlib_ext"),liba)

@BinDeps.install [:liba => :jl_liba]
