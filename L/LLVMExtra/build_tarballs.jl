using BinaryBuilder, Pkg
using Base.BinaryPlatforms

include("../../fancy_toys.jl")

name = "LLVMExtra"
repo = "https://github.com/maleadt/LLVM.jl.git"
version = v"0.0.14"

llvm_versions = [v"11.0.1", v"12.0.1", v"13.0.1"]

# Collection of sources required to build LLVMExtra
sources = [GitSource(repo, "141adedf59bb868bca40b0b9ec1267127413de5c")]

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
platforms = expand_cxxstring_abis(supported_platforms(; experimental=true))

# Bash recipe for building across all platforms
script = raw"""
cd LLVM.jl/deps/LLVMExtra

CMAKE_FLAGS=()
# Release build for best performance
CMAKE_FLAGS+=(-DCMAKE_BUILD_TYPE=RelWithDebInfo)
# Install things into $prefix
CMAKE_FLAGS+=(-DCMAKE_INSTALL_PREFIX=${prefix})
# Explicitly use our cmake toolchain file and tell CMake we're cross-compiling
CMAKE_FLAGS+=(-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN})
CMAKE_FLAGS+=(-DCMAKE_CROSSCOMPILING:BOOL=ON)
# Tell CMake where LLVM is
CMAKE_FLAGS+=(-DLLVM_DIR="${prefix}/lib/cmake/llvm")
# Force linking against shared lib
CMAKE_FLAGS+=(-DLLVM_LINK_LLVM_DYLIB=ON)
# Build the library
CMAKE_FLAGS+=(-DBUILD_SHARED_LIBS=ON)
cmake -B build -S . -GNinja ${CMAKE_FLAGS[@]}

ninja -C build -j ${nproc} install
"""

augment_platform_block = """
    using Base.BinaryPlatforms

    function augment_platform!(platform::Platform)
        haskey(platform, "llvm_version") && return p

        llvm_version = Base.libllvm_version

        # does our LLVM build use assertions?
        llvm_assertions = try
            cglobal((:_ZN4llvm24DisableABIBreakingChecksE, Base.libllvm_path()), Cvoid)
            false
        catch
            true
        end

        platform["llvm_version"] = if llvm_assertions
            "\$(llvm_version.major).asserts"
        else
            "\$(llvm_version.major)"
        end

        return platform
    end"""

# determine exactly which tarballs we should build
builds = []
for llvm_version in llvm_versions, llvm_assertions in (false, true)
    # Dependencies that must be installed before this package can be built
    llvm_name = llvm_assertions ? "LLVM_full_assert_jll" : "LLVM_full_jll"
    dependencies = [
        BuildDependency(PackageSpec(name=llvm_name, version=llvm_version))
    ]

    # The products that we will ensure are always built
    products = Product[
        LibraryProduct(["libLLVMExtra-$(llvm_version.major)", "libLLVMExtra"],
                       :libLLVMExtra, dont_dlopen=true),
    ]

    for platform in platforms
        augmented_platform = deepcopy(platform)
        augmented_platform["llvm_version"] = if llvm_assertions
            "$(llvm_version.major).asserts"
        else
            "$(llvm_version.major)"
        end

        should_build_platform(triplet(augmented_platform)) || continue
        push!(builds, (;
            dependencies, products,
            platforms=[augmented_platform],
        ))
    end
end

# don't allow `build_tarballs` to override platform selection based on ARGS.
# we handle that ourselves by calling `should_build_platform`
non_platform_ARGS = filter(arg -> startswith(arg, "--"), ARGS)

# `--register` should only be passed to the latest `build_tarballs` invocation
non_reg_ARGS = filter(arg -> arg != "--register", non_platform_ARGS)

for (i,build) in enumerate(builds)
    build_tarballs(i == lastindex(builds) ? non_platform_ARGS : non_reg_ARGS,
                   name, version, sources, script,
                   build.platforms, build.products, build.dependencies;
                   preferred_gcc_version=v"8", julia_compat="1.6",
                   augment_platform_block)
end
