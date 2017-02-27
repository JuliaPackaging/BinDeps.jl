commands = ["apt-get", "pacman", "yum", "zypper"]
try
    run(pipeline(`which unzip`, stdout=DevNull, stderr=DevNull))
catch
    for i in commands
        path=["",""]
        try
            path=split(readstring(pipeline(`which $(i)`, stderr=DevNull)),'/')
        catch
            continue
        end
        if (path[2]=="usr" && path[3]=="bin")
            println("Installing unzip...")
            try
                if (i=="pacman")
                    run(pipeline(`sudo $(i) -S unzip`, stderr=DevNull))
                else
                    run(pipeline(`sudo $(i) install unzip`, stderr=DevNull))
                end
            catch
                println("Unable to install unzip. Please install it manually.")
            end
            break
        end
    end
end
