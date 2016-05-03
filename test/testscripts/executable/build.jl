using BinDeps

@windows_only begin
    const sh_file = chomp(readlines(`where cmd`)[1])
    const sh_dest_file = "bindeps_sh_test.exe"
    copyfile(src, dest) = cp(src, dest; remove_destination=true)

    function validate(path)
        success(`$path /Q`)
    end
end
@unix_only begin
    const sh_file = chomp(readlines(`which sh`)[1])
    const sh_dest_file = "bindeps_sh_test"
    copyfile(src, dest) = success(`cp $src $dest`)

    function validate(path)
        success(`sh --help`)
    end
end


@BinDeps.setup

sh_test = executable_dependency("bindeps_sh_test", validate=validate)

sh_test_dir = BinDeps.bindir(sh_test)
sh_dest = joinpath(sh_test_dir, sh_dest_file)
mkpath(sh_test_dir)

provides(SimpleBuild, (@build_steps begin
    ()->copyfile(sh_file, sh_dest)
end), sh_test)

@BinDeps.install Dict([(:bindeps_sh_test, :sh_test)])

module Installed
include("./deps.jl")
end

@test validate(Installed.sh_test)

rm(Installed.sh_test)
