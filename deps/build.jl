s=""
try
    s = s * chomp(readstring(pipeline(`cat /etc/issue`, stderr=DevNull)))
end
try
    s = s* chomp(readstring(pipeline(`cat /proc/version`, stderr=DevNull)))
end
try
    if(contains(lowercase(s), "arch"))
        try
            run(pipeline(`sudo pacman -S unzip`, stdout=DevNull, stderr=DevNull))
        catch
            println("Unable to install zip. Please install it manually.")
        end
    end
end
