module BinDeps
    import Base.run 
    export @make_run, @build_steps, download_cmd, unpack_cmd, HomebrewInstall, Choice, Choices, CCompile, FileDownloader, 
            FileRule, ChangeDirectory, FileDownloader, FileUnpacker, prepare_src, autotools_install, CreateDirectory

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
                if success(`$checkcmd --help`)
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

    @unix_only begin
        function unpack_cmd(file,directory)
            path,extension = splitext(file)
            secondary_extension = splitext(path)[2]
            if(extension == ".gz" && secondary_extension == ".tar") || extension == ".tgz"
                return (`tar xzf $file --directory=$directory`)
            elseif(extension == ".bz2" && secondary_extension == ".tar") || extension == ".tbz"
                return (`tar xjf $file --directory=$directory`)
            elseif(extension == ".xz" && secondary_extension == ".tar")
                return (`unxz -c $file `|`tar xv --directory=$directory`)
            elseif(extension == ".zip")
                return (`unzip -x $file -d $directory`)
            end
            error("I don't know how to unpack $file")
        end
    end

    @windows_only begin
        function unpack_cmd(file,directory)
            path,extension = splitext(file)
            secondary_extension = splitext(path)[2]
            if((extension == ".gz" || extension == ".xz" || extension == ".bz2") && secondary_extension == ".tar") ||
                   extension == ".tgz" || extension == ".tbz"
                return (`7z x $file -y -so`|`7z x -si -y -ttar -o$directory`)
            elseif extension == ".zip"
                return (`7z x $file -y -o$directory`)
            end
            error("I don't know how to unpack $file")
        end 
    end

    type SynchronousStepCollection
        steps::Vector{Any}
        cwd::String
        oldcwd::String
        SynchronousStepCollection(cwd) = new({},cwd,cwd)
        SynchronousStepCollection() = new({},"","")
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


    type MakeTargets <: BuildStep
    	dir::String
    	targets::Vector{ASCIIString}
    	MakeTargets(dir,target) = new(dir,target)
    	MakeTargets(target::Vector{ASCIIString}) = new("",target)
    	MakeTargets(target::ASCIIString) = new("",[target])
    	MakeTargets() = new("",ASCIIString[])
    end

    type AutotoolsDependency <: BuildStep
        src::String     #src direcory
        prefix::String
        builddir::String
        configure_options::Vector{String}
        libname::String
        installed_libname::String
    	config_status_dir::String
        AutotoolsDependency(a::String,b::String,c::String,d::Vector{String},e::String,f::String,g::String) = new(a,b,c,d,e,f,g)
        AutotoolsDependency(b::String,c::String,d::Vector{String},e::String,f::String) = new("",b,c,d,e,f,"")
    end

    ### Choices

    type Choice
        name::Symbol
        description::String
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
        info("There are multiple options available for installing this dependency:")
        for x in c.choices
            println("- "*string(x.name)*": "*x.description)
        end
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

    ###

    @osx_only begin

        const installed_homebrew_packages = Set{ASCIIString}()

        function cacheHomebrewPackages()
            empty!(installed_homebrew_packages)
            for pkg in EachLine(read_from(`brew list`)[1])
                add!(installed_homebrew_packages,chomp(pkg))
            end
            installed_homebrew_packages
        end

        type HomebrewInstall <: BuildStep
            name::ASCIIString
            desired_options::Vector{ASCIIString}
            required_options::Vector{ASCIIString}
            HomebrewInstall(name,desired_options) = new(name,desired_options,ASCIIString[])
            HomebrewInstall(name,desired_options,required_options) = error("required_options not implemented yet")
        end

        function run(x::HomebrewInstall)
            if(isempty(installed_homebrew_packages))
                cacheHomebrewPackages()
            end
            if(has(installed_homebrew_packages,x.name))
                info("Package already installed")
            else
                run(`brew install $(x.desired_options) $(x.name)`)
            end
            cacheHomebrewPackages()
        end

    end

    ##

    type CCompile <: BuildStep
        srcFile::String
        destFile::String
        options::Vector{ASCIIString}
        libs::Vector{ASCIIString}
    end

    lower(cc::CCompile,c) = lower(FileRule(cc.destFile,`gcc $(cc.options) $(cc.srcFile) $(cc.libs) -o $(cc.destFile)`),c)
    ##

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

    type FileRule <: BuildStep
        file::String
        step
    	function FileRule(file,step) 
    		f=new(file,@build_steps (step,) )
    	end
    end

    function lower(s::ChangeDirectory,collection)
        if(!isempty(collection.steps))
            error("Change of Directory must be the first instruction")
        end
        collection.cwd = s.dir
    end
    lower(s::Nothing,collection) = nothing
    lower(s::Function,collection) = push!(collection,s)
    lower(s::CreateDirectory,collection) = @dependent_steps ( DirectoryRule(s.dest,()->(println(s.dest);mkpath(s.dest))), )
    lower(s::BuildStep,collection) = push!(collection,s)
    lower(s::Base.AbstractCmd,collection) = push!(collection,s)
    lower(s::FileDownloader,collection) = @dependent_steps ( CreateDirectory(dirname(s.dest),true), ()->info("Downloading file $(s.src)"), FileRule(s.dest,download_cmd(s.src,s.dest)), ()->info("Done downloading file $(s.src)") )
    lower(s::FileUnpacker,collection) = @dependent_steps ( CreateDirectory(dirname(s.dest),true), DirectoryRule(s.dest,unpack_cmd(s.src,dirname(s.dest))) )
    @unix_only function lower(a::MakeTargets,collection) 
        cmd = `make -j8`
        if(!isempty(a.dir))
            cmd = `$cmd -C $(a.dir)`
        end
        if(!isempty(a.targets))
            cmd = `$cmd $(a.targets)`
        end
        @dependent_steps ( cmd, )
    end
    @windows_only lower(a::MakeTargets,collection) = @dependent_steps ( `make $(!isempty(a.dir)?"-C "*a.dir:"") $(a.targets)`, )
    lower(s::SynchronousStepCollection,collection) = (collection|=s)

    #run(s::MakeTargets) = run(@make_steps (s,))

    function lower(s::AutotoolsDependency,collection)
    	@windows_only prefix = replace(replace(s.prefix,"\\","/"),"C:/","/c/")
    	@unix_only prefix = s.prefix
    	cmdstring = "pwd && ./configure --prefix=$(prefix) "*join(s.configure_options," ")
        @unix_only @dependent_steps begin
            CreateDirectory(s.builddir)
            `echo test`
            begin
                ChangeDirectory(s.builddir)
    			()->println(s.src)
                @unix_only FileRule(isempty(s.config_status_dir)?"config.status":joinpath(s.config_status_dir,"config.status"), `$(s.src)/configure $(s.configure_options) --prefix=$(prefix)`)
                FileRule(s.libname,MakeTargets())
                FileRule(s.installed_libname,MakeTargets("install"))
            end
        end

    	@windows_only @dependent_steps begin
    		begin
                ChangeDirectory(s.src)
    			@windows_only FileRule(isempty(s.config_status_dir)?"config.status":joinpath(s.config_status_dir,"config.status"),`sh -c $cmdstring`)
                FileRule(s.libname,MakeTargets())
                FileRule(s.installed_libname,MakeTargets("install"))
            end
    	end
    end

    function run(f::Function)
    	f()
    end

    function run(s::FileRule)
        if(!isfile(s.file))
            run(s.step)
    		if(!isfile(s.file))
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
            FileUnpacker(local_file,joinpath(depsdir,"src",directory_name))
    	end
    end

    function autotools_install(depsdir,url, downloaded_file, configure_opts, directory_name, directory, libname, installed_libname, confstatusdir)
        prefix = joinpath(depsdir,"usr")
        libdir = joinpath(prefix,"lib")
        srcdir = joinpath(depsdir,"src",directory)
        dir = joinpath(joinpath(depsdir,"builds"),directory)
        prepare_src(depsdir,url, downloaded_file,directory_name) |
    	@build_steps begin
            AutotoolsDependency(srcdir,prefix,dir,configure_opts,libname,joinpath(libdir,installed_libname),confstatusdir)
        end
    end
    autotools_install(depsdir,url, downloaded_file, configure_opts, directory_name, directory, libname, installed_libname) = autotools_install(depsdir,url, downloaded_file, configure_opts, directory_name, directory, libname, installed_libname, "")
    autotools_install(depsdir,url, downloaded_file, configure_opts, directory, libname)=autotools_install(depsdir,url,downloaded_file,configure_opts,directory,directory,libname,libname)

end
