__precompile__()

module BinDeps

using Libdl
using Pkg

export @build_steps, find_library, download_cmd, unpack_cmd,
    Choice, Choices, CCompile, FileDownloader, FileRule,
    ChangeDirectory, FileUnpacker, prepare_src,
    autotools_install, CreateDirectory, MakeTargets,
    MAKE_CMD, glibc_version

function find_library(pkg,libname,files)
    Base.warn_once("BinDeps.find_library is deprecated; use Base.find_library instead.")
    dl = C_NULL
    for filename in files
        dl = Libdl.dlopen_e(joinpath(Pkg.dir(),pkg,"deps","usr","lib",filename))
        if dl != C_NULL
            ccall(:add_library_mapping,Cint,(Ptr{Cchar},Ptr{Cvoid}),libname,dl)
            return true
        end

        dl = Libdl.dlopen_e(filename)
        if dl != C_NULL
            ccall(:add_library_mapping,Cint,(Ptr{Cchar},Ptr{Cvoid}),libname,dl)
            return true
        end
    end

    dl = Libdl.dlopen_e(libname)
    dl != C_NULL ? true : false
end

macro make_rule(condition,command)
    quote
        if(!$(esc(condition)))
            $(esc(command))
            @assert $(esc(condition))
        end
    end
end

abstract type BuildStep end

downloadcmd = nothing
function download_cmd(url::AbstractString, filename::AbstractString)
    global downloadcmd
    if downloadcmd === nothing
        for download_engine in (Sys.iswindows() ? ("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell",
                :powershell, :curl, :wget, :fetch) : (:curl, :wget, :fetch))
            if endswith(string(download_engine), "powershell")
                checkcmd = `$download_engine -NoProfile -Command ""`
            else
                checkcmd = `$download_engine --help`
            end
            try
                if success(checkcmd)
                    downloadcmd = download_engine
                    break
                end
            catch
                continue # don't bail if one of these fails
            end
        end
    end
    if downloadcmd == :wget
        return `$downloadcmd -O $filename $url`
    elseif downloadcmd == :curl
        return `$downloadcmd -f -o $filename -L $url`
    elseif downloadcmd == :fetch
        return `$downloadcmd -f $filename $url`
    elseif endswith(string(downloadcmd), "powershell")
        tls_cmd = "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
        download_cmd = "(new-object net.webclient).DownloadFile(\"$(url)\", \"$(filename)\")"
        return `$downloadcmd -NoProfile -Command "$(tls_cmd); $(download_cmd)"`
    else
        extraerr = Sys.iswindows() ? "check if powershell is on your path or " : ""
        error("No download agent available; $(extraerr)install curl, wget, or fetch.")
    end
end

if Sys.isunix() && Sys.KERNEL != :FreeBSD
    function unpack_cmd(file,directory,extension,secondary_extension)
        if ((extension == ".gz" || extension == ".Z") && secondary_extension == ".tar") || extension == ".tgz"
            return (`tar xzf $file --directory=$directory`)
        elseif (extension == ".bz2" && secondary_extension == ".tar") || extension == ".tbz"
            return (`tar xjf $file --directory=$directory`)
        elseif extension == ".xz" && secondary_extension == ".tar"
            return pipeline(`unxz -c $file `, `tar xv --directory=$directory`)
        elseif extension == ".tar"
            return (`tar xf $file --directory=$directory`)
        elseif extension == ".zip"
            return (`unzip -x $file -d $directory`)
        elseif extension == ".gz"
            return pipeline(`mkdir $directory`, `cp $file $directory`, `gzip -d $directory/$file`)
        end
        error("I don't know how to unpack $file")
    end
end

if Sys.KERNEL == :FreeBSD
    # The `tar` on FreeBSD can auto-detect the archive format via libarchive.
    # The supported formats can be found in libarchive-formats(5).
    # For NetBSD and OpenBSD, libarchive is not available.
    # For macOS, it is. But the previous unpack function works fine already.
    function unpack_cmd(file, dir, ext, secondary_ext)
        tar_args = ["--no-same-owner", "--no-same-permissions"]
        return pipeline(
            `mkdir -p $dir`,
            `tar -xf $file -C $dir $tar_args`)
    end
end

if Sys.iswindows()
    if isdefined(Base, :LIBEXECDIR)
        const exe7z = joinpath(Sys.BINDIR, Base.LIBEXECDIR, "7z.exe")
    else
        const exe7z = joinpath(Sys.BINDIR, "7z.exe")
    end

    function unpack_cmd(file,directory,extension,secondary_extension)
        if ((extension == ".Z" || extension == ".gz" || extension == ".xz" || extension == ".bz2") &&
                secondary_extension == ".tar") || extension == ".tgz" || extension == ".tbz"
            return pipeline(`$exe7z x $file -y -so`, `$exe7z x -si -y -ttar -o$directory`)
        elseif (extension == ".zip" || extension == ".7z" || extension == ".tar" ||
                (extension == ".exe" && secondary_extension == ".7z"))
            return (`$exe7z x $file -y -o$directory`)
        end
        error("I don't know how to unpack $file")
    end
end

mutable struct SynchronousStepCollection
    steps::Vector{Any}
    cwd::AbstractString
    oldcwd::AbstractString
    SynchronousStepCollection(cwd) = new(Any[],cwd,cwd)
    SynchronousStepCollection() = new(Any[],"","")
end

import Base: push!, run, |
push!(a::SynchronousStepCollection,args...) = push!(a.steps,args...)

mutable struct ChangeDirectory <: BuildStep
    dir::AbstractString
end

mutable struct CreateDirectory <: BuildStep
    dest::AbstractString
    mayexist::Bool
    CreateDirectory(dest, me) = new(dest,me)
    CreateDirectory(dest) = new(dest,true)
end

struct RemoveDirectory <: BuildStep
    dest::AbstractString
end

mutable struct FileDownloader <: BuildStep
    src::AbstractString     # url
    dest::AbstractString    # local_file
end

mutable struct ChecksumValidator <: BuildStep
    sha::AbstractString
    path::AbstractString
end

mutable struct FileUnpacker <: BuildStep
    src::AbstractString     # archive file
    dest::AbstractString    # directory to unpack into
    target::AbstractString  # file or directory inside the archive to test
                            # for existence (or blank to check for a.tgz => a/)
end


mutable struct MakeTargets <: BuildStep
    dir::AbstractString
    targets::Vector{String}
    env::Dict
    MakeTargets(dir,target;env = Dict{AbstractString,AbstractString}()) = new(dir,target,env)
    MakeTargets(target::Vector{<:AbstractString};env = Dict{AbstractString,AbstractString}()) = new("",target,env)
    MakeTargets(target::String;env = Dict{AbstractString,AbstractString}()) = new("",[target],env)
    MakeTargets(;env = Dict{AbstractString,AbstractString}()) = new("",String[],env)
end

mutable struct AutotoolsDependency <: BuildStep
    src::AbstractString     #src direcory
    prefix::AbstractString
    builddir::AbstractString
    configure_options::Vector{AbstractString}
    libtarget::Vector{AbstractString}
    include_dirs::Vector{AbstractString}
    lib_dirs::Vector{AbstractString}
    rpath_dirs::Vector{AbstractString}
    installed_libpath::Vector{String} # The library is considered installed if any of these paths exist
    config_status_dir::AbstractString
    force_rebuild::Bool
    env
    AutotoolsDependency(;srcdir::AbstractString = "", prefix = "", builddir = "", configure_options=AbstractString[], libtarget = AbstractString[], include_dirs=AbstractString[], lib_dirs=AbstractString[], rpath_dirs=AbstractString[], installed_libpath = String[], force_rebuild=false, config_status_dir = "", env = Dict{String,String}()) =
        new(srcdir,prefix,builddir,configure_options,isa(libtarget,Vector) ? libtarget : AbstractString[libtarget],include_dirs,lib_dirs,rpath_dirs,installed_libpath,config_status_dir,force_rebuild,env)
end

### Choices

mutable struct Choice
    name::Symbol
    description::AbstractString
    step::SynchronousStepCollection
    Choice(name,description,step) = (s=SynchronousStepCollection();lower(step,s);new(name,description,s))
end

mutable struct Choices <: BuildStep
    choices::Vector{Choice}
    Choices() = new(Choice[])
    Choices(choices::Vector{Choice}) = new(choices)
end

push!(c::Choices, args...) = push!(c.choices, args...)

function run(c::Choices)
    println()
    @info("There are multiple options available for installing this dependency:")
    while true
        for x in c.choices
            println("- "*string(x.name)*": "*x.description)
        end
        while true
            print("Plese select the desired method: ")
            method = Symbol(chomp(readline(STDIN)))
            for x in c.choices
                if(method == x.name)
                    return run(x.step)
                end
            end
            @warn("Invalid method")
        end
    end
end

mutable struct CCompile <: BuildStep
    srcFile::AbstractString
    destFile::AbstractString
    options::Vector{String}
    libs::Vector{String}
end

lower(cc::CCompile,c) = lower(FileRule(cc.destFile,`gcc $(cc.options) $(cc.srcFile) $(cc.libs) -o $(cc.destFile)`),c)
##

mutable struct DirectoryRule <: BuildStep
    dir::AbstractString
    step
end

mutable struct PathRule <: BuildStep
    path::AbstractString
    step
end

function meta_lower(a::Expr,blk::Expr,collection)
    if(a.head == :block || a.head == :tuple)
        for x in a.args
            if(isa(x,Expr))
                if(x.head == :block)
                    new_collection = gensym()
                    push!(blk.args,quote
                        $(esc(new_collection)) = SynchronousStepCollection($(esc(collection)).cwd)
                        push!($(esc(collection)),$(esc(new_collection)))
                    end)
                    meta_lower(x,blk,new_collection)
                 elseif(x.head != :line)
                     push!(blk.args,quote
                         lower($(esc(x)), $(esc(collection)))
                     end)
                 end
            elseif(!isa(x,LineNumberNode))
                meta_lower(x,blk,collection)
            end
        end
    else
        push!(blk.args,quote
            $(esc(collection)),lower($(esc(a)), $(esc(collection)))
        end)
    end
end

function meta_lower(a::Tuple,blk::Expr,collection)
    for x in a
        meta_lower(a,blk,collection)
    end
end

function meta_lower(a,blk::Expr,collection)
    push!(blk.args,quote
        $(esc(collection)), lower($(esc(a)), $(esc(collection)))
    end)
end

macro dependent_steps(steps)
    blk = Expr(:block)
    meta_lower(steps,blk,:collection)
    blk
end

macro build_steps(steps)
    collection = gensym()
    blk = Expr(:block)
    push!(blk.args,quote
        $(esc(collection)) = SynchronousStepCollection()
    end)
    meta_lower(steps,blk,collection)
    push!(blk.args, quote; $(esc(collection)); end)
    blk
end

src(b::BuildStep) = b.src
dest(b::BuildStep) = b.dest

(|)(a::BuildStep,b::BuildStep) = SynchronousStepCollection()
function (|)(a::SynchronousStepCollection,b::SynchronousStepCollection)
    if a.cwd == b.cwd
        append!(a.steps,b.steps)
    else
        push!(a.steps,b)
    end
    a
end
(|)(a::SynchronousStepCollection,b::Function) = (lower(b,a);a)
(|)(a::SynchronousStepCollection,b) = (lower(b,a);a)

(|)(b::Function,a::SynchronousStepCollection) = (c=SynchronousStepCollection(); ((c|b)|a))
(|)(b,a::SynchronousStepCollection) = (c=SynchronousStepCollection(); ((c|b)|a))

# Create any of these files
mutable struct FileRule <: BuildStep
    file::Array{AbstractString}
    step
    FileRule(file::AbstractString,step) = FileRule(AbstractString[file],step)
    function FileRule(files::Vector{AbstractString},step)
        new(files,@build_steps (step,) )
    end
end
FileRule(files::Vector{T},step) where {T <: AbstractString} = FileRule(AbstractString[f for f in files],step)

function lower(s::ChangeDirectory,collection)
    if !isempty(collection.steps)
        error("Change of directory must be the first instruction")
    end
    collection.cwd = s.dir
end
lower(s::Nothing,collection) = nothing
lower(s::Function,collection) = push!(collection,s)
lower(s::CreateDirectory,collection) = @dependent_steps ( DirectoryRule(s.dest,()->(mkpath(s.dest))), )
lower(s::RemoveDirectory,collection) = @dependent_steps ( `rm -rf $(s.dest)` )
lower(s::BuildStep,collection) = push!(collection,s)
lower(s::Base.AbstractCmd,collection) = push!(collection,s)
lower(s::FileDownloader,collection) = @dependent_steps (
    CreateDirectory(dirname(s.dest), true),
    ()->@info("Downloading file $(s.src)"),
    FileRule(s.dest, download_cmd(s.src, s.dest)),
    ()->@info("Done downloading file $(s.src)")
)
lower(s::ChecksumValidator,collection) = isempty(s.sha) || @dependent_steps ()->sha_check(s.path, s.sha)
function splittarpath(path)
    path,extension = splitext(path)
    base_filename,secondary_extension = splitext(path)
    if extension == ".tgz" || extension == ".tbz" || extension == ".zip" && !isempty(secondary_extension)
        base_filename *= secondary_extension
        secondary_extension = ""
    end
    (base_filename,extension,secondary_extension)
end
function lower(s::FileUnpacker,collection)
    base_filename,extension,secondary_extension = splittarpath(s.src)
    target = if isempty(s.target)
        basename(base_filename)
    elseif s.target == "."
        ""
    else
        s.target
    end
    @dependent_steps begin
        CreateDirectory(dirname(s.dest),true)
        PathRule(joinpath(s.dest,target),unpack_cmd(s.src,s.dest,extension,secondary_extension))
    end
end

adjust_env(env) = merge(ENV,env)  # s.env overrides ENV

if Sys.isunix()
    function lower(a::MakeTargets,collection)
        cmd = `make -j8`

        if Sys.KERNEL == :FreeBSD
            jobs = readchomp(`make -V MAKE_JOBS_NUMBER`)
            if isempty(jobs)
                jobs = readchomp(`sysctl -n hw.ncpu`)
            end
            # Tons of project have written their Makefile in GNU Make only syntax,
            # but the implementation of `make` on FreeBSD system base is `bmake`
            cmd = `gmake -j$jobs`
        end

        if !isempty(a.dir)
            cmd = `$cmd -C $(a.dir)`
        end
        if !isempty(a.targets)
            cmd = `$cmd $(a.targets)`
        end
        @dependent_steps ( setenv(cmd, adjust_env(a.env)), )
    end
end
Sys.iswindows() && (lower(a::MakeTargets,collection) = @dependent_steps ( setenv(`make $(!isempty(a.dir) ? "-C "*a.dir : "") $(a.targets)`, adjust_env(a.env)), ))
lower(s::SynchronousStepCollection,collection) = (collection|=s)

lower(s) = (c=SynchronousStepCollection();lower(s,c);c)

#run(s::MakeTargets) = run(@make_steps (s,))

function lower(s::AutotoolsDependency,collection)
    prefix = s.prefix
    if Sys.iswindows()
        prefix = replace(replace(s.prefix, "\\" => "/"), "C:/" => "/c/")
    end
    cmdstring = "pwd && ./configure --prefix=$(prefix) "*join(s.configure_options," ")

    env = adjust_env(s.env)

    for path in s.include_dirs
        if !haskey(env,"CPPFLAGS")
            env["CPPFLAGS"] = ""
        end
        env["CPPFLAGS"]*=" -I$path"
    end

    for path in s.lib_dirs
        if !haskey(env,"LDFLAGS")
            env["LDFLAGS"] = ""
        end
        env["LDFLAGS"]*=" -L$path"
    end

    for path in s.rpath_dirs
        if !haskey(env,"LDFLAGS")
            env["LDFLAGS"] = ""
        end
        env["LDFLAGS"]*=" -Wl,-rpath -Wl,$path"
    end

    if s.force_rebuild
        @dependent_steps begin
            RemoveDirectory(s.builddir)
        end
    end

    @static if Sys.isunix()
        @dependent_steps begin
            CreateDirectory(s.builddir)
            begin
                ChangeDirectory(s.builddir)
                FileRule(isempty(s.config_status_dir) ? "config.status" : joinpath(s.config_status_dir,"config.status"), setenv(`$(s.src)/configure $(s.configure_options) --prefix=$(prefix)`,env))
                FileRule(s.libtarget,MakeTargets(;env=s.env))
                MakeTargets("install";env=env)
            end
        end
    end

    @static if Sys.iswindows()
        @dependent_steps begin
            ChangeDirectory(s.src)
            FileRule(isempty(s.config_status_dir) ? "config.status" : joinpath(s.config_status_dir,"config.status"),setenv(`sh -c $cmdstring`,env))
            FileRule(s.libtarget,MakeTargets())
            MakeTargets("install")
        end
    end
end

function run(f::Function)
    f()
end

function run(s::FileRule)
    if !any(map(isfile,s.file))
        run(s.step)
        if !any(map(isfile,s.file))
            error("File $(s.file) was not created successfully (Tried to run $(s.step) )")
        end
    end
end
function run(s::DirectoryRule)
    @info("Attempting to create directory $(s.dir)")
    if !isdir(s.dir)
        run(s.step)
        if !isdir(s.dir)
            error("Directory $(s.dir) was not created successfully (Tried to run $(s.step) )")
        end
    else
        @info("Directory $(s.dir) already exists")
    end
end

function run(s::PathRule)
    if !ispath(s.path)
        run(s.step)
        if !ispath(s.path)
            error("Path $(s.path) was not created successfully (Tried to run $(s.step) )")
        end
    else
        @info("Path $(s.path) already exists")
    end
end

function run(s::BuildStep)
    error("Unimplemented BuildStep: $(typeof(s))")
end
function run(s::SynchronousStepCollection)
    for x in s.steps
        if !isempty(s.cwd)
            @info("Changing directory to $(s.cwd)")
            cd(s.cwd)
        end
        run(x)
        if !isempty(s.oldcwd)
            @info("Changing directory to $(s.oldcwd)")
            cd(s.oldcwd)
        end
    end
end

const MAKE_CMD = Sys.isbsd() && !Sys.isapple() ? `gmake` : `make`

function prepare_src(depsdir,url, downloaded_file, directory_name)
    local_file = joinpath(joinpath(depsdir,"downloads"),downloaded_file)
    @build_steps begin
        FileDownloader(url,local_file)
        FileUnpacker(local_file,joinpath(depsdir,"src"),directory_name)
    end
end

function autotools_install(depsdir,url, downloaded_file, configure_opts, directory_name, directory, libname, installed_libname, confstatusdir)
    prefix = joinpath(depsdir,"usr")
    libdir = joinpath(prefix,"lib")
    srcdir = joinpath(depsdir,"src",directory)
    dir = joinpath(joinpath(depsdir,"builds"),directory)
    prepare_src(depsdir,url, downloaded_file,directory_name) |
    @build_steps begin
        AutotoolsDependency(srcdir=srcdir,prefix=prefix,builddir=dir,configure_options=configure_opts,libtarget=libname,installed_libpath=[joinpath(libdir,installed_libname)],config_status_dir=confstatusdir)
    end
end
autotools_install(depsdir,url, downloaded_file, configure_opts, directory_name, directory, libname, installed_libname) = autotools_install(depsdir,url, downloaded_file, configure_opts, directory_name, directory, libname, installed_libname, "")
autotools_install(depsdir,url, downloaded_file, configure_opts, directory, libname)=autotools_install(depsdir,url,downloaded_file,configure_opts,directory,directory,libname,libname)

autotools_install(args...) = error("autotools_install has been removed")

function eval_anon_module(context, file)
    m = Module(:__anon__)
    if isdefined(Base, Symbol("@__MODULE__"))
        Core.eval(m, :(ARGS=[$context]))
        Base.include(m, file)
    else
        body = Expr(:toplevel, :(ARGS=[$context]), :(include($file)))
        Core.eval(m, body)
    end
    return
end

"""
    glibc_version()

For Linux-based systems, return the version of glibc in use. For non-glibc Linux and
other platforms, returns `nothing`.
"""
function glibc_version()
    Sys.islinux() || return
    libc = ccall(:jl_dlopen, Ptr{Cvoid}, (Ptr{Cvoid}, UInt32), C_NULL, 0)
    ptr = Libdl.dlsym_e(libc, :gnu_get_libc_version)
    ptr == C_NULL && return # non-glibc
    v = unsafe_string(ccall(ptr, Ptr{UInt8}, ()))
    occursin(Base.VERSION_REGEX, v) ? VersionNumber(v) : nothing
end

include("dependencies.jl")
include("debug.jl")
include("show.jl")


# deprecations

@Base.deprecate_binding shlib_ext Libdl.dlext

const has_sudo = Ref{Bool}(false)
function __init__()
    if lowercase(get(Base.ENV, "NOSUDO", "false")) == "false"
        has_sudo[] = try success(`sudo -V`) catch err false end
    end
end

end
