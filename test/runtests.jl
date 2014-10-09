folder = joinpath(dirname(@__FILE__), "testscripts", "simplebuild")
cd(folder) do
    include(joinpath(folder, "build.jl"))
end

