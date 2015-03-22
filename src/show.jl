print_indented(io::IO,x,indent) = print(io," "^indent,x)
function show_indented(io::IO,x,indent)
    print_indented(io,"- ",indent)
    show(io,x)
end

show(io::IO,x::PackageManager) = print(io,"$(typeof(x)) package $(pkg_name(x))")
show(io::IO,x::SimpleBuild) = print(io,"Simple Build Process")
show(io::IO,x::Sources) = print(io,"Sources")
show(io::IO,x::Binaries) = print(io,"Binaries")
show(io::IO,x::Autotools) = print(io,"Autotools Build")
