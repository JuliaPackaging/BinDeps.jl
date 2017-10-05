"""
    download_cmd(url, filename)

Downloads file from `url` to local `filename`.
"""
function download_cmd end

# global set by download_cmd below
downloadcmd = nothing

function download_cmd(url::AbstractString, filename::AbstractString)
    global downloadcmd
    if downloadcmd === nothing
        for download_engine in (Compat.Sys.iswindows() ? ("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell",
                :powershell, :curl, :wget, :fetch) : (:curl, :wget, :fetch))
            if endswith(string(download_engine), "powershell")
                checkcmd = `$download_engine -NoProfile -Command ""`
            else
                checkcmd = `$download_engine --help`
            end
            try
                if success(checkcmd)
                    downloadcmd = download_engine
                    break
                end
            catch
                continue # don't bail if one of these fails
            end
        end
    end
    if downloadcmd == :wget
        return `$downloadcmd -O $filename $url`
    elseif downloadcmd == :curl
        return `$downloadcmd -f -o $filename -L $url`
    elseif downloadcmd == :fetch
        return `$downloadcmd -f $filename $url`
    elseif endswith(string(downloadcmd), "powershell")
        return `$downloadcmd -NoProfile -Command "(new-object net.webclient).DownloadFile(\"$url\", \"$filename\")"`
    else
        extraerr = Compat.Sys.iswindows() ? "check if powershell is on your path or " : ""
        error("No download agent available; $(extraerr)install curl, wget, or fetch.")
    end
end


"""
    unpack_cmd(file, directory, extension, secondary_extension)

Extract archive `file` based to `directory`, where the appropriate tool is determined by the use of `extension` and `secondary_extension`.

Currently supported extensions are:

| extension | secondary_extension |
|-----------|---------------------|
| .zip      |                     |
| .gz       |                     |
| .tar      |                     |
| .gz       | .tar                |
| .Z        | .tar                |
| .tgz      |                     |
| .bz2      | .tar                |
| .tbz      |                     |
| .xz       | .tar                |
"""
function unpack_cmd end

if Compat.Sys.isunix() && Sys.KERNEL != :FreeBSD
    function unpack_cmd(file,directory,extension,secondary_extension)
        if ((extension == ".gz" || extension == ".Z") && secondary_extension == ".tar") || extension == ".tgz"
            return (`tar xzf $file --directory=$directory`)
        elseif (extension == ".bz2" && secondary_extension == ".tar") || extension == ".tbz"
            return (`tar xjf $file --directory=$directory`)
        elseif extension == ".xz" && secondary_extension == ".tar"
            return pipeline(`unxz -c $file `, `tar xv --directory=$directory`)
        elseif extension == ".tar"
            return (`tar xf $file --directory=$directory`)
        elseif extension == ".zip"
            return (`unzip -x $file -d $directory`)
        elseif extension == ".gz"
            return pipeline(`mkdir $directory`, `cp $file $directory`, `gzip -d $directory/$file`)
        end
        error("I don't know how to unpack $file")
    end
end

if Sys.KERNEL == :FreeBSD
    # The `tar` on FreeBSD can auto-detect the archive format via libarchive.
    # The supported formats can be found in libarchive-formats(5).
    # For NetBSD and OpenBSD, libarchive is not available.
    # For macOS, it is. But the previous unpack function works fine already.
    function unpack_cmd(file, dir, ext, secondary_ext)
        tar_args = ["--no-same-owner", "--no-same-permissions"]
        return pipeline(
            `/bin/mkdir -p $dir`,
            `/usr/bin/tar -xf $file -C $dir $tar_args`)
    end
end

if Compat.Sys.iswindows()
    const exe7z = joinpath(JULIA_HOME, "7z.exe")

    function unpack_cmd(file,directory,extension,secondary_extension)
        if ((extension == ".Z" || extension == ".gz" || extension == ".xz" || extension == ".bz2") &&
                secondary_extension == ".tar") || extension == ".tgz" || extension == ".tbz"
            return pipeline(`$exe7z x $file -y -so`, `$exe7z x -si -y -ttar -o$directory`)
        elseif (extension == ".zip" || extension == ".7z" || extension == ".tar" ||
                (extension == ".exe" && secondary_extension == ".7z"))
            return (`$exe7z x $file -y -o$directory`)
        end
        error("I don't know how to unpack $file")
    end
end
