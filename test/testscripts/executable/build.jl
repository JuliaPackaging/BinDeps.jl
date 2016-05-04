using BinDeps

function validate(path)
    if basename(path) == "sh"
        return success(`$path --help`)
    else
        return success(`$path /Q`)
    end
end


@BinDeps.setup

sh_test = executable_dependency("bindeps_sh_test", aliases=["sh", "cmd.exe"], validate=validate)

@BinDeps.install Dict([(:bindeps_sh_test, :sh_test)])

module Installed
include("./deps.jl")
end

@test validate(Installed.sh_test)
