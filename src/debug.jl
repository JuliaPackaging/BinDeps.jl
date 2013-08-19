function debug(io,pkg::String)
    info("Reading build script...")
    dir = Pkg2.dir(pkg)
    file = joinpath(dir,"deps/build.jl")
    context = BinDeps.PackageContext(false,dir,pkg,{})
    m = Module(:__anon__)
    body = Expr(:toplevel,:(ARGS=[$context]),:(include($file)))
    eval(m,body)
    println(io,"The package declares $(length(context.deps)) dependencies.")
    for dep in context.deps
        print(io," - Library \"$(dep.name)\"")
        if !applicable(dep)
            println(io," (not applicable to this system)")
        else
            lib = _find_library(dep)
            if !isempty(lib)
                println(io," (satisfied by $lib)")
            else
                println(io)
            end
            if length(dep.providers) > 0
                println(io,"    - Providers:")
                for (dep,opts) in dep.providers 
                    show_indented(io,dep,6)
                    println(io)
                end
            end
        end
    end
end
debug(pkg::String) = debug(STDOUT,pkg)