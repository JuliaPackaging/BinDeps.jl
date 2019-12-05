import Base: show

function _show_indented(io::IO, dep::LibraryDependency, indent, lib)
    print_indented(io,"- Library \"$(dep.name)\"",indent+1)
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
show_indented(io::IO, dep::LibraryDependency, indent) = _show_indented(io,dep,indent, applicable(dep) ? _find_library(dep) : nothing)
show(io::IO, dep::LibraryDependency) = show_indented(io, dep, 0)

function show(io::IO, deps::LibraryGroup)
    print(io," - Library Group \"$(deps.name)\"")
    all = allf(deps)
    providers = satisfied_providers(deps,all)
    if providers !== nothing && !isempty(providers)
        print(io," (satisfied by ",join(providers,", "),")")
    end
    if !applicable(deps)
        println(io," (not applicable to this system)")
    else
        println(io)
        for dep in deps.deps
            _show_indented(io,dep,4,haskey(all,dep) ? all[dep] : nothing)
        end
    end
end

function debug_context(pkg::AbstractString)
    @info("Reading build script...")
    dir = Pkg.dir(pkg)
    file = joinpath(dir, "deps", "build.jl")
    context = BinDeps.PackageContext(false, dir, pkg, Any[])
    eval_anon_module(context, file)
    context
end

function debug(io,pkg::AbstractString)
    context = debug_context(pkg)
    println(io,"The package declares $(length(context.deps)) dependencies.")

    # We need to `eval()` the rest of this function because `debug_context()` will
    # `eval()` in things like `Homebrew.jl`, which contain new methods for things
    # like `can_provide()`, and we cannot deal with those new methods in our
    # current world age; we need to `eval()` to force ourselves up into a newer
    # world age.
    @eval for dep in $(context.deps)
        show($io,dep)
    end
end
debug(pkg::AbstractString) = debug(stdout,pkg)
