module BinDeps
    importall Base
    using Compat

    export @make_run, @build_steps, find_library, download_cmd, unpack_cmd,
            Choice, Choices, CCompile, FileDownloader, FileRule,
            ChangeDirectory, FileDownloader, FileUnpacker, prepare_src,
            autotools_install, CreateDirectory, MakeTargets, SystemLibInstall

    const dlext = Libdl.dlext
    const shlib_ext = dlext # compatibility with older packages (e.g. ZMQ)

    function find_library(pkg,libname,files)
        Base.warn_once("BinDeps.find_library is deprecated, use Base.find_library instead.")
        dl = C_NULL
        for filename in files
            dl = Libdl.dlopen_e(joinpath(Pkg.dir(),pkg,"deps","usr","lib",filename))
            if dl != C_NULL
                ccall(:add_library_mapping,Cint,(Ptr{Cchar},Ptr{Void}),libname,dl)
                return true
            end

            dl = Libdl.dlopen_e(filename)
            if dl != C_NULL
                ccall(:add_library_mapping,Cint,(Ptr{Cchar},Ptr{Void}),libname,dl)
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

    abstract BuildStep

    downloadcmd = nothing
    function download_cmd(url::AbstractString, filename::AbstractString)
        global downloadcmd
        if downloadcmd === nothing
            for checkcmd in @windows? (:powershell, :curl, :wget, :fetch) : (:curl, :wget, :fetch)
                try
                    if success(`$checkcmd --help`)
                        downloadcmd = checkcmd
                        break
                    end
                catch
                    continue # don't bail if one of these fails
                end
            end
        end
        if downloadcmd == :wget
            return `wget -O $filename $url`
        elseif downloadcmd == :curl
            return `curl -f -o $filename -L $url`
        elseif downloadcmd == :fetch
            return `fetch -f $filename $url`
        elseif downloadcmd == :powershell
            return `powershell -Command "(new-object net.webclient).DownloadFile(\"$url\", \"$filename\")"`
        else
            error("No download agent available; install curl, wget, or fetch.")
        end
    end

    @unix_only begin
        function unpack_cmd(file,directory,extension,secondary_extension)
            if (extension == ".gz" && secondary_extension == ".tar") || extension == ".tgz"
                return (`tar xzf $file --directory=$directory`)
            elseif (extension == ".bz2" && secondary_extension == ".tar") || extension == ".tbz"
                return (`tar xjf $file --directory=$directory`)
            elseif extension == ".xz" && secondary_extension == ".tar"
                return (`unxz -c $file `|>`tar xv --directory=$directory`)
            elseif extension == ".tar"
                return (`tar xf $file --directory=$directory`)
            elseif extension == ".zip"
                return (`unzip -x $file -d $directory`)
            elseif extension == ".gz"
                return (`mkdir $directory` |> `cp $file $directory` |> `gzip -d $directory/$file`)
            end
            error("I don't know how to unpack $file")
        end
    end

    @windows_only begin
        function unpack_cmd(file,directory,extension,secondary_extension)
            if((extension == ".gz" || extension == ".xz" || extension == ".bz2") && secondary_extension == ".tar") ||
                   extension == ".tgz" || extension == ".tbz"
                return (`7z x $file -y -so`|>`7z x -si -y -ttar -o$directory`)
            elseif extension == ".zip" || extension == ".7z"
                return (`7z x $file -y -o$directory`)
            end
            error("I don't know how to unpack $file")
        end 
    end

    type SynchronousStepCollection
        steps::Vector{Any}
        cwd::AbstractString
        oldcwd::AbstractString
        SynchronousStepCollection(cwd) = new(Any[],cwd,cwd)
        SynchronousStepCollection() = new(Any[],"","")
    end

    import Base.push!, Base.run, Base.(|)
    push!(a::SynchronousStepCollection,args...) = push!(a.steps,args...)

    type ChangeDirectory <: BuildStep
        dir::AbstractString
    end

    type CreateDirectory <: BuildStep
        dest::AbstractString
        mayexist::Bool
        CreateDirectory(dest, me) = new(dest,me)
        CreateDirectory(dest) = new(dest,true)
    end

    immutable RemoveDirectory <: BuildStep
        dest::AbstractString
    end

    type FileDownloader <: BuildStep
        src::AbstractString     #url
        dest::AbstractString    #local_file
    end

    type ChecksumValidator <: BuildStep
        sha::AbstractString
        path::AbstractString
    end

    type FileUnpacker <: BuildStep
        src::AbstractString     #file
        dest::AbstractString    #directory
        target::AbstractString  #file or directory inside the archive to test
                        #for existence (or blank to check for a.tgz => a/)
    end


    type MakeTargets <: BuildStep
        dir::AbstractString
        targets::Vector{ASCIIString}
        env::Dict
        MakeTargets(dir,target;env = Dict{AbstractString,AbstractString}()) = new(dir,target,env)
        MakeTargets(target::Vector{ASCIIString};env = Dict{AbstractString,AbstractString}()) = new("",target,env)
        MakeTargets(target::ASCIIString;env = Dict{AbstractString,AbstractString}()) = new("",[target],env)
        MakeTargets(;env = Dict{AbstractString,AbstractString}()) = new("",ASCIIString[],env)
    end

    type AutotoolsDependency <: BuildStep
        src::AbstractString     #src direcory
        prefix::AbstractString
        builddir::AbstractString
        configure_options::Vector{AbstractString}
        libtarget::Vector{AbstractString}
        include_dirs::Vector{AbstractString}
        lib_dirs::Vector{AbstractString}
        rpath_dirs::Vector{AbstractString}
        installed_libpath::Vector{ByteString} # The library is considered installed if any of these paths exist
    	config_status_dir::AbstractString
        force_rebuild::Bool
        env
        AutotoolsDependency(;srcdir::AbstractString = "", prefix = "", builddir = "", configure_options=AbstractString[], libtarget = AbstractString[], include_dirs=AbstractString[], lib_dirs=AbstractString[], rpath_dirs=AbstractString[], installed_libpath = ByteString[], force_rebuild=false, config_status_dir = "", env = Dict{ByteString,ByteString}()) = 
            new(srcdir,prefix,builddir,configure_options,isa(libtarget,Vector)?libtarget:AbstractString[libtarget],include_dirs,lib_dirs,rpath_dirs,installed_libpath,config_status_dir,force_rebuild,env)
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
        Choices() = new(Array(Choice,0))
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
                print("Plese select desired method: ")
                method = symbol(chomp(readline(STDIN)))
                for x in c.choices
                    if(method == x.name)
                        return run(x.step)
                    end
                end
                warn("Invalid Method")
            end
        end
    end

    type CCompile <: BuildStep
        srcFile::AbstractString
        destFile::AbstractString
        options::Vector{ASCIIString}
        libs::Vector{ASCIIString}
    end

    lower(cc::CCompile,c) = lower(FileRule(cc.destFile,`gcc $(cc.options) $(cc.srcFile) $(cc.libs) -o $(cc.destFile)`),c)
    ##

    type DirectoryRule <: BuildStep
        dir::AbstractString
        step
    end

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
    	if(a.cwd==b.cwd)
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
        if(!isempty(collection.steps))
            error("Change of Directory must be the first instruction")
        end
        collection.cwd = s.dir
    end
    @compat lower(s::Void,collection) = nothing
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
        target = !isempty(s.target) ? s.target : basename(base_filename)
        @dependent_steps begin
            CreateDirectory(dirname(s.dest),true)
            PathRule(joinpath(s.dest,target),unpack_cmd(s.src,s.dest,extension,secondary_extension))
        end
    end

    function adjust_env(env) 
        ret = similar(env)
        merge!(ret,ENV)
        merge!(ret,env) #s.env overrides ENV 
        ret
    end

    @unix_only function lower(a::MakeTargets,collection) 
        cmd = `make -j8`
        if(!isempty(a.dir))
            cmd = `$cmd -C $(a.dir)`
        end
        if(!isempty(a.targets))
            cmd = `$cmd $(a.targets)`
        end
        @dependent_steps ( setenv(cmd, adjust_env(a.env)), )
    end
    @windows_only lower(a::MakeTargets,collection) = @dependent_steps ( setenv(`make $(!isempty(a.dir)?"-C "*a.dir:"") $(a.targets)`, adjust_env(a.env)), )
    lower(s::SynchronousStepCollection,collection) = (collection|=s)

    lower(s) = (c=SynchronousStepCollection();lower(s,c);c)

    #run(s::MakeTargets) = run(@make_steps (s,))

    function lower(s::AutotoolsDependency,collection)
    	@windows_only prefix = replace(replace(s.prefix,"\\","/"),"C:/","/c/")
    	@unix_only prefix = s.prefix
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

        @unix_only @dependent_steps begin
            CreateDirectory(s.builddir)
            begin
                ChangeDirectory(s.builddir)
                @unix_only FileRule(isempty(s.config_status_dir)?"config.status":joinpath(s.config_status_dir,"config.status"), setenv(`$(s.src)/configure $(s.configure_options) --prefix=$(prefix)`,env))
                FileRule(s.libtarget,MakeTargets(;env=s.env))
                MakeTargets("install";env=env)
            end
        end

    	@windows_only @dependent_steps begin
    		begin
                ChangeDirectory(s.src)
    			@windows_only FileRule(isempty(s.config_status_dir)?"config.status":joinpath(s.config_status_dir,"config.status"),setenv(`sh -c $cmdstring`,env))
                FileRule(s.libtarget,MakeTargets())
                MakeTargets("install")
            end
    	end
    end

    function run(f::Function)
    	f()
    end

    function run(s::FileRule)
        if(!any(map(isfile,s.file)))
            run(s.step)
    		if(!any(map(isfile,s.file)))
    			error("File $(s.file) was not created successfully (Tried to run $(s.step) )")
    		end
        end
    end
    function run(s::DirectoryRule)
    	info("Attempting to Create directory $(s.dir)")
        if(!isdir(s.dir))
            run(s.step)
    		if(!isdir(s.dir))
    			error("Directory $(s.dir) was not created successfully (Tried to run $(s.step) )")
    		end
    	else
    		info("Directory $(s.dir) already created")
        end
    end

    function run(s::PathRule)
        if !ispath(s.path)
            run(s.step)
            if !ispath(s.path)
                error("Path $(s.path) was not created successfully (Tried to run $(s.step) )")
            end
        else
            info("Path $(s.path) already created")
        end
    end

    function run(s::BuildStep)
        error("Unimplemented BuildStep: $(typeof(s))")
    end
    function run(s::SynchronousStepCollection)
        for x in s.steps
    		if(!isempty(s.cwd))
    			info("Changing Directory to $(s.cwd)")
    			cd(s.cwd)
    		end
            run(x)
            if(!isempty(s.oldcwd))
    			info("Changing Directory to $(s.oldcwd)")
    			cd(s.oldcwd)
    		end
        end
    end

    @unix_only make_command = `make -j8`
    @windows_only make_command = `make`

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

    include("dependencies.jl")
    include("debug.jl")
    include("show.jl")
end
