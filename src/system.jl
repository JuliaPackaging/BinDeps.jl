@windows_only using RPMmd

function add_to_juliarc(line::String)
    f=open("$HOME/juliarc.jl")
end

function hasbin{T<:String}(bin::String,extra::Vector{T}=[])
    path = split(ENV["PATH"],":")
    for p in path
        if isfile(p,bin)
            return p
        end
    end
    for p in extra
        if isdir(p)
            f = joinpath(p,bin)
            if isfile(f)
                ENV["PATH"] = ENV["PATH"]*":"*p
                return realpath(p)
            end
        end
    end
    return ""
end
function haslib(lib::String)
    man = default_pkg_manager() # for the search path side effect    
    libext = lib*"."*shlib_ext
    for p in LIBRARY_PATH
        if isfile(p,lib) || isfile(p,libext)
            return true
        end
    end
    p = dlopen_e(lib, RTLD_LAZY)
    dlclose(p)
    return p != C_NULL
end
function find_library{T<:String}(libnames::Vector{T})
    for lib in libnames
        if haslib(lib)
            return lib
        end
    end
    error("none of the libraries $libnames could be found! perhaps you need to rerun Pkg.runbuildscript?")
end

#example: SystemLibInstall("libexpat", [("brew","expat",""), ("port","expat","")])
type SystemLibInstall <: BuildStep
    filename::Vector{String}
    known_map::Dict{String,(String,String)}
end
SystemLibInstall(s::Vector{String},known_map::Dict{String,(String,String)}) = SystemLibInstall(String[s,], Dict{String,(String,String)}())
SystemLibInstall(s::String) = SystemLibInstall(s, Dict{String,(String,String)}())
function SystemLibInstall(s,known_map::Vector)
    known = Dict{String,(String,String)}()
    for (manager,name,options) in known_map
        known[manager] = (name,options)
    end
    SystemLibInstall(s,known)
end

function brew(cmd::Symbol,arg::String="")
    if cmd == :exists
        global const brew_path = hasbin("brew",["/usr/local/bin",])
        if brew_path != ""
            push!(LIBRARY_PATH, abspath(brew_path,"..","lib"))
            return true
        end
        return false
#    elseif cmd == :haslib
#        opt = joinpath(brew_path,"opt")
#        for x in readdir(opt)
#            lib = joinpath(opt,x,"lib",arg)
#            libext = lib*"."*shlib_ext
#            if isfile(lib) || isfile(libext)
#                return true
#            end    
#            p = dlopen_e(lib, RTLD_LAZY)
#            dlclose(p)
#            if p != C_NULL
#                return true
#            end
#        end
#        return false

    end
end
function port(cmd::Symbol,arg::String="")
    if cmd == :exists
        port_path = hasbin("port",["/opt/local/bin",])
        if port_path != ""
            push!(LIBRARY_PATH, abspath(port_path,"..","lib"))
            return true
        end
        return false
        
    end
end
function rpmmd(cmd::Symbol,arg::String="")
    if cmd == :exists
        return true

    end
end
function yum(cmd::Symbol,arg::String="")
    if cmd == :exists
        return hasbin("yum")

    end
end
function apt(cmd::Symbol,arg::String="")
    if cmd == :exists
        return hasbin("apt-get")

    end
end
global system_man = nothing
function default_pkg_manager()
    global system_man
    if system_man !== nothing
        return system_man::Function
    end
    pkg_mangers = []
    @osx_only append!(pkg_managers,[port,brew])
    @windows_only push!(pkg_managers,[rpmmd,])
    @linux_only push!(pkg_managers,[apt,yum])
    for man in pkg_managers
        if man(:exists)
            system_man = man
            return man
        end
    end
    return nothing
end

function run(si::SystemLibInstall)
    #if file exists already
    man = default_pkg_manager()
    #if !man
    #man search
    #man install
end


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
