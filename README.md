BinDeps.jl
==========

Easily build binary dependencies for Julia packages 

# FAQ

Since there seems to be a lot of confusion surrounding the package 
systems and the role of this package, before we get started looking at
the actual package, I want to answer a few common questions:

  * What is `BinDeps`?

  	`BinDeps` is a package that provides a collection of tools to build binary dependencies for Julia packages. 

  * Do I need to use this package if I want to build binary
    dependencies for my Julia package?

    Absolutely not! The system is designed to give the maximum amount 
    of freedom to the package author in order to be able to address any 
    situation that one may encounter in the real world. This is achieved
    by simply evaluating a file called `deps/build.jl` (if it exists) in
    a package whenever it is installed or updated. Thus the following 
    might perhaps be the simplest possible useful `build.jl` script 
    one can imagine:

```julia
    run(`make`)
    Pkg2.markworking("MyPkg")
```

	The second command is optional and tells the package manger, not to
	consider this package broken in the `fixup` method. Unless you add 
	additional code to your package, it has no other effect and can thus
	be considered optional though recommended. 

  * I want to use BinDeps, but it is missing some functionality I need  
    (e.g. a package manager)

    Since BinDeps is written in Julia it is extensible with the same ease as the rest of Julia. In particular, defining new behavior,
    e.g. for adding a new package manger, consists of little more than
    adding a type and implementing a couple of methods (see the section on Interfaces) or the RPMmd package for an example implementation. 

  * I like the runtime features that BinDeps provides, but I don't 
    really want to use its build time capabilities. What do you 
    recommend?

    The easiest way to do this is probably just to declare a 
    `BuildProceess` for all your declared dependencies. This way, your 
    custom build process will be called whenever there is an unsatisfied
    library dependency and you my still use the BinDeps runtime 
    features.

  * Is there anything I should keep in mind when extending BinDeps or 
    writing my own build process?

    BinDeps uses a fairly standard set of directories by default and if
    possible, using the same directory structure is advised. Currently 
    the specified directory structure is:

```
	deps/
		build.jl 		# This is your build file
		downloads/  	# Store any binary/source downloads here
		builds/		
			dep1/		# out-of-tree build for dep1, is possible
			dep2/   	# out-of-tree build for dep1, is possible
		    ...
		src/		
			dep1/   	# Source code for dep1
			dep2/		# Source code for dep2
			...
		usr/			# "prefix", install your binaries here
			lib/		# Dynamic libraries (yes even on Windows)
			bin/		# Excecutables
			include/	# Headers
			...
```

# The high level interface - Declaring dependencies

To get a feel for the high level interface provided by BinDeps, have a look at a 
real-world example, namely the [build script from the Cairo package](https://github.com/JuliaLang/Cairo.jl/blob/kf/bindeps2/deps/build.jl).
That build script uses almost all the features that BinDeps currently provides and is a great overview, but let's take
it apart, to see exactly what's going on.

As you can see Cairo depends on a lot of libraries that all need to be managed by this build script. 
Every one of these library dependencies is introduced by the `library_dependency` function. The only required argument
is the name of the library, so the following would be an entirely valid call:

```julia
	foo = library_dependency("libfoo")
```

However, you'll most likely quickly run into the issue that this library is named differently on different systems, which is 
why BinDeps provides the handy `aliases` keyword argument. So suppose our library is sometimes known as `libfoo.so`, but 
other times as `libfoo-1.so` or `libfoo-1.0.0.dylib` or even `libbar.dll` on windows, because the authors of the library 
decided to punish windows uses. In either case, we can easily declare all these in our library dependency:

```julia
	foo = library_dependency("libfoo",aliases=["libfoo","libfoo-1","libfoo-1.0.0","libbar"])
```

So far so good!
There are a couple of other keyword arguments that are currently implemented and many more will most likely be added as 
necessary. The ones that are currently used are:

 * `os = OS_NAME`
 	Limits this dependency to certain operating systems. The same could be achieved by using the operating specific macro, but
 	this setting applies to all uses of this dependency and avoids having to wrap all uses of this dependency in macros.
 	Note that the `os` parameter must match the value of `Base.OS_NAME` on the target platform with the special exception that
 	`:Unix` matches all Unix-like platforms (e.g. `Linux`, `Mac OS X`, `FreeBSD`)
 	As an example, consider this line from the Cairo build script:

```julia
	gettext = library_dependency("gettext", aliases = ["libgettext", "libgettextlib"], os = :Unix)
```

 * `depends = [dep1,dep2]`
	Currently unused, but in the future will be used to keep track of the dependency graph between binary dependencies to allow parallel builds. E.g.:

```julia
	cairo = library_dependency("cairo", aliases = ["libcairo-2", "libcairo"], depends = [gobject,fontconfig,libpng])
```

 * `runtime::Bool`
 	Whether or not to consider this a runtime dependency. This means it's absence 
 	will not trigger an error at runtime (and it will not be loaded), but if it
 	cannot be found at buildtime it will be installed (useful for build-time) 
 	dependencies of other binary dependencies. 
 
 * `validate::Function`
 	You may pass a function to validate whether or not a certain library is usable,
 	e.g. whether or not has the correct version. To do so, pass a function that takes 
 	(name,handle) as an argument and returns `true` if the library is usable and `false` 
 	it not. The `name` argument is either an absolute path or the library name if it a
 	global system library, while the handle is a handle that may be passed to `ccall` or
 	`dlsym` to check library symbols or the return value of function. Note however that it 
 	is invalid to store the `handle`. Instead, use the `@load_dependencies` macro (see below).
 	Should the validation return false for a library that was installed by a provider, the 
 	provider will be instructed to force a rebuild.


# The high level interface - Declaring build mechanisms

Alright, now that we have declared all the dependencies that we
need let's tell BinDeps how to build them. One of the easiest ways 
to do so it to use the system package manger. So suppose we have 
defined the following dependencies:

```julia
	foo = library_dependency("libfoo")
	baz = library_dependency("libbaz")
```

And let's suppose that these libraries are available in the `foo` and `baz` 
packages in Homebrew, the `libfoo-dev` and `libbaz-dev` in apt-get and that both 
libraries are installed by the `libbaz` yum package. We may declare this as follows:

```julia
	provides(Homebrew,{
		"foo" => foo,
		"baz" => baz
	}
	provides(AptGet,{
		"libfoo-dev" => foo,
		"libbaz-dev" => baz,
	})
	provides(Yum,"libbaz",[foo,baz])
}
```

One may remember the `provides` function by thinking `Homebrew` `provides` the dependencies `foo` and `baz`. 

The basic signature of the provides function is
```julia
	provides(Provider, data, dependency, options...)
```

where `data` is provider-specific (e.g. a string in all of the package manager 
cases) and `dependency` is the return value from `library dependency. As you saw
above multiple definitions may be combined into one function call as such:
```julia
	provides(Provider,{data1=>dep1, data2=>dep2},options...)
```
which is equivalent to (and in fact will be internally dispatched) to:
```julia
	provides(Provider,data1,dep1,options...)
	provides(Provider,data2,dep2,options...)
```

If one provide satisfied multiple dependencies simultaneously, `dependency` may 
also be an array of dependencies (as in the `Yum` case above). 

There are also several builtin options. Some of them are:

 * `os = OS_NAME`

 	This provider can only satisfy the library dependency on the specified `os`. 
 	This argument takes has the same syntax as the `os` keyword argument to \
	`library_dependency`.

# The high level interface - built in providers

We have already seen the `Homebrew`, `Cairo` and `Yum` providers, which all take a string naming the package as their data argument. The other build-in providers are:

 * Sources

 	Takes a `URI` object as its data argument and declared that the sources may be 
 	downloaded from the provided URI. This dependency is special, because it's 
 	success does not automatically mark the build as succeeded (in BinDeps 
 	terminology, it's a "helper").

 * Binaries

 	If given a `URI` object as its data argument, indicates that the binaries may be 
 	downloaded from the provided URI. It is assumed that the binaries unpack the
	libraries into ``usr/lib``. If given a ``String`` as its data argument, provides
	a custom search path for the binaries. A typical use might be to allow the 
	user to provide a custom path by using an environmental variable. 

 * BuildProcess

 	Common super class of various kind of build processes. The exact behavior depends on the `data` argument. Some of the currently supported build processes are:

```julia
 	Autotools(;options...)
```
 	
 	Download the sources (as declared by the "Sources" provider) and attempt to 
 	install using Autotools. There is a plethora of options to change the behavior of 
 	this command. See the appropriate section of the manual (or even better, read the 
 	code) for more details on the available options.

  * SimpleBuild

    A subclass of BuildProcess that takes any object that's part of the low-level interface and could be passed to `run` and simply executes that command.

# The high level interface - Loading dependencies

BinDeps provides the `@BinDeps.load_dependencies` macro that you may call early in 
initialization process of your package to load all declared libraries in your build.jl
file. 

The basic usage is very simple:
```
using BinDeps
@BinDeps.load_dependencies
```

This will make all your libraries available as variables named by the names you gave 
the dependency. E.g. if you declared a dependency as

```julia
	library_dependency("libfoo")
```

The `libfoo` variable will now contain a reference to that library that may be passed
to `ccall` or similar functions. 

If you only want to load a subset of the declared dependencies you may pass the macro
a list of libraries to load, e.g. 
```julia
@BinDeps.load_dependencies [:libfoo, :libbar]
```

if you do not want to change the names of the variables that these libraries get 
stored in, you may use

```julia
@BinDeps.load_dependencies [:libfoo=>:_foo, :libbar=>:_bar]
```

which will assign the result to the `_foo` and `_bar` variables instead. 

# The low level interface
	
   The low level interface provides a number of utilities to write cross platform 
   build scripts. It looks something like this (from the Cairo build script):

```julia
	@build_steps begin
		GetSources(libpng)
		CreateDirectory(pngbuilddir)
		@build_steps begin
			ChangeDirectory(pngbuilddir)
			FileRule(joinpath(prefix,"lib","libpng15.dll"),@build_steps begin
				`cmake -DCMAKE_INSTALL_PREFIX="$prefix" -G"MSYS Makefiles" $pngsrcdir`
				`make`
				`cp libpng*.dll $prefix/lib`
				`cp libpng*.a $prefix/lib`
				`cp libpng*.pc $prefix/lib/pkgconfig`
				`cp pnglibconf.h $prefix/include`
				`cp $pngsrcdir/png.h $prefix/include`
				`cp $pngsrcdir/pngconf.h $prefix/include`
			end)
		end
	end
```
	All the steps are executed synchronously. The result of the `@build_steps` macro 
	may be passed to run to execute it directly, thought this is not recommended other
	than for debugging purposes. Instead, please use the high level interface to tie 
	the build process to dependencies. 

	Some of the build builtin build steps are:

  * FileDownloader(remote_file,local_file)

  	Download a file from `remote_file` create it as `local_file`

  * FileUnpacker(local_file,folder)

    Unpack the file `local_file` into the folder `folder`

  * AutotoolsDependency(opts...)

  	Invoke autotools. Use of this build step is not recommended. Use the high level  
  	interface instead

  * CreateDirectory(dir)

  	Create the directory `dir`

  * ChangeDirectory(dir)

  	`cd` into the directory `dir` and try to remain there for this build block. Must
  	be the first command in a `@build_steps` block and will remain active for the entire block

  * MakeTargets([dir,],[args...],env)

  	Invoke `make` with the given arguments in the given directory with the given environment. 

  * DirectoryRule(dir,step)

  	If `dir` does not exist invoke step and validate that the directory was created

  * FileRule([files...],step)

  	Like Directory rule, but validates the existence of any of the files in the `files
  	`array`.

  * GetSources(dep)

  	Get the declared sources from the dependency dep and put them in the default 
  	download location
