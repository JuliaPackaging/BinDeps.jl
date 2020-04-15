# This is the high level interface for building dependencies using the declarative BinDeps Interface
import Base: show
const OSNAME = Sys.iswindows() ? :Windows : Sys.KERNEL

if !isdefined(Base, :pairs)
    pairs(x) = (a => b for (a, b) in x)
end


# A dependency provider, if successfully executed will satisfy the dependency
abstract type DependencyProvider end

# A library helper may be used by `DependencyProvider`s but will by itself not provide the library
abstract type DependencyHelper end

mutable struct PackageContext
    do_install::Bool
    dir::AbstractString
    package::AbstractString
    deps::Vector{Any}
end

mutable struct LibraryDependency
    name::AbstractString
    context::PackageContext
    providers::Vector{Tuple{DependencyProvider,Dict{Symbol,Any}}}
    helpers::Vector{Tuple{DependencyHelper,Dict{Symbol,Any}}}
    properties::Dict{Symbol,Any}
    libvalidate::Function
end

mutable struct LibraryGroup
    name::AbstractString
    deps::Vector{LibraryDependency}
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
libdir(provider, dep) = [libdir(dep), libdir(dep)*"32", libdir(dep)*"64"]
bindir(provider, dep) = bindir(dep)

successful_validate(l,p) = true

function _library_dependency(context::PackageContext, name; props...)
    validate = successful_validate
    group = nothing
    properties = collect(pairs(props))
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
    r = LibraryDependency(name, context, Tuple{DependencyProvider,Dict{Symbol,Any}}[], Tuple{DependencyHelper,Dict{Symbol,Any}}[], Dict{Symbol,Any}(properties), validate)
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
            bindeps_context = BinDeps.PackageContext(true,$dir,$package,Any[])
        end
        library_group(args...) = BinDeps._library_group(bindeps_context,args...)
        library_dependency(args...; properties...) = BinDeps._library_dependency(bindeps_context,args...;properties...)
    end)
end

export library_dependency, bindir, srcdir, usrdir, libdir

library_dependency(args...; properties...) = error("No context provided. Did you forget `@BinDeps.setup`?")

abstract type PackageManager <: DependencyProvider end

const DEBIAN_VERSION_REGEX = r"^
    ([0-9]+\:)?                                           # epoch
    (?:(?:([0-9][a-z0-9.\-+:~]*)-([0-9][a-z0-9.+~]*)) |   # upstream version + debian revision
          ([0-9][a-z0-9.+:~]*))                           # upstream version
"ix

const has_apt = try success(`apt-get -v`) && success(`apt-cache -v`) catch e false end
mutable struct AptGet <: PackageManager
    package::AbstractString
end
can_use(::Type{AptGet}) = has_apt && Sys.islinux()
package_available(p::AptGet) = can_use(AptGet) && !isempty(available_versions(p))
function available_versions(p::AptGet)
    vers = String[]
    lookfor_version = false
    for l in eachline(`apt-cache showpkg $(p.package)`)
        if startswith(l,"Version:")
            try
                vs = l[(1+length("Version: ")):end]
                push!(vers, vs)
            catch e
                # ignore error
            end
        elseif lookfor_version && (m = match(DEBIAN_VERSION_REGEX, l)) !== nothing
            m.captures[2] !== nothing ? push!(vers, m.captures[2]) :
                                       push!(vers, m.captures[4])
        elseif startswith(l, "Versions:")
            lookfor_version = true
        elseif startswith(l, "Reverse Depends:")
            lookfor_version = false
        end
    end
    return vers
end
function available_version(p::AptGet)
    vers = available_versions(p)
    isempty(vers) && error("apt-cache did not return version information. This shouldn't happen. Please file a bug!")
    length(vers) > 1 && warn("Multiple versions of $(p.package) are available.  Use BinDeps.available_versions to get all versions.")
    return vers[end]
end
pkg_name(a::AptGet) = a.package

libdir(p::AptGet,dep) = ["/usr/lib", "/usr/lib64", "/usr/lib32", "/usr/lib/x86_64-linux-gnu", "/usr/lib/i386-linux-gnu"]

const has_yum = try success(`yum --version`) catch e false end
mutable struct Yum <: PackageManager
    package::AbstractString
end
can_use(::Type{Yum}) = has_yum && Sys.islinux()
package_available(y::Yum) = can_use(Yum) && success(`yum list $(y.package)`)
function available_version(y::Yum)
    uname = readchomp(`uname -m`)
    found_uname = false
    found_version = false
    for l in eachline(`yum info $(y.package)`)
        VERSION < v"0.6" && (l = chomp(l))
        if !found_uname
            # On 64-bit systems, we may have multiple arches installed
            # this makes sure we get the right one
            found_uname = endswith(l, uname)
            continue
        end
        if startswith(l, "Version")
            return convert(VersionNumber, split(l)[end])
        end
    end
    error("yum did not return version information.  This shouldn't happen. Please file a bug!")
end
pkg_name(y::Yum) = y.package

# Pacman/Yaourt are package managers for Arch Linux.

# Note that `pacman --version` has an unreliable return value.
const has_pacman = try success(`pacman -Qq`) catch e false end
mutable struct Pacman <: PackageManager
    package::AbstractString
end
can_use(::Type{Pacman}) = has_pacman && Sys.islinux()
package_available(p::Pacman) = can_use(Pacman) && success(`pacman -Si $(p.package)`)
# Only one version is usually available via pacman, hence no `available_versions`.
function available_version(p::Pacman)
    for l in eachline(`pacman -Si $(p.package)`) # To circumvent alias problems
        if startswith(l, "Version")
            # The following isn't perfect, but it's hopefully less brittle than
            # writing a regex for pacman's nonexistent version-string standard.

            # This also strips away the sometimes leading epoch as in ffmpeg's
            # Version        : 1:2.3.3-1
            versionstr = strip(split(l, ":")[end])
            try
                return convert(VersionNumber, versionstr)
            catch e
                # For too long versions like imagemagick's 6.8.9.6-1, give it
                # a second try just discarding superfluous stuff.
                return convert(VersionNumber, join(split(versionstr, '.')[1:3], '.'))
            end
        end
    end
    error("pacman did not return version information. This shouldn't happen. Please file a bug!")
end
pkg_name(p::Pacman) = p.package

libdir(p::Pacman,dep) = ["/usr/lib", "/usr/lib32"]

# zypper is a package manager used by openSUSE
const has_zypper = try success(`zypper --version`) catch e false end
mutable struct Zypper <: PackageManager
    package::AbstractString
end
can_use(::Type{Zypper}) = has_zypper && Sys.islinux()
package_available(z::Zypper) = can_use(Zypper) && success(`zypper se $(z.package)`)
function available_version(z::Zypper)
    uname = readchomp(`uname -m`)
    found_uname = false
    ENV2 = copy(ENV)
    ENV2["LC_ALL"] = "C"
    for l in eachline(setenv(`zypper info $(z.package)`, ENV2))
        VERSION < v"0.6" && (l = chomp(l))
        if !found_uname
            found_uname = endswith(l, uname)
            continue
        end
        if startswith(l, "Version:")
            versionstr = strip(split(l, ":")[end])
            return convert(VersionNumber, versionstr)
        end
    end
    error("zypper did not return version information.  This shouldn't happen. Please file a bug!")
end
pkg_name(z::Zypper) = z.package

libdir(z::Zypper,dep) = ["/usr/lib", "/usr/lib32", "/usr/lib64"]

# pkg is the system binary package manager for FreeBSD
const has_bsdpkg = try success(`pkg -v`) catch e false end
mutable struct BSDPkg <: PackageManager
    package::AbstractString
end
can_use(::Type{BSDPkg}) = has_bsdpkg && Sys.KERNEL === :FreeBSD
function package_available(p::BSDPkg)
    can_use(BSDPkg) || return false
    rgx = Regex(string("^(", p.package, ")(\\s+.+)?\$"))
    for line in eachline(`pkg search -L name $(p.package)`)
        occursin(rgx, line) && return true
    end
    return false
end
function available_version(p::BSDPkg)
    looknext = false
    for line in eachline(`pkg search -L name -Q version $(p.package)`)
        if rstrip(line) == p.package
            looknext = true
            continue
        end
        if looknext && startswith(line, "Version")
            # Package versioning is [SOFTWARE VERSION]_[PORT REVISION],[PORT EPOCH]
            # In our case we only care about the software version, not the port revision
            # or epoch. The software version should be recognizable as semver-ish.
            rawversion = chomp(line[findfirst(c->c==':', line)+2:end])
            # Chop off the port revision and epoch by removing everything after and
            # including the first underscore
            libversion = replace(rawversion, r"_.+$" => "")
            # This should be a valid version, but it's still possible that it isn't
            if occursin(Base.VERSION_REGEX, libversion)
                return VersionNumber(libversion)
            else
                error("\"$rawversion\" is not recognized as a version. Please report this to BinDeps.jl.")
            end
        end
    end
    error("pkg did not return version information. This should not happen. Please file a bug!")
end
pkg_name(p::BSDPkg) = p.package
libdir(p::BSDPkg, dep) = ["/usr/local/lib"]

# Can use everything else without restriction by default
can_use(::Type) = true

abstract type Sources <: DependencyHelper end
abstract type Binaries <: DependencyProvider end

#
# A dummy provider checked for every library that
# indicates the library was found somewhere on the
# system using dlopen.
#
struct SystemPaths <: DependencyProvider; end

show(io::IO, ::SystemPaths) = print(io,"System Paths")

using URIParser
export URI

mutable struct NetworkSource <: Sources
    uri::URI
end

srcdir(s::Sources, dep::LibraryDependency) = srcdir(dep,s,Dict{Symbol,Any}())
function srcdir( dep::LibraryDependency, s::NetworkSource,opts)
    joinpath(srcdir(dep),get(opts,:unpacked_dir,splittarpath(basename(s.uri.path))[1]))
end

mutable struct RemoteBinaries <: Binaries
    uri::URI
end

mutable struct CustomPathBinaries <: Binaries
    path::AbstractString
end

libdir(p::CustomPathBinaries,dep) = p.path

abstract type BuildProcess <: DependencyProvider end

mutable struct SimpleBuild <: BuildProcess
    steps
end

mutable struct Autotools <: BuildProcess
    source
    opts
end

mutable struct GetSources <: BuildStep
    dep::LibraryDependency
end

lower(x::GetSources,collection) = push!(collection,generate_steps(x.dep,gethelper(x.dep,Sources)...))

Autotools(;opts...) = Autotools(nothing, Dict{Any,Any}(pairs(opts)))

export AptGet, Yum, Pacman, Zypper, BSDPkg, Sources, Binaries, provides, BuildProcess, Autotools,
       GetSources, SimpleBuild, available_version

provider(::Type{T},package::AbstractString; opts...) where {T <: PackageManager} = T(package)
provider(::Type{Sources},uri::URI; opts...) = NetworkSource(uri)
provider(::Type{Binaries},uri::URI; opts...) = RemoteBinaries(uri)
provider(::Type{Binaries},path::AbstractString; opts...) = CustomPathBinaries(path)
provider(::Type{SimpleBuild},steps; opts...) = SimpleBuild(steps)
provider(::Type{BuildProcess},p::T; opts...) where {T <: BuildProcess} = provider(T,p; opts...)
provider(::Type{BuildProcess},steps::Union{BuildStep,SynchronousStepCollection}; opts...) = provider(SimpleBuild,steps; opts...)
provider(::Type{Autotools},a::Autotools; opts...) = a

provides(provider::DependencyProvider,dep::LibraryDependency; opts...) = push!(dep.providers,(provider,Dict{Symbol,Any}(pairs(opts))))
provides(helper::DependencyHelper,dep::LibraryDependency; opts...) = push!(dep.helpers,(helper,Dict{Symbol,Any}(pairs(opts))))
provides(::Type{T},p,dep::LibraryDependency; opts...) where {T} = provides(provider(T,p; opts...),dep; opts...)
function provides(::Type{T},packages::AbstractArray,dep::LibraryDependency; opts...) where {T}
    for p in packages
        provides(T,p,dep; opts...)
    end
end

function provides(::Type{T},ps,deps::Vector{LibraryDependency}; opts...) where {T}
    p = provider(T,ps; opts...)
    for dep in deps
        provides(p,dep; opts...)
    end
end

function provides(::Type{T},providers::Dict; opts...) where {T}
    for (k,v) in providers
        provides(T,k,v;opts...)
    end
end

sudoname(c::Cmd) = c == `` ? "" : "sudo "

const have_sonames = Ref(false)
const sonames = Dict{String,String}()
function reread_sonames()
    if VERSION >= v"0.7.0-DEV.1287" # only use this where julia issue #22832 is fixed
        empty!(sonames)
        have_sonames[] = false
        nothing
    else
        ccall(:jl_read_sonames, Cvoid, ())
    end
end

if Sys.iswindows() || Sys.isapple()
    function read_sonames()
        have_sonames[] = true
    end
elseif Sys.islinux()
    let ldconfig_arch = Dict(:i386 => "x32",
                             :i387 => "x32",
                             :i486 => "x32",
                             :i586 => "x32",
                             :i686 => "x32",
                             :x86_64 => "x86-64",
                             :aarch64 => "AArch64"),
        arch = get(ldconfig_arch, Sys.ARCH, ""),
        arch_wrong = filter!(x -> (x != arch), ["x32", "x86-64", "AArch64", "soft-float"])
    global read_sonames
    function read_sonames()
        empty!(sonames)

        # Some Linux distros do not expose executables from /sbin and /usr/sbin via PATH,
        # so we append these here explicitly
        ldconfig_path = ENV["PATH"] * ":/usr/local/sbin:/usr/sbin:/sbin"
        lines_ldconfig = withenv("PATH" => ldconfig_path) do
            eachline(`ldconfig -p`)
        end
        for line in lines_ldconfig
            VERSION < v"0.6" && (line = chomp(line))
            m = match(r"^\s+([^ ]+)\.so[^ ]* \(([^)]*)\) => (.+)$", line)
            if m !== nothing
                desc = m[2]
                if Sys.WORD_SIZE != 32 && !isempty(arch)
                    occursin(arch, desc) || continue
                end
                for wrong in arch_wrong
                    occursin(wrong, desc) && continue
                end
                sonames[m[1]] = m[3]
            end
        end
        have_sonames[] = true
    end
    end
else
    function read_sonames()
        empty!(sonames)
        for line in eachline(`ldconfig -r`)
            m = match(r"^\s+\d+:-l([^ ]+)\.[^. ]+ => (.+)$", line)
            if m !== nothing
                sonames["lib" * m[1]] = m[2]
            end
        end
        have_sonames[] = true
    end
end

if VERSION >= v"0.7.0-DEV.1287" # only use this where julia issue #22832 is fixed
    lookup_soname(s) = lookup_soname(String(s))
    function lookup_soname(s::String)
        have_sonames[] || read_sonames()
        return get(sonames, s, "")
    end
else
    function lookup_soname(lib)
        if Sys.islinux() || (Sys.isbsd() && !Sys.isapple())
            soname = ccall(:jl_lookup_soname, Ptr{UInt8}, (Ptr{UInt8}, Csize_t), lib, sizeof(lib))
            soname != C_NULL && return unsafe_string(soname)
        end
        return ""
    end
end

generate_steps(h::DependencyProvider,dep::LibraryDependency) = error("Must also pass provider options")
generate_steps(h::BuildProcess,dep::LibraryDependency,opts) = h.steps
function generate_steps(dep::LibraryDependency,h::AptGet,opts)
    if get(opts,:force_rebuild,false)
        error("Will not force apt-get to rebuild dependency \"$(dep.name)\".\n"*
              "Please make any necessary adjustments manually (This might just be a version upgrade)")
    end
    sudo = get(opts, :sudo, has_sudo[]) ? `sudo` : ``
    @build_steps begin
        println("Installing dependency $(h.package) via `$(sudoname(sudo))apt-get install $(h.package)`:")
        `$sudo apt-get install $(h.package)`
        reread_sonames
    end
end
function generate_steps(dep::LibraryDependency,h::Yum,opts)
    if get(opts,:force_rebuild,false)
        error("Will not force yum to rebuild dependency \"$(dep.name)\".\n"*
              "Please make any necessary adjustments manually (This might just be a version upgrade)")
    end
    sudo = get(opts, :sudo, has_sudo[]) ? `sudo` : ``
    @build_steps begin
        println("Installing dependency $(h.package) via `$(sudoname(sudo))yum install $(h.package)`:")
        `$sudo yum install $(h.package)`
        reread_sonames
    end
end
function generate_steps(dep::LibraryDependency,h::Pacman,opts)
    if get(opts,:force_rebuild,false)
        error("Will not force pacman to rebuild dependency \"$(dep.name)\".\n"*
              "Please make any necessary adjustments manually (This might just be a version upgrade)")
    end
    sudo = get(opts, :sudo, has_sudo[]) ? `sudo` : ``
    @build_steps begin
        println("Installing dependency $(h.package) via `$(sudoname(sudo))pacman -S --needed $(h.package)`:")
        `$sudo pacman -S --needed $(h.package)`
        reread_sonames
    end
end
function generate_steps(dep::LibraryDependency,h::Zypper,opts)
    if get(opts,:force_rebuild,false)
        error("Will not force zypper to rebuild dependency \"$(dep.name)\".\n"*
              "Please make any necessary adjustments manually (This might just be a version upgrade)")
    end
    sudo = get(opts, :sudo, has_sudo[]) ? `sudo` : ``
    @build_steps begin
        println("Installing dependency $(h.package) via `$(sudoname(sudo))zypper install $(h.package)`:")
        `$sudo zypper install $(h.package)`
        reread_sonames
    end
end
function generate_steps(dep::LibraryDependency, p::BSDPkg, opts)
    if get(opts, :force_rebuild, false)
        error("Will not force pkg to rebuild dependency \"$(dep.name)\".\n" *
              "Please make any necessary adjustments manually. (This might just be a version upgrade.)")
    end
    sudo = get(opts, :sudo, has_sudo[]) ? `sudo` : ``
    @build_steps begin
        println("Installing dependency $(p.package) via `$(sudoname(sudo))pkg install -y $(p.package)`:`")
        `$sudo pkg install -y $(p.package)`
        reread_sonames
    end
end
function generate_steps(dep::LibraryDependency,h::NetworkSource,opts)
    localfile = joinpath(downloadsdir(dep),get(opts,:filename,basename(h.uri.path)))
    @build_steps begin
        FileDownloader(string(h.uri),localfile)
        ChecksumValidator(get(opts,:SHA,get(opts,:sha,"")),localfile)
        CreateDirectory(srcdir(dep))
        FileUnpacker(localfile,srcdir(dep),srcdir(dep,h,opts))
    end
end
function generate_steps(dep::LibraryDependency,h::RemoteBinaries,opts)
    get(opts,:force_rebuild,false) && error("Force rebuild not allowed for binaries. Use a different download location instead.")
    localfile = joinpath(downloadsdir(dep),get(opts,:filename,basename(h.uri.path)))
    # choose the destination to unpack into and the folder/file to validate
    (dest, target) = if haskey(opts, :unpacked_dir)
        if opts[:unpacked_dir] == "."
            # if the archive dumps right in the root dir, create a subdir
            (joinpath(depsdir(dep), dep.name), ".")
        else
            (depsdir(dep), opts[:unpacked_dir])
        end
    else
        (depsdir(dep), "usr")
    end
    steps = @build_steps begin
        FileDownloader(string(h.uri),localfile)
        ChecksumValidator(get(opts,:SHA,get(opts,:sha,"")),localfile)
        FileUnpacker(localfile,dest,target)
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
    ret = Any[]
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

# convert aliases="foo" into aliases=["foo"] to avoid iterating over characters 'f' 'o' 'o'
stringarray(s::AbstractString) = [s]
stringarray(s) = s

function generate_steps(dep::LibraryDependency,method)
    (p,opts) = getoneprovider(dep,method)
    p !== nothing && return generate_steps(p,dep,opts)
    (p,hopts) = gethelper(dep,method)
    p !== nothing && return generate_steps(p,dep,hopts)
    error("No provider or helper for method $method found for dependency $(dep.name)")
end

function generate_steps(dep::LibraryDependency, h::Autotools,  provider_opts)
    if h.source === nothing
        h.source = gethelper(dep,Sources)
    end
    if isa(h.source,Sources)
        h.source = (h.source,Dict{Symbol,Any}())
    end
    h.source[1] === nothing && error("Could not obtain sources for dependency $(dep.name)")
    steps = lower(generate_steps(dep,h.source...))
    opts = Dict()
    opts[:srcdir]   = srcdir(dep,h.source...)
    opts[:prefix]   = usrdir(dep)
    opts[:builddir] = joinpath(builddir(dep),dep.name)
    merge!(opts,h.opts)
    if haskey(opts,:installed_libname)
        !haskey(opts,:installed_libpath) || error("Can't specify both installed_libpath and installed_libname")
        opts[:installed_libpath] = String[joinpath(libdir(dep),opts[:installed_libname])]
        delete!(opts, :installed_libname)
    elseif !haskey(opts,:installed_libpath)
        opts[:installed_libpath] = String[joinpath(libdir(dep),x)*"."*Libdl.dlext for x in stringarray(get(dep.properties,:aliases,String[]))]
    end
    if !haskey(opts,:libtarget) && haskey(dep.properties,:aliases)
        opts[:libtarget] = String[x*"."*Libdl.dlext for x in stringarray(dep.properties[:aliases])]
    end
    if !haskey(opts,:include_dirs)
        opts[:include_dirs] = AbstractString[]
    end
    if !haskey(opts,:lib_dirs)
        opts[:lib_dirs] = AbstractString[]
    end
    if !haskey(opts,:pkg_config_dirs)
        opts[:pkg_config_dirs] = AbstractString[]
    end
    if !haskey(opts,:rpath_dirs)
        opts[:rpath_dirs] = AbstractString[]
    end
    if haskey(opts,:configure_subdir)
        opts[:srcdir] = joinpath(opts[:srcdir],opts[:configure_subdir])
        delete!(opts, :configure_subdir)
    end
    pushfirst!(opts[:include_dirs],includedir(dep))
    pushfirst!(opts[:lib_dirs],libdir(dep))
    pushfirst!(opts[:rpath_dirs],libdir(dep))
    pushfirst!(opts[:pkg_config_dirs],joinpath(libdir(dep),"pkgconfig"))
    env = Dict{String,String}()
    env["PKG_CONFIG_PATH"] = join(opts[:pkg_config_dirs],":")
    delete!(opts,:pkg_config_dirs)
    if Sys.isunix()
        env["PATH"] = bindir(dep)*":"*ENV["PATH"]
    elseif Sys.iswindows()
        env["PATH"] = bindir(dep)*";"*ENV["PATH"]
    end
    haskey(opts,:env) && merge!(env,opts[:env])
    opts[:env] = env
    if get(provider_opts,:force_rebuild,false)
        opts[:force_rebuild] = true
    end
    steps |= AutotoolsDependency(;opts...)
    steps
end

const EXTENSIONS = ["", "." * Libdl.dlext]

# Finds all copies of the library on the system, listed in preference order.
# Return value is an array of tuples of the provider and the path where it is found
function _find_library(dep::LibraryDependency; provider = Any)
    ret = Any[]
    # Same as find_library, but with extra check defined by dep
    libnames = [dep.name;get(dep.properties,:aliases,String[])]
    # Make sure we keep the defaults first, but also look in the other directories
    providers = unique([reduce(vcat,[getallproviders(dep,p) for p in defaults]);dep.providers])
    for (p,opts) in providers
        (p !== nothing && can_use(typeof(p)) && can_provide(p,opts,dep)) || continue
        paths = AbstractString[]

        # Allow user to override installation path
        if haskey(opts,:installed_libpath) && isdir(opts[:installed_libpath])
            pushfirst!(paths,opts[:installed_libpath])
        end

        ppaths = libdir(p,dep)
        append!(paths,isa(ppaths,Array) ? ppaths : [ppaths])

        if haskey(opts,:unpacked_dir)
            dir = opts[:unpacked_dir]
            if dir == "." && isdir(joinpath(depsdir(dep), dep.name))
                # the archive unpacks into the root, so we created a subdir with the dep name
                push!(paths, joinpath(depsdir(dep), dep.name))
            elseif isdir(joinpath(depsdir(dep),dir))
                push!(paths,joinpath(depsdir(dep),dir))
            end
        end

        # Windows, do you know what `lib` stands for???
        if Sys.iswindows()
            push!(paths,bindir(p,dep))
        end
        (isempty(paths) || all(map(isempty,paths))) && continue
        for lib in libnames, path in paths
            l = joinpath(path, lib)
            h = Libdl.dlopen_e(l, Libdl.RTLD_LAZY)
            if h != C_NULL
                works = dep.libvalidate(l,h)
                l = Libdl.dlpath(h)
                Libdl.dlclose(h)
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
    # Now check system libraries
    for lib in libnames
        # We don't want to use regular dlopen, because we want to get at
        # system libraries even if one of our providers is higher in the
        # DL_LOAD_PATH
        for path in Libdl.DL_LOAD_PATH
            for ext in EXTENSIONS
                opath = string(joinpath(path,lib),ext)
                check_path!(ret,dep,opath)
            end
        end
        for ext in EXTENSIONS
            opath = string(lib,ext)
            check_path!(ret,dep,opath)
        end
        soname = lookup_soname(lib)
        isempty(soname) || check_path!(ret, dep, soname)
    end
    return ret
end

function check_path!(ret, dep, opath)
    flags = Libdl.RTLD_LAZY
    handle = ccall(:jl_dlopen, Ptr{Cvoid}, (Cstring, Cuint), opath, flags)
    try
        check_system_handle!(ret, dep, handle)
    finally
        handle != C_NULL && Libdl.dlclose(handle)
    end
end

function check_system_handle!(ret,dep,handle)
    if handle != C_NULL
        libpath = Libdl.dlpath(handle)
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
            push!(ret, ((SystemPaths(),Dict()), libpath))
        end
    end
end

# Default installation method
defaults = if Sys.isapple()
    [Binaries, PackageManager, SystemPaths, BuildProcess]
elseif Sys.isbsd() || (Sys.islinux() && glibc_version() === nothing) # non-glibc
    [PackageManager, SystemPaths, BuildProcess]
elseif Sys.islinux() # glibc
    [PackageManager, SystemPaths, Binaries, BuildProcess]
elseif Sys.iswindows()
    [Binaries, PackageManager, SystemPaths]
else
    [SystemPaths, BuildProcess]
end

function applicable(dep::LibraryDependency)
    if haskey(dep.properties,:os)
        if (dep.properties[:os] != OSNAME && dep.properties[:os] != :Unix) || (dep.properties[:os] == :Unix && !Sys.isunix())
            return false
        end
    elseif haskey(dep.properties,:runtime) && dep.properties[:runtime] == false
        return false
    end
    return true
end

applicable(deps::LibraryGroup) = any([applicable(dep) for dep in deps.deps])

function can_provide(p,opts,dep)
    if p === nothing || (haskey(opts,:os) && opts[:os] != OSNAME && (opts[:os] != :Unix || !Sys.isunix()))
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
    if p === nothing || (haskey(opts,:os) && opts[:os] != OSNAME && (opts[:os] != :Unix || !Sys.isunix()))
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

allf(deps) = Dict([(dep, _find_library(dep)) for dep in deps.deps])
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
        if vp === nothing
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
        return Dict()
    else
        for p2 in providers
            if p2 <: provider
                p = p2
            end
        end
    end
    p === nothing && error("Given provider does not satisfy the library group")
    Dict([(dep, begin
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
    end) for dep in filter(applicable,deps.deps)])
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
            !issatisfied(dep) && error("Provider $method failed to satisfy dependency $(dep.name). Maybe you forgot to declare an alias in a library_dependency?")
            return p
        end
    end
    error("""
        None of the selected providers can install dependency $(dep.name).
        Use BinDeps.debug(package_name) to see available providers
        """)
end

execute(dep::LibraryDependency,method) = run(lower(generate_steps(dep,method)))

macro install(_libmaps...)
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
                    pre_hooks = Set{$AbstractString}()
                    load_hooks = Set{$AbstractString}()
                    if bindeps_context.do_install
                        for d in bindeps_context.deps
                            p = BinDeps.satisfy!(d)
                            libs = BinDeps._find_library(d; provider = p)
                            if isa(d, BinDeps.LibraryGroup)
                                if !isempty(libs)
                                    for dep in d.deps
                                        !BinDeps.applicable(dep) && continue
                                        if !haskey(load_cache, dep.name)
                                            load_cache[dep.name] = libs[dep][2]
                                            opts = libs[dep][1][2]
                                            haskey(opts, :preload) && push!(pre_hooks,opts[:preload])
                                            haskey(opts, :onload) && push!(load_hooks,opts[:onload])
                                        end
                                    end
                                end
                            else
                                for (k,v) in libs
                                    if !haskey(load_cache, d.name)
                                        load_cache[d.name] = v
                                        opts = k[2]
                                        haskey(opts, :preload) && push!(pre_hooks,opts[:preload])
                                        haskey(opts, :onload) && push!(load_hooks,opts[:onload])
                                    end
                                end
                            end
                        end

                        # Generate "deps.jl" file for runtime loading
                        depsfile_location = joinpath(splitdir(Base.source_path())[1],"deps.jl")
                        depsfile_buffer = IOBuffer()
                        println(depsfile_buffer,
                            """
                            # This is an auto-generated file; do not edit and do not check-in to version control
                            """)
                        println(depsfile_buffer, "# Pre-hooks")
                        println(depsfile_buffer, join(pre_hooks, "\n"))
                        println(depsfile_buffer,
                            """
                            if VERSION >= v"0.7.0-DEV.3382"
                                using Libdl
                            end
                            # Macro to load a library
                            macro checked_lib(libname, path)
                                if Libdl.dlopen_e(path) == C_NULL
                                    error("Unable to load \\n\\n\$libname (\$path)\\n\\nPlease ",
                                          "re-run Pkg.build(package), and restart Julia.")
                                end
                                quote
                                    const \$(esc(libname)) = \$path
                                end
                            end
                            """)
                        println(depsfile_buffer, "# Load dependencies")
                        for libkey in keys($libmaps)
                            ((cached = get(load_cache,string(libkey),nothing)) === nothing) && continue
                            println(depsfile_buffer, "@checked_lib ", $libmaps[libkey], " \"", escape_string(cached), "\"")
                        end
                        println(depsfile_buffer)
                        println(depsfile_buffer, "# Load-hooks")
                        println(depsfile_buffer, join(load_hooks,"\n"))
                        depsfile_content = chomp(String(take!(depsfile_buffer)))
                        if !isfile(depsfile_location) || readchomp(depsfile_location) != depsfile_content
                            # only overwrite if deps.jl file does not yet exist or content has changed
                            open(depsfile_location, "w") do depsfile
                                println(depsfile, depsfile_content)
                            end
                        end
                    end
                end))
        if !(typeof(libmaps) <: AbstractDict)
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
#  1. Vector{Symbol} or Vector{T <: AbstractString}
#       Only load that are declared whose name is listed in the Array
#       E.g. @load_dependencies "file.jl" [:cairo, :tk]
#
#  2. AbstractDict{S<:Union{Symbol,AbstractString},S<:Union{Symbol,AbstractString}}
#       Only loads libraries whose name matches a key in the AbstractDict collection, but assigns it
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
        elseif typeof(args[1]) <: AbstractString
            file = args[1]
            dir = dirname(normpath(joinpath(dirname(file),"..")))
        elseif typeof(args[1]) <: AbstractDict || isa(args[1],Vector)
            arg1 = args[1]
        else
            error("Type $(typeof(args[1])) not recognized for argument 1. See usage instructions!")
        end
    elseif length(args) == 2
        file = args[1]
        arg1 = typeof(args[2]) <: AbstractDict || isa(args[2],Vector) ? args[2] : eval(args[2])
    elseif length(args) != 0
        error("No version of @load_dependencies takes $(length(args)) arguments. See usage instructions!")
    end
    pkg = ""
    r = findfirst(Pkg.Dir.path(), dir)
    if r !== nothing
        s = findnext("/", dir, last(r)+2)
        if s !== nothing
            pkg = dir[(last(r)+2):(first(s)-1)]
        else
            pkg = dir[(last(r)+2):end]
        end
    end
    context = BinDeps.PackageContext(false,dir,pkg,Any[])
    eval_anon_module(context, file)
    ret = Expr(:block)
    for dep in context.deps
        if !applicable(dep)
            continue
        end
        name = sym = dep.name
        if arg1 !== nothing
            if (typeof(arg1) <: AbstractDict) && all(map(x->(x == Symbol || x <: AbstractString),eltype(arg1)))
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
            elseif isa(arg1,Vector) && ((eltype(arg1) == Symbol) || (eltype(arg1) <: AbstractString))
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
                if !arg1(name)
                    continue
                end
            else
                error("Can't deal with argument type $(typeof(arg1)). See usage instructions!")
            end
        end
        s = Symbol(sym)
        errorcase = Expr(:block)
        push!(errorcase.args,:(error("Could not load library "*$(dep.name)*". Try running Pkg.build() to install missing dependencies!")))
        push!(ret.args,quote
            const $(esc(s)) = BinDeps._find_library($dep)
            if isempty($(esc(s)))
                $errorcase
            end
        end)
    end
    if arg1 !== nothing && !isa(arg1,Function)
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

function build(pkg::AbstractString, method; dep::AbstractString="", force=false)
    dir = Pkg.dir(pkg)
    file = joinpath(dir,"deps/build.jl")
    context = BinDeps.PackageContext(false,dir,pkg,Any[])
    eval_anon_module(context, file)
    for d in context.deps
        BinDeps.satisfy!(d,[method])
    end
end

# Calculate the SHA-256 hash of a file
using SHA

function sha_check(path, sha)
    open(path) do f
        calc_sha = sha256(f)
        # Workaround for SHA.jl API change.  Safe to remove once SHA versions
        # < v0.2.0 are rare, e.g. when Julia v0.4 is deprecated.
        if !isa(calc_sha, AbstractString)
            calc_sha = bytes2hex(calc_sha)
        end
        if calc_sha != sha
            error("Checksum mismatch!  Expected:\n$sha\nCalculated:\n$calc_sha\nDelete $path and try again")
        end
    end
end
