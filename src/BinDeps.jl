__precompile__()

module BinDeps

using Compat

export @make_run, @build_steps, find_library, download_cmd, unpack_cmd,
    Choice, Choices, CCompile, FileDownloader, FileRule,
    ChangeDirectory, FileDownloader, FileUnpacker, prepare_src,
    autotools_install, CreateDirectory, MakeTargets, SystemLibInstall,
    MAKE_CMD


macro make_rule(condition,command)
    quote
        if !$(esc(condition))
            $(esc(command))
            @assert $(esc(condition))
        end
    end
end

@compat abstract type BuildStep end

type SynchronousStepCollection
    steps::Vector{Any}
    cwd::AbstractString
    oldcwd::AbstractString
    SynchronousStepCollection(cwd) = new(Any[],cwd,cwd)
    SynchronousStepCollection() = new(Any[],"","")
end

import Base.push!, Base.run, Base.(|)
push!(a::SynchronousStepCollection,args...) = push!(a.steps,args...)

"""
    ChangeDirectory(dir) <: BuildStep

Specifies that the working directory should be changed to `dir`.
"""
type ChangeDirectory <: BuildStep
    dir::AbstractString
end

"""
    CreateDirectory(dir, mayexist=true) <: BuildStep

Specifies that the directory `dir` should be created. `mayexist` specifies if whether or not the directory may exist.
"""
type CreateDirectory <: BuildStep
    dest::AbstractString
    mayexist::Bool
end
CreateDirectory(dest) = CreateDirectory(dest,true)

"""
    RemoveDirectory(dir) <: BuildStep

Specifies that the directory `dir` should be removed.
"""
immutable RemoveDirectory <: BuildStep
    dest::AbstractString
end

"""
    FileDownloader(url, dest) <: BuildStep

Specifies that the file from `url` should be downloaded to `dest`.
"""
type FileDownloader <: BuildStep
    src::AbstractString     # url
    dest::AbstractString    # local_file
end


"""
    ChecksumValidator(sha, file) <: BuildStep

Specifies that the file `file` should be checked against the SHA1 sum `sha`.
"""
type ChecksumValidator <: BuildStep
    sha::AbstractString
    path::AbstractString
end


"""
    FileUnpacker(archive, dest[, target]) <: BuildStep

Specifies that the archive file `archive` should be extracted to `dest`.

After extraction, the file `target` is checked to exist: if no `target` is provided, then a file
of the same name as the archive with the extension removed is checked.
"""
type FileUnpacker <: BuildStep
    src::AbstractString     # archive file
    dest::AbstractString    # directory to unpack into
    target::AbstractString  # file or directory inside the archive to test
                            # for existence (or blank to check for a.tgz => a/)
end
FileUnpacker(src, dest) = FileUnpacker(src, dest, "")

"""
    MakeTargets(dir="", targets=[][, env]) <: BuildStep

Invoke GNU Make for targets `targets` in the directory `dir` with the environment variables `env` set.

"""
type MakeTargets <: BuildStep
    dir::AbstractString
    targets::Vector{String}
    env::Dict
    MakeTargets(dir,target;env = Dict{AbstractString,AbstractString}()) = new(dir,target,env)
    MakeTargets{S<:AbstractString}(target::Vector{S};env = Dict{AbstractString,AbstractString}()) = new("",target,env)
    MakeTargets(target::String;env = Dict{AbstractString,AbstractString}()) = new("",[target],env)
    MakeTargets(;env = Dict{AbstractString,AbstractString}()) = new("",String[],env)
end

"""
    AutotoolsDependency <: BuildStep

Invokes autotools. 

Use of this build step is not recommended: use the [`Autotools`](@ref) provider instead.
"""
type AutotoolsDependency <: BuildStep
    src::AbstractString     # src direcory
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

type Choice
    name::Symbol
    description::AbstractString
    step::SynchronousStepCollection
    Choice(name,description,step) = (s=SynchronousStepCollection();lower(step,s);new(name,description,s))
end

type Choices <: BuildStep
    choices::Vector{Choice}
    Choices() = new(Choice[])
    Choices(choices::Vector{Choice}) = new(choices)
end

push!(c::Choices, args...) = push!(c.choices, args...)

function run(c::Choices)
    println()
    info("There are multiple options available for installing this dependency:")
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
            warn("Invalid method")
        end
    end
end

"""
    CCompile(src, dest, options, libs) <: BuildStep

Compile C file `src` to `dest`.
"""
type CCompile <: BuildStep
    srcFile::AbstractString
    destFile::AbstractString
    options::Vector{String}
    libs::Vector{String}
end

lower(cc::CCompile,c) = lower(FileRule(cc.destFile,`gcc $(cc.options) $(cc.srcFile) $(cc.libs) -o $(cc.destFile)`),c)
##

"""
    DirectoryRule(dir, step) <: BuildStep

If `dir` does not exist invoke `step`, and validate that the directory was created.
"""
type DirectoryRule <: BuildStep
    dir::AbstractString
    step
end

"""
    PathRule(path, step) <: BuildStep

If `path` does not exist invoke `step` and validate that the directory was created.
"""
type PathRule <: BuildStep
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

mypwd() = chomp(readall(`pwd`))

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


"""
    FileRule(files, step)

If none of the files `files` exist, then invoke `step` and confirm that at least one of
`files` was created.
"""
type FileRule <: BuildStep
    file::Array{AbstractString}
    step
    FileRule(file::AbstractString,step) = FileRule(AbstractString[file],step)
    function FileRule(files::Vector{AbstractString},step)
        new(files,@build_steps (step,) )
    end
end
FileRule{T<:AbstractString}(files::Vector{T},step) = FileRule(AbstractString[f for f in files],step)

function lower(s::ChangeDirectory,collection)
    if !isempty(collection.steps)
        error("Change of directory must be the first instruction")
    end
    collection.cwd = s.dir
end
lower(s::Void,collection) = nothing
lower(s::Function,collection) = push!(collection,s)
lower(s::CreateDirectory,collection) = @dependent_steps ( DirectoryRule(s.dest,()->(mkpath(s.dest))), )
lower(s::RemoveDirectory,collection) = @dependent_steps ( `rm -rf $(s.dest)` )
lower(s::BuildStep,collection) = push!(collection,s)
lower(s::Base.AbstractCmd,collection) = push!(collection,s)
lower(s::FileDownloader,collection) = @dependent_steps ( CreateDirectory(dirname(s.dest),true), ()->info("Downloading file $(s.src)"), FileRule(s.dest,download_cmd(s.src,s.dest)), ()->info("Done downloading file $(s.src)") )
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

function adjust_env(env)
    ret = similar(env)
    merge!(ret,ENV)
    merge!(ret,env) # s.env overrides ENV
    ret
end

if Compat.Sys.isunix()
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
Compat.Sys.iswindows() && (lower(a::MakeTargets,collection) = @dependent_steps ( setenv(`make $(!isempty(a.dir) ? "-C "*a.dir : "") $(a.targets)`, adjust_env(a.env)), ))
lower(s::SynchronousStepCollection,collection) = (collection|=s)

lower(s) = (c=SynchronousStepCollection();lower(s,c);c)

#run(s::MakeTargets) = run(@make_steps (s,))

function lower(s::AutotoolsDependency,collection)
    prefix = s.prefix
    if Compat.Sys.iswindows()
        prefix = replace(replace(s.prefix,"\\","/"),"C:/","/c/")
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

    @static if Compat.Sys.isunix()
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

    @static if Compat.Sys.iswindows()
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
    info("Attempting to create directory $(s.dir)")
    if !isdir(s.dir)
        run(s.step)
        if !isdir(s.dir)
            error("Directory $(s.dir) was not created successfully (Tried to run $(s.step) )")
        end
    else
        info("Directory $(s.dir) already exists")
    end
end

function run(s::PathRule)
    if !ispath(s.path)
        run(s.step)
        if !ispath(s.path)
            error("Path $(s.path) was not created successfully (Tried to run $(s.step) )")
        end
    else
        info("Path $(s.path) already exists")
    end
end

function run(s::BuildStep)
    error("Unimplemented BuildStep: $(typeof(s))")
end
function run(s::SynchronousStepCollection)
    for x in s.steps
        if !isempty(s.cwd)
            info("Changing directory to $(s.cwd)")
            cd(s.cwd)
        end
        run(x)
        if !isempty(s.oldcwd)
            info("Changing directory to $(s.oldcwd)")
            cd(s.oldcwd)
        end
    end
end

const MAKE_CMD = Compat.Sys.isbsd() && !Compat.Sys.isapple() ? `gmake` : `make`

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
        eval(m, :(ARGS=[$context]))
        Base.include(m, file)
    else
        body = Expr(:toplevel, :(ARGS=[$context]), :(include($file)))
        eval(m, body)
    end
    return
end

include("utils.jl")
include("dependencies.jl")
include("debug.jl")
include("show.jl")


# deprecations

@Base.deprecate_binding shlib_ext Libdl.dlext

const has_sudo = Ref{Bool}(false)
function __init__()
    has_sudo[] = try success(`sudo -V`) catch err false end
end

end
