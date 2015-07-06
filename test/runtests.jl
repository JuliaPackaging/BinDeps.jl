Pkg.add("Cairo")  # Tests apt-get code paths
using Cairo
Pkg.add("HttpParser")  # Tests build-from-source code paths
using HttpParser
Pkg.add("ECOS")  # Build-from-source
Pkg.build("ECOS")  # Double-build it
