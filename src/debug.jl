import Base: show

function _show_indented(io::IO, dep::Dependency, indent, lib)
    deptype = isa(dep, LibraryDependency) ? "Library" : (isa(dep, ExecutableDependency) ? "Executable" : "")
    print_indented(io,"- $deptype \"$(dep.name)\"",indent+1)
    if !applicable(dep)
        println(io," (not applicable to this system)")
    else
        println(io)
        if !isempty(lib)
            print_indented(io,"- Satisfied by:\n",indent+4)
            for (k,v) in lib
                print_indented(io,"- $(k[1]) at $v\n",indent+6)
            end
        end
        if length(dep.providers) > 0
            print_indented(io,"- Providers:\n",indent+4)
            for (p,opts) in dep.providers
                show_indented(io,p,indent+6)
                if !can_provide(p,opts,dep)
                    print(io," (can't provide)")
                end
                println(io)
            end
        end
    end
end
show_indented(io::IO, dep::Dependency, indent) = _show_indented(io,dep,indent, applicable(dep) ? _find_dependency(dep) : nothing)
show(io::IO, dep::Dependency) = show_indented(io, dep, 0)

function show(io::IO, deps::DependencyGroup)
    print(io," - Dependency Group \"$(deps.name)\"")
    all = allf(deps)
    providers = satisfied_providers(deps,all)
    if providers != nothing && !(isempty(providers))
        print(io," (satisfied by ",join(providers,", "),")")
    end
    if !applicable(deps)
        println(io," (not applicable to this system)")
    else
        println(io)
        for dep in deps.deps
            _show_indented(io,dep,4,haskey(all,dep)? all[dep] : nothing)
        end
    end
end

function debug_context(pkg::AbstractString)
    info("Reading build script...")
    dir = Pkg.dir(pkg)
    file = joinpath(dir,"deps/build.jl")
    context = BinDeps.PackageContext(false,dir,pkg,Any[])
    m = Module(:__anon__)
    body = Expr(:toplevel,:(ARGS=[$context]),:(include($file)))
    eval(m,body)
    context
end

function debug(io,pkg::AbstractString)
    context = debug_context(pkg)
    println(io,"The package declares $(length(context.deps)) dependencies.")
    for dep in context.deps
        show(io,dep)
    end
end
debug(pkg::AbstractString) = debug(STDOUT,pkg)
