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
	helpers::Vector{DependencyHelper}
	properties::Dict{Symbol,Any}
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
sourcesdir(dep) = joinpath(depsdir(dep),"src")

function library_dependency(context::PackageContext, name; properties...)
	r = LibraryDependency(name,context,Array((DependencyProvider,Dict{Symbol,Any}),0),DependencyHelper[],(Symbol=>Any)[name => value for (name,value) in properties])
	push!(context.deps,r)
	r
end

# This macro expects to be the first thing run. It attempts to deduce the package name and initializes the context
macro setup()
	dir = pwd()
	package = basename(pwd())
	esc(quote
		if length(ARGS) > 0 && isa(ARGS[1],BinDeps.PackageContext)
			bindeps_context = ARGS[1]
		else
			bindeps_context = BinDeps.PackageContext(true,$dir,$package,{})
		end
		library_dependency(args...; properties...) = BinDeps.library_dependency(bindeps_context,args...;properties...)
	end)
end

macro if_install(expr)
	esc(quote
		if bindeps_context.do_install
			$expr
		end
	end)
end
	
library_dependency(args...; properties...) = error("No context provided. Did you forget `@Bindeps.setup`?")

abstract PackageManager <: DependencyProvider

const has_homebrew = try success(`brew -v`) catch e false end

type Homebrew <: PackageManager 
	inst::HomebrewInstall
end
Homebrew(pkg::String) = Homebrew(HomebrewInstall(pkg,ASCIIString[]))
can_use(::Type{Homebrew}) = has_homebrew && OS_NAME == :Darwin

const has_apt = try success(`apt-get -v`) catch e false end
type AptGet <: PackageManager 
	package::String
end
can_use(::Type{AptGet}) = has_apt && OS_NAME == :Linux

const has_yum = try success(`yum -v`) catch e false end
type Yum <: PackageManager
	package::String
end
can_use(::Type{Yum}) = has_yum && OS_NAME == :Linux

# Can use everything else without restriction by default
can_use(::Type) = true

abstract Sources <: DependencyHelper
abstract Binaries <: DependencyProvider

using URIParser
export URI

type NetworkSource <: Sources
	uri::URI
end

srcdir(s::NetworkSource, dep::LibraryDependency) = joinpath(sourcesdir(dep),splittarpath(basename(s.uri.path))[1])

type RemoteBinaries <: Binaries
	uri::URI
end

abstract BuildProcess <: DependencyProvider

type SimpleBuild <: BuildProcess
	steps
end

type Autotools <: BuildProcess
	source::Union(Sources,Nothing)
	opts
end

type GetSources <: BuildStep
	dep::LibraryDependency
end

lower(x::GetSources,collection) = push!(collection,generate_steps(gethelper(x.dep,Sources),x.dep))

Autotools(;opts...) = Autotools(nothing,{k => v for (k,v) in opts})

export Homebrew, AptGet, Yum, Sources, Binaries, provides, BuildProcess, Autotools, GetSources, SimpleBuild

provider{T<:PackageManager}(::Type{T},package::String; opts...) = T(package)
provider(::Type{Sources},uri::URI; opts...) = NetworkSource(uri)
provider(::Type{Binaries},uri::URI; opts...) = RemoteBinaries(uri)
provider(::Type{SimpleBuild},steps; opts...) = SimpleBuild(steps)
provider{T<:BuildProcess}(::Type{BuildProcess},p::T; opts...) = provider(T,p; opts...)
provider(::Type{BuildProcess},steps::Union(BuildStep,SynchronousStepCollection); opts...) = provider(SimpleBuild,steps; opts...)
provider(::Type{Autotools},a::Autotools; opts...) = a

provides(provider::DependencyProvider,dep::LibraryDependency; opts...) = push!(dep.providers,(provider,(Symbol=>Any)[k=>v for (k,v) in opts]))
provides(helper::DependencyHelper,dep::LibraryDependency; opts...) = push!(dep.helpers,helper)
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

generate_steps(h::BuildProcess,dep::LibraryDependency) = h.steps
generate_steps(h::Homebrew,dep::LibraryDependency) = h.inst
generate_steps(h::AptGet,dep::LibraryDependency) = `sudo apt-get install $(h.package)`
generate_steps(h::Yum,dep::LibraryDependency) = `sudo yum install $(h.package)`
function generate_steps(h::NetworkSource,dep::LibraryDependency) 
	localfile = joinpath(downloadsdir(dep),basename(h.uri.path))
	@build_steps begin
		FileDownloader(string(h.uri),localfile)
		CreateDirectory(sourcesdir(dep))
		FileUnpacker(localfile,joinpath(sourcesdir(dep)),"")
	end
end
function generate_steps(h::RemoteBinaries,dep::LibraryDependency) 
	localfile = joinpath(downloadsdir(dep),basename(h.uri.path))
	@build_steps begin
		FileDownloader(string(h.uri),localfile)
		FileUnpacker(localfile,usrdir(dep)," ")
	end
end

function getprovider(dep::LibraryDependency,method)
	for (p,opts) = dep.providers
		if typeof(p) <: method && can_use(typeof(p))
			return (p,opts)
		end
	end
	return (nothing,nothing)
end

function gethelper(dep::LibraryDependency,method)
	for p = dep.helpers
		if typeof(p) <: method
			return p
		end
	end
	return nothing
end

function generate_steps(dep::LibraryDependency,method)
	(p,opts) = getprovider(dep,method)
	!is(p,nothing) && return generate_steps(p,dep)
	p = gethelper(dep,method)
	!is(p,nothing) && return generate_steps(p,dep)
	error("No provider or helper for method $method found for dependency $(dep.name)")
end

function generate_steps(h::Autotools, dep::LibraryDependency)
	dump(dep.providers)
	if is(h.source, nothing) 
		h.source = gethelper(dep,Sources)
	end
	is(h.source, nothing) && error("Could not obtain sources for dependency $(dep.name)")
	steps = lower(generate_steps(h.source,dep))
	opts = {:srcdir=>srcdir(h.source,dep), :prefix=>usrdir(dep), :builddir=>joinpath(builddir(dep),dep.name)}
	merge!(opts,h.opts)
	if haskey(opts,:installed_libname)
		!haskey(opts,:installed_libpath) || error("Can't specify both installed_libpath and installed_libname")
		opts[:installed_libpath] = ByteString[joinpath(libdir(dep),delete!(opts,:installed_libname))]
	elseif !haskey(opts,:installed_libpath)
		opts[:installed_libpath] = ByteString[joinpath(libdir(dep),x)*"."*shlib_ext for x in get(dep.properties,:aliases,ByteString[])]
	end
	if !haskey(opts,:libtarget) && haskey(dep.properties,:aliases)
		opts[:libtarget] = ByteString[x*"."*shlib_ext for x in dep.properties[:aliases]]
	end
	if !haskey(opts,:include_dirs)
		opts[:include_dirs] = String[]
	end
	if !haskey(opts,:lib_dirs)
		opts[:include_dirs] = String[]
	end
	push!(opts[:include_dirs],includedir(dep))
	push!(opts[:lib_dirs],libdir(dep))
	env = Dict{ByteString,ByteString}()
	env["PKG_CONFIG_PATH"] = env["PKG_CONFIG_LIBDIR"] = joinpath(libdir(dep),"pkgconfig")
	@unix_only env["PATH"] = bindir(dep)*":"*ENV["PATH"]
	@windows_only env["PATH"] = bindir(dep)*";"*ENV["PATH"]
	haskey(opts,:env) && merge!(env,opts[:env])
	opts[:env] = env
	steps |= AutotoolsDependency(;opts...) 
	steps
end

function issatisfied(dep::LibraryDependency)
	Base.find_library([dep.name,get(dep.properties,:aliases,ASCIIString[])],[libdir(dep)]) != ""
end

# Default installation method
if OS_NAME == :Darwin
	defaults = [Binaries,BuildProcess]
elseif OS_NAME == :Linux
	defaults = [PackageManager,BuildProcess]
elseif OS_NAME == :Windows
	defaults = [Binaries]
else
	defaults = [BuildProcess]
end

applicable(dep) = !haskey(dep.properties,:os) || (dep.properties[:os] == OS_NAME || (dep.properties[:os] == :Unix && Base.is_unix(OS_NAME)))

function satisfy!(dep::LibraryDependency)
	if !issatisfied(dep) 
		if !applicable(dep)
			return
		end
		for method in defaults
			(p,opts) = getprovider(dep,method)
			if p === nothing || (haskey(opts,:os) && opts[:os] != OS_NAME && (opts[:os] != :Unix || !Base.is_unix(OS_NAME)))
				continue
			end
			run(lower(generate_steps(p,dep)))
			!issatisfied(dep) && error("Provider $method failed to satisfy dependency $(dep.name)")
			return
		end
		error("None of the selected providers can install dependency $(dep.name)")
	end
end

execute(dep::LibraryDependency,method) = run(lower(generate_steps(dep,method)))

macro install()
	esc(quote
		if bindeps_context.do_install
			for d in bindeps_context.deps
				BinDeps.satisfy!(d)
			end
			isdefined(Pkg2,:markworking) && Pkg2.markworking(bindeps_context.package)
		end	end)
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
#		Only load that are declared whose name is listed in the Array
#		E.g. @load_dependencies "file.jl" [:cairo, :tk]
#
#  2. Associative{S<:Union(Symbol,String),S<:Union(Symbol,String)}
# 		Only loads libraries whose name matches a key in the Associative collection, but assigns it
#		to the name matiching the corresponsing value
#		E.g. @load_dependencies "file.jl" [:cairo=>:libcairo, :tk=>:libtk]
#		will assign the result of the lookup for :cairo and :tk to the variables `libcairo` and `libtk`
#		respectively.
# 
#  3. Function
#		A filter function
#		E.g. @load_dependencies "file.jl" x->x=="tk"
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
	r = search(dir,Pkg2.Dir.path())
	if r != 0:-1
		s = search(dir,"/",last(r)+2)
		if s != 0:-1
			pkg = dir[(last(r)+2):(first(s)-1)]
		else
			pkg = dir[(last(r)+2):end]
		end
	end
	if pkg != "" && isdefined(Pkg2,:isworking) && !Pkg2.isworking(pkg)
		error("This package was marked as not working. Run Pkg2.fixup() to attempt to install any"*
			  " missing dependencies. You may have to exit Julia afterwards.")
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
				for need in keys(args1)
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
		pkg != "" && isdefined(Pkg2,:markworking) && push!(errorcase.args,:(Pkg2.markworking($pkg,false)))
		push!(errorcase.args,:(error("Could not load library "*$(dep.name)*". Try running Pkg2.fixup() to install missing dependencies!")))
		push!(ret.args,quote
			const $(esc(s)) = Base.find_library([$(dep.name),$(get(dep.properties,:aliases,ASCIIString[]))],[$(libdir(dep))])
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
