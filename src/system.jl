@windows_only using RPMmd

function add_to_juliarc(line::String)
    f=open("$(ENV["HOME"])/juliarc.jl","a")
    println(f)
    println(f,line)
    close(f)
end

function hasbin{T<:String}(bin::String,extra::Vector{T}=[])
    path = split(ENV["PATH"],":")
    for p in path
        f = joinpath(p,bin)
        if isfile(f)
            return realpath(p)
        end
    end
    for p in extra
        if isdir(p)
            f = joinpath(p,bin)
            if isfile(f)
                #ENV["PATH"] = ENV["PATH"]*":"*p
                return realpath(p)
            end
        end
    end
    return ""
end

#example: SystemLibInstall("libexpat", [("brew","expat"), ("port","expat")])
typealias PackageInstallMap Dict{Symbol,Union(String,Cmd)}
type SystemLibInstall <: BuildStep
    filenames::Vector{String}
    known_map::PackageInstallMap
end
SystemLibInstall(s::Vector{String},known_map::PackageInstallMap) = SystemLibInstall(String[s,], PackageInstallMap())
SystemLibInstall(s::String) = SystemLibInstall(s, PackageInstallMap())
function SystemLibInstall(s,known_map::Vector)
    known = PackageInstallMap()
    for (manager,cmd) in known_map
        known[manager] = cmd
    end
    SystemLibInstall(s,known)
end

let brew_path=""
global brew
function brew(cmd::Symbol,arg=nothing)
    if cmd == :exists
        brew_path = hasbin("brew",["/usr/local/bin",])
        if brew_path != ""
            brewlib = abspath(brew_path,"..","lib")
            if !(brewlib in LIBRARY_PATH)
                push!(Sys.DL_LOAD_PATH, brewlib)
                add_to_juliarc("push!(Sys.DL_LOAD_PATH, \"$(escape(brewlib))\")")
            end
            return true
        end
        return false
    elseif cmd == :whatprovides
        return nothing
    elseif cmd == :install
        return run(`$brew_path install $arg`)
    end
end
end

let port_path = ""
global port
function port(cmd::Symbol,arg=nothing)
    if cmd == :exists
        port_path = hasbin("port",["/opt/local/bin",])
        if port_path != ""
            portlib = abspath(port_path,"..","lib")
            if !(portlib in LIBRARY_PATH)
                push!(Sys.DL_LOAD_PATH, portlib)
                add_to_juliarc("push!(Sys.DL_LOAD_PATH, \"$(escape(portlib))\")")
            end
            return true
        end
        return false
    elseif cmd == :whatprovides
        return nothing
    elseif cmd == :install
        print("System dependency install using `sudo`. You will be prompted to enter password.")
        return run(`sudo $port_path install $arg`)
    end
end
end

function rpmmd(cmd::Symbol,arg=nothing)
    if cmd == :exists
        try
            eval(Expr(:toplevel,:using,:RPMmd))
            return true
        catch
            return false
        end
    elseif cmd == :whatprovides
        return RPMmd.whatprovides("/$arg")
    elseif cmd == :install
        return RPMmd.install(arg)
    end
end

function yum(cmd::Symbol,arg=nothing)
    if cmd == :exists
        return hasbin("yum")
    elseif cmd == :whatprovides
        #pkgs = readall(`yum whatprovides */$arg`, STDIN)
        #TODO: scan for package name(s)
        return nothing
    elseif cmd == :install
        print("System dependency install using `sudo`. You will be prompted to enter password.")
        return run(`sudo yum install $arg`)
    end
end

function apt(cmd::Symbol,arg=nothing)
    if cmd == :exists
        return hasbin("apt-get")
    elseif cmd == :whatprovides
        return unique([split(pkg,":",2) for pkg in split(readall("apt-file search $arg"),'\n')])
    elseif cmd == :install
        print("System dependency install using `sudo`. You will be prompted to enter password.")
        return run("sudo apt-get install $arg")
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
    man = default_pkg_manager()
    lib = Base.find_library(si.filenames)
    if lib != ""
        return true
    end
    if man === nothing
        return false
    end
    provides = get(si.known_map, string(man), nothing)
    if provides === nothing
        for file in si.filenames
            provides = man(:whatprovides, file)
            if provides !== nothing
                break
            end
        end
    end
    if provides === nothing
        return false
    end
    return man(:install, provides)
end

