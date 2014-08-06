# This is the high level interface for building dependencies using the declarative BinDeps Interface

# A dependency provider, if succcessfully exectued will satisfy the dependency
abstract DependencyProvider

# A library helper may be used by `DependencyProvider`s but will by iteself not provide the library
abstract DependencyHelper

type PackageContext
    do_install::Bool
    dir::String
    package::String
    deps::Vector{Any}
end

type LibraryDependency
    name::String
    context::PackageContext
    providers::Vector{(DependencyProvider,Dict{Symbol,Any})}
    helpers::Vector{(DependencyHelper,Dict{Symbol,Any})}
    properties::Dict{Symbol,Any}
    libvalidate::Function
end

type LibraryGroup
    name::String
    deps::Vector{LibraryDependency}
end

import Base: show

function show(io::IO, dep::LibraryDependency)
    print(io,"LibraryDependency(",dep.name,")")
end

# Default directory organization
pkgdir(dep) = dep.context.dir
depsdir(dep) = joinpath(pkgdir(dep),"deps")
usrdir(dep) = joinpath(depsdir(dep),"usr")
libdir(dep) = joinpath(usrdir(dep),"lib")
bindir(dep) = joinpath(usrdir(dep),"bin")
includedir(dep) = joinpath(usrdir(dep),"include")
builddir(dep) = joinpath(depsdir(dep),"builds")
downloadsdir(dep) = joinpath(depsdir(dep),"downloads")
srcdir(dep) = joinpath(depsdir(dep),"src")
libdir(provider, dep) = libdir(dep)
bindir(provider, dep) = bindir(dep)

successful_validate(l,p) = true

function _library_dependency(context::PackageContext, name; properties...)
    validate = successful_validate
    group = nothing
    for i in 1:length(properties)
        k,v = properties[i]
        if k == :validate
            validate = v
            splice!(properties,i)
        end
        if k == :group
            group = v
        end
    end
    r = LibraryDependency(name,context,Array((DependencyProvider,Dict{Symbol,Any}),0),Array((DependencyHelper,Dict{Symbol,Any}),0),(Symbol=>Any)[name => value for (name,value) in properties],validate)
    if group !== nothing
        push!(group.deps,r)
    else
        push!(context.deps,r)
    end
    r
end

function _library_group(context,name)
    r = LibraryGroup(name,LibraryDependency[])
    push!(context.deps,r)
    r
end

# This macro expects to be the first thing run. It attempts to deduce the package name and initializes the context
macro setup()
    dir = normpath(joinpath(pwd(),".."))
    package = basename(dir)
    esc(quote
        if length(ARGS) > 0 && isa(ARGS[1],BinDeps.PackageContext)
            bindeps_context = ARGS[1]
        else
            bindeps_context = BinDeps.PackageContext(true,$dir,$package,{})
        end
        library_group(args...) = BinDeps._library_group(bindeps_context,args...)
        library_dependency(args...; properties...) = BinDeps._library_dependency(bindeps_context,args...;properties...)
    end)
end

export library_dependency, bindir, srcdir, usrdir, libdir

library_dependency(args...; properties...) = error("No context provided. Did you forget `@Bindeps.setup`?")

abstract PackageManager <: DependencyProvider

const has_apt = try success(`apt-get -v`) catch e false end
type AptGet <: PackageManager 
    package::String
end
can_use(::Type{AptGet}) = has_apt && OS_NAME == :Linux
package_available(p::AptGet) = can_use(AptGet) && beginswith(readall(`apt-cache showpkg $(p.package)`),"Package:")
function available_version(p::AptGet)
    for l in eachline(`apt-cache show $(p.package)`)
        if beginswith(l,"Version:")
            return convert(VersionNumber,l[(1+length("Version: ")):end])
        end
    end
    error("apt-cache did not return version information. This shouldn't happen. Please file a bug!")
end
pkg_name(a::AptGet) = a.package

libdir(p::AptGet,dep) = "/usr/lib"

const has_yum = try success(`yum --version`) catch e false end
type Yum <: PackageManager
    package::String
end
can_use(::Type{Yum}) = has_yum && OS_NAME == :Linux
package_available(y::Yum) = can_use(Yum) && success(`yum list $(y.package)`)
function available_version(y::Yum)
    uname = readchomp(`uname -m`)
    found_uname = false
    found_version = false
    for l in eachline(`yum info $(y.package)`)
        l = chomp(l)
        if !found_uname
            # On 64-bit systems, we may have multiple arches installed
            # this makes sure we get the right one
            found_uname = endswith(l, uname)
            continue
        end
        if beginswith(l, "Version")
            return convert(VersionNumber, split(l)[end])
        end
    end
    error("yum did not return version information.  This shouldn't happen. Please file a bug!")
end
pkg_name(y::Yum) = y.package

# Can use everything else without restriction by default
can_use(::Type) = true

abstract Sources <: DependencyHelper
abstract Binaries <: DependencyProvider

#
# A dummy provider checked for every library that
# indicates the library was found somewhere on the
# system using dlopen.
#
immutable SystemPaths <: Binaries; end

show(io::IO, ::SystemPaths) = print(io,"System Paths")

using URIParser
export URI

type NetworkSource <: Sources
    uri::URI
end

srcdir(s::Sources, dep::LibraryDependency) = srcdir(dep,s,(Symbol=>Any)[])
function srcdir( dep::LibraryDependency, s::NetworkSource,opts) 
    joinpath(srcdir(dep),get(opts,:unpacked_dir,splittarpath(basename(s.uri.path))[1]))
end

type RemoteBinaries <: Binaries
    uri::URI
end

type CustomPathBinaries <: Binaries
    path::String
end

libdir(p::CustomPathBinaries,dep) = p.path

abstract BuildProcess <: DependencyProvider

type SimpleBuild <: BuildProcess
    steps
end

type Autotools <: BuildProcess
    source
    opts
end

type GetSources <: BuildStep
    dep::LibraryDependency
end

lower(x::GetSources,collection) = push!(collection,generate_steps(x.dep,gethelper(x.dep,Sources)...))

Autotools(;opts...) = Autotools(nothing,{k => v for (k,v) in opts})

export AptGet, Yum, Sources, Binaries, provides, BuildProcess, Autotools, GetSources, SimpleBuild, available_version

provider{T<:PackageManager}(::Type{T},package::String; opts...) = T(package)
provider(::Type{Sources},uri::URI; opts...) = NetworkSource(uri)
provider(::Type{Binaries},uri::URI; opts...) = RemoteBinaries(uri)
provider(::Type{Binaries},path::String; opts...) = CustomPathBinaries(path)
provider(::Type{SimpleBuild},steps; opts...) = SimpleBuild(steps)
provider{T<:BuildProcess}(::Type{BuildProcess},p::T; opts...) = provider(T,p; opts...)
provider(::Type{BuildProcess},steps::Union(BuildStep,SynchronousStepCollection); opts...) = provider(SimpleBuild,steps; opts...)
provider(::Type{Autotools},a::Autotools; opts...) = a

provides(provider::DependencyProvider,dep::LibraryDependency; opts...) = push!(dep.providers,(provider,(Symbol=>Any)[k=>v for (k,v) in opts]))
provides(helper::DependencyHelper,dep::LibraryDependency; opts...) = push!(dep.helpers,(helper,(Symbol=>Any)[k=>v for (k,v) in opts]))
provides{T}(::Type{T},p,dep::LibraryDependency; opts...) = provides(provider(T,p; opts...),dep; opts...)
function provides{T}(::Type{T},ps,deps::Vector{LibraryDependency}; opts...) 
    p = provider(T,ps; opts...)
    for dep in deps 
        provides(p,dep; opts...)
    end
end

function provides{T}(::Type{T},providers::Dict; opts...)
    for (k,v) in providers
        provides(T,k,v;opts...)
    end
end


generate_steps(h::DependencyProvider,dep::LibraryDependency) = error("Must also pass provider options")
generate_steps(h::BuildProcess,dep::LibraryDependency,opts) = h.steps
function generate_steps(dep::LibraryDependency,h::AptGet,opts) 
    if get(opts,:force_rebuild,false) 
        error("Will not force apt-get to rebuild dependency \"$(dep.name)\".\n"*
              "Please make any necessary adjustments manually (This might just be a version upgrade)")
    end
    @build_steps begin
        println("Installing dependency $(h.package) via `sudo apt-get install $(h.package)`:")
        `sudo apt-get install $(h.package)`
        ()->(ccall(:jl_read_sonames,Void,()))
    end
end
function generate_steps(dep::LibraryDependency,h::Yum,opts) 
    if get(opts,:force_rebuild,false) 
        error("Will not force yum to rebuild dependency \"$(dep.name)\".\n"*
              "Please make any necessary adjustments manually (This might just be a version upgrade)")
    end

    @build_steps begin
        println("Installing dependency $(h.package) via `sudo yum install $(h.package)`:")
        `sudo yum install $(h.package)`
        ()->(ccall(:jl_read_sonames,Void,()))
    end
end
function generate_steps(dep::LibraryDependency,h::NetworkSource,opts)
    localfile = joinpath(downloadsdir(dep),basename(h.uri.path))
    @build_steps begin
        FileDownloader(string(h.uri),localfile)
        ChecksumValidator(get(opts,:SHA,""),localfile)
        CreateDirectory(srcdir(dep))
        FileUnpacker(localfile,srcdir(dep),srcdir(dep,h,opts))
    end
end
function generate_steps(dep::LibraryDependency,h::RemoteBinaries,opts) 
    get(opts,:force_rebuild,false) && error("Force rebuild not allowed for binaries. Use a different download location instead.")
    localfile = joinpath(downloadsdir(dep),basename(h.uri.path))
    steps = @build_steps begin
        FileDownloader(string(h.uri),localfile)
        ChecksumValidator(get(opts,:SHA,""),localfile)
        FileUnpacker(localfile,depsdir(dep),get(opts,:unpacked_dir,"usr"))
    end
end
generate_steps(dep::LibraryDependency,h::SimpleBuild,opts) = h.steps

function getoneprovider(dep::LibraryDependency,method)
    for (p,opts) = dep.providers
        if typeof(p) <: method && can_use(typeof(p))
            return (p,opts)
        end
    end
    return (nothing,nothing)
end

function getallproviders(dep::LibraryDependency,method)
    ret = {}
    for (p,opts) = dep.providers
        if typeof(p) <: method && can_use(typeof(p))
            push!(ret,(p,opts))
        end
    end
    ret
end

function gethelper(dep::LibraryDependency,method)
    for (p,opts) = dep.helpers
        if typeof(p) <: method
            return (p,opts)
        end
    end
    return (nothing,nothing)
end

function generate_steps(dep::LibraryDependency,method)
    (p,opts) = getoneprovider(dep,method)
    !is(p,nothing) && return generate_steps(p,dep,opts)
    (p,hopts) = gethelper(dep,method)
    !is(p,nothing) && return generate_steps(p,dep,hopts)
    error("No provider or helper for method $method found for dependency $(dep.name)")
end

function generate_steps(dep::LibraryDependency, h::Autotools,  provider_opts)
    if is(h.source, nothing) 
        h.source = gethelper(dep,Sources)
    end
    if isa(h.source,Sources)
        h.source = (h.source,(Symbol=>Any)[])
    end
    is(h.source[1], nothing) && error("Could not obtain sources for dependency $(dep.name)")
    steps = lower(generate_steps(dep,h.source...))
    opts = {:srcdir=>srcdir(dep,h.source...), :prefix=>usrdir(dep), :builddir=>joinpath(builddir(dep),dep.name)}
    merge!(opts,h.opts)
    if haskey(opts,:installed_libname)
        !haskey(opts,:installed_libpath) || error("Can't specify both installed_libpath and installed_libname")
        opts[:installed_libpath] = ByteString[joinpath(libdir(dep),opts[:installed_libname])]
        delete!(opts, :installed_libname)
    elseif !haskey(opts,:installed_libpath)
        opts[:installed_libpath] = ByteString[joinpath(libdir(dep),x)*"."*dlext for x in get(dep.properties,:aliases,ByteString[])]
    end
    if !haskey(opts,:libtarget) && haskey(dep.properties,:aliases)
        opts[:libtarget] = ByteString[x*"."*dlext for x in dep.properties[:aliases]]
    end
    if !haskey(opts,:include_dirs)
        opts[:include_dirs] = String[]
    end
    if !haskey(opts,:lib_dirs)
        opts[:lib_dirs] = String[]
    end
    if !haskey(opts,:pkg_config_dirs)
        opts[:pkg_config_dirs] = String[]
    end
    if !haskey(opts,:rpath_dirs)
        opts[:rpath_dirs] = String[]
    end
    if haskey(opts,:configure_subdir)
        opts[:srcdir] = joinpath(opts[:srcdir],opts[:configure_subdir])
        delete!(opts, :configure_subdir)
    end
    unshift!(opts[:include_dirs],includedir(dep))
    unshift!(opts[:lib_dirs],libdir(dep))
    unshift!(opts[:rpath_dirs],libdir(dep))
    unshift!(opts[:pkg_config_dirs],joinpath(libdir(dep),"pkgconfig"))
    env = Dict{ByteString,ByteString}()
    env["PKG_CONFIG_PATH"] = join(opts[:pkg_config_dirs],":")
    delete!(opts,:pkg_config_dirs)
    @unix_only env["PATH"] = bindir(dep)*":"*ENV["PATH"]
    @windows_only env["PATH"] = bindir(dep)*";"*ENV["PATH"]
    haskey(opts,:env) && merge!(env,opts[:env])
    opts[:env] = env
    if get(provider_opts,:force_rebuild,false)
        opts[:force_rebuild] = true
    end
    steps |= AutotoolsDependency(;opts...)
    steps
end

@osx_only const EXTENSIONS = ["","dylib"]
@windows_only const EXTENSIONS = ["", "dll"]
@linux_only const EXTENSIONS = ["","so"]

#
# Finds all copies of the library on the system, listed in preference order.
# Return value is an array of tuples if the provider and the path where it is found
#
function _find_library(dep::LibraryDependency; provider = Any)
    ret = Any[]
    # Same as find_library, but with extra check defined by dep
    libnames = [dep.name;get(dep.properties,:aliases,ASCIIString[])]
    # Make sure we keep the defaults first, but also look in the other directories
    providers = unique([reduce(vcat,[getallproviders(dep,p) for p in defaults]),dep.providers])
    for (p,opts) in providers
        (p != nothing && can_use(typeof(p)) && can_provide(p,opts,dep)) || continue
        paths = String[]
        push!(paths,libdir(p,dep))
        if haskey(opts,:unpacked_dir) && isdir(joinpath(depsdir(dep),opts[:unpacked_dir]))
            push!(paths,joinpath(depsdir(dep),opts[:unpacked_dir]))
        end

        # Many linux distributions use lib32/lib64 as well
        @unix_only begin
            if isdir(libdir(p,dep)*"32")
                push!(paths, libdir(p,dep)*"32")
            end
            if isdir(libdir(p,dep)*"64")
                push!(paths, libdir(p,dep)*"64")
            end
        end
        # Windows, do you know what `lib` stands for???
        @windows_only push!(paths,bindir(p,dep))
        (isempty(paths) || all(map(isempty,paths))) && continue
        for lib in libnames, path in paths
            l = joinpath(path, lib)
            h = dlopen_e(l, RTLD_LAZY)
            if h != C_NULL
                works = dep.libvalidate(l,h)
                if VERSION >= v"0.3-"
                    l = Sys.dlpath(h)
                end
                dlclose(h)
                if works
                    push!(ret, ((p, opts), l))
                else
                    # We tried to load this providers' library, but it didn't satisfy
                    # the requirements, so tell it to force a rebuild since the requirements
                    # have most likely changed
                    opts[:force_rebuild] = true
                end
            end
        end
    end
    # 0.2 compatibility
    if VERSION < v"0.3-"
        for lib in libnames
            p = dlopen_e(lib, RTLD_LAZY)
            if p != C_NULL
                works = dep.libvalidate(lib,p)
                dlclose(p)
                if works
                    push!(ret,((SystemPaths(),(Any=>Any)[]),lib))
                end
            end
        end
    else
        # Now check system libraries
        for lib in libnames
            # We don't want to use regular dlopen, because we want to get at
            # system libraries even if one of our providers is higher in the
            # DL_LOAD_PATH
            for path in Base.DL_LOAD_PATH
                for ext in EXTENSIONS
                    opath = string(joinpath(path,lib),".",ext)
                    check_path!(ret,dep,opath)
                end
            end
            for ext in EXTENSIONS
                opath = string(lib,".",ext)
                check_path!(ret,dep,opath)
            end
        end
    end
    return ret
end

if VERSION >= v"0.3-"
    function check_path!(ret,dep,opath)
        flags = RTLD_LAZY
        handle = c_malloc(2*sizeof(Ptr{Void}))
        err = ccall(:jl_uv_dlopen,Cint,(Ptr{Uint8},Ptr{Void},Cuint),opath,handle,flags)
        if err == 0
            check_system_handle!(ret,dep,handle)
            dlclose(handle)
            c_free(handle)
        end
    end

    function check_system_handle!(ret,dep,handle)
        if handle != C_NULL
            libpath = Sys.dlpath(handle)
            # Check that this is not a duplicate
            for p in ret
                try
                    if realpath(p[2]) == realpath(libpath)
                        return
                    end
                catch
                    warn("""
                        Found a library that does not exist.
                        This may happen if the library has an active open handle.
                        Please quit julia and try again.
                        """)
                    return
                end
            end
            works = dep.libvalidate(libpath,handle)
            if works
                push!(ret, ((SystemPaths(),(Any=>Any)[]), libpath))
            end
        end
    end
end

# Default installation method
if OS_NAME == :Darwin
    defaults = [Binaries,PackageManager,BuildProcess]
elseif OS_NAME == :Linux
    defaults = [PackageManager,BuildProcess]
elseif OS_NAME == :Windows
    defaults = [Binaries,PackageManager]
else
    defaults = [BuildProcess]
end

function applicable(dep::LibraryDependency)
    if haskey(dep.properties,:os)
        if (dep.properties[:os] != OS_NAME && dep.properties[:os] != :Unix) || (dep.properties[:os] == :Unix && !Base.is_unix(OS_NAME))
            return false
        end
    elseif haskey(dep.properties,:runtime) && dep.properties[:runtime] == false
        return false
    end
    return true
end

applicable(deps::LibraryGroup) = any([applicable(dep) for dep in deps.deps])

function can_provide(p,opts,dep)
    if p === nothing || (haskey(opts,:os) && opts[:os] != OS_NAME && (opts[:os] != :Unix || !Base.is_unix(OS_NAME)))
        return false
    end
    if !haskey(opts,:validate)
        return true
    elseif isa(opts[:validate],Bool)
        return opts[:validate]
    else
        return opts[:validate](p,dep)
    end
end

function can_provide(p::PackageManager,opts,dep)
    if p === nothing || (haskey(opts,:os) && opts[:os] != OS_NAME && (opts[:os] != :Unix || !Base.is_unix(OS_NAME)))
        return false
    end
    if !package_available(p)
        return false
    end
    if !haskey(opts,:validate)
        return true
    elseif isa(opts[:validate],Bool)
        return opts[:validate]
    else
        return opts[:validate](p,dep)
    end
end

issatisfied(dep::LibraryDependency) = !isempty(_find_library(dep))

allf(deps) = [dep => _find_library(dep) for dep in deps.deps]
function satisfied_providers(deps::LibraryGroup, allfl = allf(deps))
    viable_providers = nothing
    for dep in deps.deps
        if !applicable(dep)
            continue
        end
        providers = map(x->typeof(x[1][1]),allfl[dep])
        if viable_providers == nothing
            viable_providers = providers
        else
            viable_providers = intersect(viable_providers,providers)
        end
    end
    viable_providers
end

function viable_providers(deps::LibraryGroup)
    vp = nothing
    for dep in deps.deps
        if !applicable(dep)
            continue
        end
        providers = map(x->typeof(x[1]),dep.providers)
        if vp == nothing
            vp = providers
        else
            vp = intersect(vp,providers)
        end
    end
    vp
end

#
# We need to make sure all libraries are satisfied with the
# additional constraint that all of them are satisfied by the
# same provider.
#
issatisfied(deps::LibraryGroup) = !isempty(satisfied_providers(deps))

function _find_library(deps::LibraryGroup, allfl = allf(deps); provider = Any)
    providers = satisfied_providers(deps,allfl)
    p = nothing
    if isempty(providers)
        return (Any=>Any)[]
    else
        for p2 in providers
            if p2 <: provider
                p = p2
            end
        end
    end
    p === nothing && error("Given provider does not satisfy the library group")
    [dep => begin
        thisfl = allfl[dep]
        ret = nothing
        for fl in thisfl
            if isa(fl[1][1],p)
                ret = fl
                break
            end
        end
        @assert ret != nothing
        ret
    end for dep in filter(applicable,deps.deps)]
end

function satisfy!(deps::LibraryGroup, methods = defaults)
    sp = satisfied_providers(deps)
    if !isempty(sp)
        for m in methods
            for s in sp
                if s <: m
                    return s
                end
            end
        end
    end
    if !applicable(deps)
        return Any
    end
    vp = viable_providers(deps)
    didsatisfy = false
    for method in methods
        for p in vp
            if !(p <: method) || !can_use(p)
                continue
            end
            skip = false
            for dep in deps.deps
                !applicable(dep) && continue
                hasany = false
                for (p2,opts) in getallproviders(dep,p)
                    can_provide(p2, opts, dep) && (hasany = true)
                end
                if !hasany
                    skip = true
                    break
                end
            end
            if skip
                continue
            end
            for dep in deps.deps
                satisfy!(dep,[p])
            end
            return p
        end
    end
    error("""
        None of the selected providers could satisfy library group $(deps.name)
        Use BinDeps.debug(package_name) to see available providers
        """)
end

function satisfy!(dep::LibraryDependency, methods = defaults)
    sp = map(x->typeof(x[1][1]),_find_library(dep))
    if !isempty(sp)
        for m in methods
            for s in sp
                if s <: m
                    return s
                end
            end
        end
    end
    if !applicable(dep)
        return
    end
    for method in methods
        for (p,opts) in getallproviders(dep,method)
            can_provide(p,opts,dep) || continue
            if haskey(opts,:force_depends)
                for (dmethod,ddep) in opts[:force_depends]
                    (dp,dopts) = getallproviders(ddep,dmethod)[1]
                    run(lower(generate_steps(ddep,dp,dopts)))
                end
            end
            run(lower(generate_steps(dep,p,opts)))
            !issatisfied(dep) && error("Provider $method failed to satisfy dependency $(dep.name)")
            return p
        end
    end
    error("""
        None of the selected providers can install dependency $(dep.name).
        Use BinDeps.debug(package_name) to see available providers
        """)
end

execute(dep::LibraryDependency,method) = run(lower(generate_steps(dep,method)))

macro install (_libmaps...)
    if length(_libmaps) == 0
        return esc(quote
            if bindeps_context.do_install
                for d in bindeps_context.deps
                    BinDeps.satisfy!(d)
                end
            end
        end)
    else
        libmaps = eval(_libmaps[1])
        load_cache = gensym()
        ret = Expr(:block)
        push!(ret.args,
            esc(quote
                    load_cache = Dict()
                    load_hooks = String[]
                    if bindeps_context.do_install
                        for d in bindeps_context.deps
                            p = BinDeps.satisfy!(d)
                            libs = BinDeps._find_library(d; provider = p)
                            if isa(d, BinDeps.LibraryGroup)
                                if !isempty(libs)
                                    for dep in d.deps
                                        !BinDeps.applicable(dep) && continue
                                        load_cache[dep.name] = libs[dep][2]
                                        opts = libs[dep][1][2]
                                        if haskey(opts,:onload) && !(opts[:onload] in load_hooks)
                                            push!(load_hooks,opts[:onload])
                                        end
                                    end
                                end
                            else
                                for (k,v) in libs
                                    load_cache[d.name] = v
                                    opts = k[2]
                                    if haskey(opts,:onload) && !(opts[:onload] in load_hooks)
                                        push!(load_hooks,opts[:onload])
                                    end
                                end
                            end
                        end
                    end
                    depsfile = open(joinpath(splitdir(Base.source_path())[1],"deps.jl"), "w")
                    println(depsfile, "macro checked_lib(libname, path)
        (dlopen_e(path) == C_NULL) && error(\"Unable to load \\n\\n\$libname (\$path)\\n\\nPlease re-run Pkg.build(package), and restart Julia.\")
        quote const \$(esc(libname)) = \$path end
    end")
                    for libkey in keys($libmaps)
                        ((cached = get(load_cache,string(libkey),nothing)) === nothing) && continue
                        println(depsfile, "@checked_lib ", $libmaps[libkey], " \"", escape_string(cached), "\"")
                    end
                    println(depsfile, join(load_hooks,"\n"))
                    close(depsfile)
                end))
        if !(typeof(libmaps) <: Associative)
            warn("Incorrect mapping in BinDeps.@install call. No dependencies will be cached.")
        end
        ret
    end
end

# Usage: @load_dependencies [file] [filter]
#
# Load dependencies as declared in `file` (default to "../deps/build.jl")
#
# This will also assign global variables in the current module that are the result of the symbol lookup
# The filter argument determines which libaries are being loaded and can be used to modify
# the name of the global variable to be set to the result of the lookup.
# The second argument may be as follows:
#
#  1. Vector{Symbol} or Vector{T <: String} 
#       Only load that are declared whose name is listed in the Array
#       E.g. @load_dependencies "file.jl" [:cairo, :tk]
#
#  2. Associative{S<:Union(Symbol,String),S<:Union(Symbol,String)}
#       Only loads libraries whose name matches a key in the Associative collection, but assigns it
#       to the name matiching the corresponsing value
#       E.g. @load_dependencies "file.jl" [:cairo=>:libcairo, :tk=>:libtk]
#       will assign the result of the lookup for :cairo and :tk to the variables `libcairo` and `libtk`
#       respectively.
# 
#  3. Function
#       A filter function
#       E.g. @load_dependencies "file.jl" x->x=="tk"
#
#
macro load_dependencies(args...)
    dir = dirname(normpath(joinpath(dirname(Base.source_path()),"..")))
    arg1 = nothing
    file = "../deps/build.jl"
    if length(args) == 1 
        if isa(args[1],Expr)
            arg1 = eval(args[1])
        elseif typeof(args[1]) <: String
            file = args[1]
            dir = dirname(normpath(joinpath(dirname(file),"..")))
        elseif typeof(args[1]) <: Associative || isa(args[1],Vector)
            arg1 = args[1]
        else
            error("Type $(typeof(args[1])) not recognized for argument 1. See usage instructions!")
        end
    elseif length(args) == 2
        file = args[1]
        arg1 = typeof(args[2]) <: Associative || isa(args[2],Vector) ? args[2] : eval(args[2])
    elseif length(args) != 0
        error("No version of @load_dependencies takes $(length(args)) arguments. See usage instructions!")
    end
    pkg = ""
    r = search(dir,Pkg.Dir.path())
    if r != 0:-1
        s = search(dir,"/",last(r)+2)
        if s != 0:-1
            pkg = dir[(last(r)+2):(first(s)-1)]
        else
            pkg = dir[(last(r)+2):end]
        end
    end
    context = BinDeps.PackageContext(false,dir,pkg,{})
    m = Module(:__anon__)
    body = Expr(:toplevel,:(ARGS=[$context]),:(include($file)))
    eval(m,body)
    ret = Expr(:block)
    for dep in context.deps
        if !applicable(dep)
            continue
        end
        name = sym = dep.name
        if arg1 !== nothing
            if (typeof(arg1) <: Associative) && all(map(x->(x == Symbol || x <: String),eltype(arg1)))
                found = false
                for need in keys(arg1)
                    found = (dep.name == string(need))
                    if found
                        sym = arg1[need]
                        delete!(arg1,need)
                        break
                    end
                end
                if !found
                    continue
                end
            elseif isa(arg1,Vector) && ((eltype(arg1) == Symbol) || (eltype(arg1) <: String))
                found = false
                for i = 1:length(args)
                    found = (dep.name == string(arg1[i]))
                    if found
                        sym = arg1[i]
                        splice!(arg1,i)
                        break
                    end
                end
                if !found
                    continue
                end
            elseif isa(arg1,Function)
                if !f(name)
                    continue
                end
            else
                error("Can't deal with argument type $(typeof(arg1)). See usage instructions!")
            end
        end
        s = symbol(sym)
        errorcase = Expr(:block)
        push!(errorcase.args,:(error("Could not load library "*$(dep.name)*". Try running Pkg.build() to install missing dependencies!")))
        push!(ret.args,quote
            const $(esc(s)) = BinDeps._find_library($dep)
            if isempty($(esc(s)))
                $errorcase
            end
        end)
    end
    if arg1 != nothing && !isa(arg1,Function)
        if !isempty(arg1)
            errrormsg = "The following required libraries were not declared in build.jl:\n"
            for k in (isa(arg1,Vector) ? arg1 : keys(arg1))
                errrormsg *= " - $k\n"
            end
            error(errrormsg)
        end
    end
    ret
end

function build(pkg::String, method; dep::String="", force=false)
    dir = Pkg.dir(pkg)
    file = joinpath(dir,"deps/build.jl")
    context = BinDeps.PackageContext(false,dir,pkg,{})
    m = Module(:__anon__)
    body = Expr(:toplevel,:(ARGS=[$context]),:(include($file)))
    eval(m,body)
    for d in context.deps
        BinDeps.satisfy!(d,[method])
    end
end

# Calculate the SHA-512 hash of a file
if success(`shasum -v`)
    shasum(path) = split(readall(`shasum -a 512 $path`))[1]
elseif success(`sha512sum -v`)
    shasum(path) = split(readall(`sha512sum $path`))[1]
else
    function shasum(path)
        info("No utility found for checksumming downloads; skipping checksum verification")
        return nothing
    end
end

function sha_check(path, sha)
    calc_sha = shasum(path)
    if calc_sha != nothing && calc_sha != sha
        error("Checksum mismatch!  Expected:\n$sha\nCalculated:\n$calc_sha\nDelete $path and try again")
    end
end