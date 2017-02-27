commands = ["apt-get", "pacman", "yum", "zypper"]
items=""
try
    items = readstring((pipeline(`ls /usr/bin`, stderr = DevNull)));
end
if ((contains(items,"\nunzip\n") == false) && (items != ""))
    for i in commands
        if (contains(items, "\n$(i)\n"))
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
        end
    end
end
