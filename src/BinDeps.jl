if OS_NAME == :Linux
    shlib_ext = "so"
elseif OS_NAME == :Darwin 
    shlib_ext = "dylib"
elseif OS_NAME == :Windows
    shlib_ext = "dll"
end

macro make_rule(condition,command)
    quote
        if(!$(esc(condition)))
            $(esc(command))
            @assert $(esc(condition))
        end
    end
end

abstract BuildStep

downloadcmd = nothing
function download_cmd(url::String, filename::String)
    global downloadcmd
    if downloadcmd === nothing
        for checkcmd in (:curl, :wget, :fetch)
            if system("which $checkcmd > /dev/null") == 0
                downloadcmd = checkcmd
                break
            end
        end
    end
    if downloadcmd == :wget
        return `wget -O $filename $url`
    elseif downloadcmd == :curl
        return `curl -o $filename -L $url`
    elseif downloadcmd == :fetch
        return `fetch -f $filename $url`
    else
        error("No download agent available; install curl, wget, or fetch.")
    end
end

function unpack_cmd(file,directory)
    path,extension = splitext(file)
    secondary_extension = splitext(path)[2]
    if(extension == ".gz" && secondary_extension == ".tar")
        return (`tar xzf $file --directory=$directory`)
    elseif(extension == ".xz" && secondary_extension == ".tar")
        return (`unxz -c $file `|`tar xv --directory=$directory`)
    end
    error("I don't know how to unpack $file")
end

type SynchronousStepCollection
    steps::Vector{Any}
    cwd::String
    oldcwd::String
    SynchronousStepCollection(cwd) = new({},cwd,cwd)
end

import Base.push!, Base.run, Base.(|)
push!(a::SynchronousStepCollection,args...) = push!(a.steps,args...)

type ChangeDirectory <: BuildStep
    dir::String
end

type CreateDirectory <: BuildStep
    dest::String
    mayexist::Bool
    CreateDirectory(dest, me) = new(dest,me)
    CreateDirectory(dest) = new(dest,true)
end

type FileDownloader <: BuildStep
    src::String     #url
    dest::String    #local_file
end

type FileUnpacker <: BuildStep
    src::String     #file
    dest::String    #directory
end

type AutotoolsDependency <: BuildStep
    src::String     #src direcory
    prefix::String
    builddir::String
    configure_options::Vector{String}
    libname::String
    installed_libname::String
    AutotoolsDependency(a::String,b::String,c::String,d::Vector{String},e::String,f::String) = new(a,b,c,d,e,f)
    AutotoolsDependency(b::String,c::String,d::Vector{String},e::String,f::String) = new("",b,c,d,e,f)
end

type FileRule <: BuildStep
    file::String
    step
end

type DirectoryRule <: BuildStep
    dir::String
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
    blk = expr(:block)
    meta_lower(steps,blk,:collection)
    blk
end

macro build_steps(steps)
    collection = gensym()
    blk = expr(:block)
    push!(blk.args,quote
        $(esc(collection)) = SynchronousStepCollection(pwd())
    end)
    meta_lower(steps,blk,collection)
    push!(blk.args, quote; $(esc(collection)); end)
    blk
end

src(b::BuildStep) = b.src
dest(b::BuildStep) = b.dest

(|)(a::BuildStep,b::BuildStep) = SynchronousStepCollection(pwd())
(|)(b::SynchronousStepCollection,a::SynchronousStepCollection) = (append(a.steps,b.steps); a)
(|)(a::SynchronousStepCollection,b) = push!(a.steps,b)
(|)(b,a::SynchronousStepCollection) = unshift!(a.steps,b)

function lower(s::ChangeDirectory,collection)
    if(!isempty(collection.steps))
        error("Change of Directory must be the first instruction")
    end
    collection.cwd = s.dir
end
lower(s::BuildStep,collection) = push!(collection,s)
lower(s::Base.AbstractCmd,collection) = push!(collection,s)
lower(s::FileDownloader,collection) = @dependent_steps ( CreateDirectory(dirname(s.dest),true), FileRule(s.dest,download_cmd(s.src,s.dest)) )
lower(s::FileUnpacker,collection) = @dependent_steps ( CreateDirectory(s.dest,true), unpack_cmd(s.src,s.dest) )
function lower(s::AutotoolsDependency,collection)
    @dependent_steps begin
        CreateDirectory(s.builddir)
        `echo test`
        begin
            ChangeDirectory(s.builddir)
            FileRule("config.status", `$(s.src)/configure $(s.configure_options) --prefix=$(s.prefix)`)
            FileRule(s.libname,make_command)
            FileRule(s.installed_libname,`$make_command install`)
        end
    end
end

function run(s::FileRule)
    if(!isfile(s.file))
        run(s.step)
    end
end
function run(s::BuildStep)
    error("Unimplemented BuildStep: $(typeof(s))")
end
function run(s::CreateDirectory)
    @make_rule isdir(s.dest) run(`mkdir -p $(s.dest)`)
end
function run(s::SynchronousStepCollection)
    for x in s.steps
        cd(s.cwd)
        run(x)
        cd(s.oldcwd)
    end
end

@unix_only make_command = `make -j8`
@windows_only make_command = `make`

function autotools_install(url, downloaded_file, configure_opts, directory, libname, installed_libname)
    prefix = joinpath(depsdir,"usr")
    libdir = joinpath(prefix,"lib")
    srcdir = joinpath(depsdir,"src",directory)
    local_file = joinpath(joinpath(depsdir,"downloads"),downloaded_file)
    dir = joinpath(joinpath(depsdir,"builds"),directory)
    run(@build_steps begin
        FileDownloader(url,local_file)
        FileUnpacker(local_file,joinpath(depsdir,"src"))
        AutotoolsDependency(srcdir,prefix,dir,configure_opts,libname,joinpath(libdir,installed_libname))
    end)
end
autotools_install(url, downloaded_file, configure_opts, directory, libname)=autotools_install(url,downloaded_file,configure_opts,directory,libname,libname)
