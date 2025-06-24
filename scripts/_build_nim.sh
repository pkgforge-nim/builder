#!/usr/bin/env bash

#-------------------------------------------------------#
##Usage:
# "./_build_nim.sh" --help
# Examples:
#   CC="riscv64-linux-gnu-gcc" CXX="riscv64-linux-gnu-g++" "./_build_nim.sh" -a "riscv64"
#   CC="zig cc -target riscv64-linux-musl" CXX="zig c++ -target riscv64-linux-musl" "./_build_nim.sh" -a "riscv64"
# 
set -e
#-------------------------------------------------------#

#-------------------------------------------------------#
##ENV
#Script metadata
SCRIPT_VERSION="0.0.1"
SCRIPT_NAME="${0##*/}"
#Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'
#Default configuration
CURRENT_WORKING_DIR="$(realpath $(pwd))"
DEFAULT_NIM_VERSION="stable"
DEFAULT_BUILD_JOBS=""  # Auto-detect max_procs
DEFAULT_OUTPUT_DIR="${CURRENT_WORKING_DIR}/nim-build"
DEFAULT_CLEANUP="yes"
DEFAULT_OPTIMIZATION="release"
DEFAULT_COMPRESSION="9"
DEFAULT_VERBOSE="no"
DEFAULT_TARGET_ARCH="$(uname -m)"
DEFAULT_TARGET_OS="linux"
#Architectures
declare -A ARCH_ALIASES=(
    [arm64]=aarch64 [armv8]=aarch64 [armhf]=arm [armel]=arm
    [mips64el]=mips64 [ppc64]=powerpc64 [ppc]=powerpc
    [i686]=i386 [x64]=x86_64 [amd64]=x86_64
    [loong64]=loongarch64 [la64]=loongarch64
)
#-------------------------------------------------------#

#-------------------------------------------------------#
##Funcs
#Loggers
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_debug() { [[ "${VERBOSE}" == "yes" ]] && echo -e "${PURPLE}[DEBUG]${NC} $1"; }
#Help
show_help() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - Nim Cross-Compilation Script

USAGE: ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -a, --arch ARCH         Target architecture (default: ${DEFAULT_TARGET_ARCH})
                            Supported: aarch64, arm, armv7, i386, loongarch64, mips64,
                                     mips, powerpc64, powerpc, riscv64, s390x, sparc64, x86_64
                            Aliases: arm64->aarch64, x64->x86_64, loong64->loongarch64, etc.
    
    -v, --version VERSION   Nim version: stable, devel, or tag (default: ${DEFAULT_NIM_VERSION})
    -j, --jobs JOBS         Parallel build jobs (default: auto-detect)
    -o, --output DIR        Output directory (default: current)
    -O, --optimization LVL  release, debug, danger (default: ${DEFAULT_OPTIMIZATION})
    -c, --compression LVL   Gzip level 1-9 (default: ${DEFAULT_COMPRESSION})
    --no-cleanup            Keep temporary directories
    --verbose               Enable verbose output
    -h, --help              Show this help

ENVIRONMENT VARIABLES:
    CC, CXX                 C/C++ compilers (e.g., zig cc, clang)
    CFLAGS, CXXFLAGS        Compiler flags
    HOST_CC, HOST_CXX       Host Compiler to bootstrap the Nim Compiler
    LDFLAGS                 Linker flags  
    AR, STRIP               Archiver and strip tools
    NIM_VERSION, BUILD_JOBS, OUTPUT_DIR, TARGET_ARCH, TARGET_OS

EXAMPLES:
    ${SCRIPT_NAME} -a aarch64                                          # ARM64 build
    CC="zig cc -target riscv64-linux-musl" ${SCRIPT_NAME} -a riscv64   # Using Zig compiler
    ${SCRIPT_NAME} -a loongarch64 -v devel                             # LoongArch64 devel build
EOF
}
#Normalize architecture
normalize_arch() {
    local arch="${1,,}"
    echo "${ARCH_ALIASES[${arch}]:-${arch}}"
}
#Validate architecture
validate_arch() {
    local arch
    arch="$(normalize_arch "$1")"
    local supported="aarch64 arm armv7 i386 loongarch64 mips mips64 powerpc64 powerpc riscv64 s390x sparc64 x86_64"
    
    for sup in ${supported}; do
        [[ "${arch}" == "${sup}" ]] && { echo "${arch}"; return; }
    done
    
    log_error "Unsupported architecture: $1"
    echo "Supported: ${supported}"
    exit 1
}
#Arge Parser
parse_args() {
    while (( $# )); do
        case $1 in
            -a|--arch) TARGET_ARCH="$2"; shift 2 ;;
            -v|--version) NIM_VERSION="$2"; shift 2 ;;
            -j|--jobs) BUILD_JOBS="$2"; shift 2 ;;
            -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
            -O|--optimization) OPTIMIZATION="$2"; shift 2 ;;
            -c|--compression) COMPRESSION="$2"; shift 2 ;;
            --no-cleanup) CLEANUP="no"; shift ;;
            --verbose) VERBOSE="yes"; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
}
#Get Host Compiler
get_host_cc() {

    [[ -n "${HOST_CC}" && (-x "${HOST_CC}" || $(command -v "${HOST_CC}" &>/dev/null)) ]] && return

    if command -v clang &>/dev/null; then
        export HOST_CC="clang"
        command -v clang++ &>/dev/null && export HOST_CXX="clang++"
    elif command -v gcc &>/dev/null; then
        export HOST_CC="gcc"
        command -v g++ &>/dev/null && export HOST_CXX="g++"
    else
        echo "Error: No suitable compiler found" >&2
        log_error "No suitable compiler found"
        exit 1
    fi

    log_success "Host Compiler [${HOST_CC} | ${HOST_CXX}] OK"
}
#Initialize configuration
init_config() {
    #Environment overrides or defaults
    get_host_cc
    NIM_VERSION="${NIM_VERSION:-${DEFAULT_NIM_VERSION}}"
    BUILD_JOBS="${BUILD_JOBS:-${DEFAULT_BUILD_JOBS}}"
    OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_OUTPUT_DIR}}"
    CLEANUP="${CLEANUP:-${DEFAULT_CLEANUP}}"
    OPTIMIZATION="${OPTIMIZATION:-${DEFAULT_OPTIMIZATION}}"
    COMPRESSION="${COMPRESSION:-${DEFAULT_COMPRESSION}}"
    VERBOSE="${VERBOSE:-${DEFAULT_VERBOSE}}"
    TARGET_ARCH="${TARGET_ARCH:-${DEFAULT_TARGET_ARCH}}"
    TARGET_OS="${TARGET_OS:-${DEFAULT_TARGET_OS}}"
    
    TARGET_ARCH=$(validate_arch "${TARGET_ARCH}")
    
    #Auto-detect max_procs
    [[ -z "${BUILD_JOBS}" ]] && BUILD_JOBS="$(nproc 2>/dev/null || echo '4')"
    
    #Validate inputs
    [[ "${BUILD_JOBS}" =~ ^[0-9]+$ ]] || { log_error "Invalid BUILD_JOBS"; exit 1; }
    [[ "${COMPRESSION}" =~ ^[1-9]$ ]] || { log_error "Invalid COMPRESSION"; exit 1; }
    [[ "${TARGET_OS}" == "linux" ]] || { log_error "Only linux OS supported"; exit 1; }
    
    #Create output directory
    mkdir -p "${OUTPUT_DIR}"
    OUTPUT_DIR="$(realpath "${OUTPUT_DIR}")"
    
    #Set optimization flags  
    case "${OPTIMIZATION}" in
        release) NIM_RELEASE_OPTS="-d:release -d:strip --opt:speed" ;;
        debug) NIM_RELEASE_OPTS="--opt:none --debugger:native" ;;
        danger) NIM_RELEASE_OPTS="-d:release -d:strip -d:danger --opt:speed" ;;
        *) log_error "Invalid optimization: ${OPTIMIZATION}"; exit 1 ;;
    esac
    
    #Set build directories
    TEMP_DIR="$(mktemp -d -t nim-build-XXXXXX)"
    BUILD_DIR="${TEMP_DIR}/nim-build"
    export TEMP_DIR BUILD_DIR
    
    #Build options
    MAKE_OPTS="-j${BUILD_JOBS}"
    NIM_OPTS="--parallelBuild:${BUILD_JOBS} --hints:off --warnings:off"
    [[ "${VERBOSE}" == "yes" ]] && NIM_OPTS="--parallelBuild:${BUILD_JOBS} --hints:on"
    
    #Map to Nim CPU names
    case "${TARGET_ARCH}" in
        x86_64) NIM_CPU="amd64" ;;
        i386) NIM_CPU="i386" ;;
        aarch64) NIM_CPU="arm64" ;;
        arm|armv7) NIM_CPU="arm" ;;
        *) NIM_CPU="${TARGET_ARCH}" ;;
    esac
    
    NIM_OS="linux"
    
    #Set compilers
    CC="${CC:-gcc}"
    CXX="${CXX:-g++}"
    AR="${AR:-ar}"
    STRIP="${STRIP:-strip}"
    
    #Detect if we're cross-compiling
    HOST_ARCH="$(uname -m)"
    CROSS_COMPILING="no"
    [[ "${TARGET_ARCH}" != "${HOST_ARCH}" ]] && CROSS_COMPILING="yes"
}
#Print Config
show_config() {
    log_info "Configuration:"
    echo "  Target: ${TARGET_ARCH}-${TARGET_OS} (Nim: ${NIM_CPU}-${NIM_OS})"
    echo "  Host: ${HOST_ARCH} (Cross-compiling: ${CROSS_COMPILING})"
    echo "  Bootstrap: CC=${HOST_CC}, CXX=$HOST_CXX"
    echo "  Version: ${NIM_VERSION}, Jobs: ${BUILD_JOBS}, Opt: ${OPTIMIZATION}"
    echo "  Compiler (CC): ${CC}, Compiler (C++): ${CXX}"
    echo "  Temp: ${TEMP_DIR}, Output: ${OUTPUT_DIR}"
    echo
}
#Cleanup
cleanup() {
    local exit_code=$?
    [[ "${CLEANUP}" == "yes" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
    (( exit_code )) && log_error "Build failed with exit code ${exit_code}"
    popd &>/dev/null ; cd "${CURRENT_WORKING_DIR}"
}
#Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=0
    for cmd in "${CC}" "${CXX}" git make tar gzip; do
        command -v "${cmd}" >/dev/null || { log_error "${cmd} not found"; missing=1; }
    done
    
    (( missing )) && exit 1
    
    #Test compiler
    if ! "${CC}" --version &>/dev/null; then
        log_error "Compiler ${CC} not working"
        exit 1
    fi
    
    log_success "Prerequisites OK"
}
#Clone Nim repository
clone_nim_repository() {
    log_info "Cloning Nim repository..."
    
    mkdir -p "${BUILD_DIR}"
    pushd "${BUILD_DIR}" &>/dev/null
    
    rm -rf Nim 2>/dev/null || true
    if git clone --filter="blob:none" --depth 50 "https://github.com/nim-lang/Nim.git" "./Nim" 2>/dev/null; then
        pushd "./Nim" &>/dev/null
        SOURCE_DIR="$(realpath .)" ; export SOURCE_DIR
        log_success "Cloned from https://github.com/nim-lang/Nim.git"
    else
        log_error "Failed to clone Nim repository"
        exit 1
    fi
}
#Checkout version
checkout_nim_version() {
    log_info "Checking out: ${NIM_VERSION}"
    
    if [[ "${NIM_VERSION}" == "stable" ]]; then
        git fetch --depth 50 origin "+refs/tags/*:refs/tags/*" 2>/dev/null || true
        local latest_tag
        latest_tag="$(git tag -l --sort=-version:refname | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
        if [[ -n "${latest_tag}" ]] && git checkout "${latest_tag}" 2>/dev/null; then
            ACTUAL_VERSION="${latest_tag}"
        else
            log_warn "No stable tags found, using devel"
            git checkout devel
            ACTUAL_VERSION="devel-$(git rev-parse --short HEAD)"
        fi
    elif [[ "${NIM_VERSION}" == "devel" ]]; then
        git checkout devel
        ACTUAL_VERSION="devel-$(git rev-parse --short HEAD)"
    else
        if git checkout "${NIM_VERSION}" 2>/dev/null; then
            ACTUAL_VERSION="${NIM_VERSION}"
        else
            log_error "Failed to checkout: ${NIM_VERSION}"
            exit 1
        fi
    fi
    
    log_success "Using: ${ACTUAL_VERSION}"
}
#Clone csources
clone_csources() {
    log_info "Cloning csources..."
    
    if git clone --depth 1 "https://github.com/nim-lang/csources_v2.git" "csources_v2" 2>/dev/null; then
        CSOURCES_DIR="csources_v2"
        log_success "Using csources: csources_v2"
    else
        log_error "Failed to clone csources"
        exit 1
    fi
}
#Bootstrap Nim
bootstrap_nim() {
    log_info "Bootstrapping Nim...\n"

    pushd "${CSOURCES_DIR}" &>/dev/null
    
    #Host-optimized build for bootstrap
    log_debug "RUN: make CC='${HOST_CC:-CC}' $MAKE_OPTS CFLAGS='-O3 -DNDEBUG'"
    echo
    make CC="${HOST_CC:-CC}" $MAKE_OPTS CFLAGS="-O3 -DNDEBUG" 2>/dev/null || make CC="${HOST_CC:-CC}"
    
    pushd "${SOURCE_DIR}" &>/dev/null
    
    #Find nim binary
    local nim_binary=""
    for location in bin/nim nim compiler/nim "${CSOURCES_DIR}/nim"; do
        [[ -f "${location}" && -x "${location}" ]] && { nim_binary="${location}"; break; }
    done
    
    [[ -z "${nim_binary}" ]] && { log_error "Bootstrap nim binary not found"; exit 1; }
    
    #Build koch
    log_debug "RUN: \"${nim_binary}\" c $NIM_OPTS $NIM_RELEASE_OPTS koch"
    echo
    "${nim_binary}" c $NIM_OPTS $NIM_RELEASE_OPTS koch
    [[ ! -f "koch" ]] && { log_error "Koch not found"; exit 1; }
    
    #Bootstrap with koch
    echo
    log_debug "RUN: \"./koch\" boot $NIM_RELEASE_OPTS $NIM_OPTS"
    echo
    "./koch" boot $NIM_RELEASE_OPTS $NIM_OPTS
    
    log_success "Bootstrap completed"
}
#Cross-compile
cross_compile_nim() {
    log_info "Cross-compiling for ${TARGET_ARCH}...\n"
    
    #Verify compiler
    "${CC}" --version >/dev/null || { log_error "Cross-compiler ${CC} not working"; exit 1; }
    
    #Set environment
    export CC CXX AR
    
    #Architecture-specific optimizations
    local arch_cflags=""
    case "${TARGET_ARCH}" in
        aarch64) arch_cflags="-march=armv8-a" ;;
        arm|armv7) arch_cflags="-march=armv7-a" ;;
        riscv64) arch_cflags="-march=rv64gc" ;;
        mips64) arch_cflags="-march=mips64r2" ;;
        x86_64) arch_cflags="-march=x86-64" ;;
        i386) arch_cflags="-march=i686" ;;
        loongarch64) arch_cflags="-march=loongarch64" ;;
    esac
    
    #Use provided CFLAGS or set defaults
    if [[ "${VERBOSE}" == "yes" ]]; then
      export CFLAGS="${CFLAGS:--O3 -DNDEBUG ${arch_cflags}} -g0 -pipe -static -v -w -Wno-error"
    else
      export CFLAGS="${CFLAGS:--O3 -DNDEBUG ${arch_cflags}} -g0 -pipe -static -w -Wno-error"
    fi
    export CXXFLAGS="${CXXFLAGS:-${CFLAGS}}"
    export LDFLAGS="${LDFLAGS:--static -Wl,--build-id=none,--static,--strip-all}"
    echo
    log_debug "Using CFLAGS: ${CFLAGS}"
    log_debug "Using CXXFLAGS: ${CXXFLAGS}"
    log_debug "Using LDFLAGS: ${LDFLAGS}"
    echo
    
    #Build tools (continue on failure)
    log_debug "RUN: \"./koch\" tools $NIM_RELEASE_OPTS $NIM_OPTS --cpu:$NIM_CPU --os:$NIM_OS --passC:\"${CFLAGS}\" --passL:\"${LDFLAGS}\""
    echo
    "./koch" tools $NIM_RELEASE_OPTS $NIM_OPTS \
        --cpu:$NIM_CPU --os:$NIM_OS --passC:"${CFLAGS}" --passL:"${LDFLAGS}" 2>/dev/null || true
    
    #Cross-compile main compiler
    local cross_opts
    cross_opts="--cpu:${NIM_CPU} --os:${NIM_OS} ${NIM_RELEASE_OPTS} ${NIM_OPTS}"
    cross_opts="${cross_opts} --gcc.exe:${CC} --gcc.linkerexe:${CC}"
    cross_opts="${cross_opts} --passC:\"${CFLAGS}\" --passL:\"${LDFLAGS}\""
    echo
    log_debug "Using OPTS: ${cross_opts}"
    cross_cmd="\"bin/nim\" c ${cross_opts}"

    #Find and compile nim source
    for source in "compiler/nim.nim" "nim.nim" "src/nim.nim"; do
        if [[ -f "${source}" ]]; then
            echo
            log_debug "Compiling: ${source}"
            log_debug "RUN: eval \"${cross_cmd}\" \"${source}\""
            if eval "${cross_cmd}" "${source}"; then
                break
            else
                log_error "Failed to compile: ${source}"
                exit 1
            fi
        fi
    done
    
    #Find cross-compiled binary
    for location in "compiler/nim" "nim"; do
        if [[ -f "${location}" ]]; then
            CROSS_NIM_BINARY="${location}"
            break
        fi
    done
    
    [[ -z "${CROSS_NIM_BINARY}" ]] && { log_error "Cross-compiled binary not found"; exit 1; }
    
    #Show binary info
    if command -v file >/dev/null; then
        local file_output
        file_output="$(file "${CROSS_NIM_BINARY}")"
        echo
        log_info "Binary: ${file_output}"
        log_info "Size: $(du -h "${CROSS_NIM_BINARY}" | cut -f1)"
    fi
    
    #Strip if available and not debug build
    if command -v "${STRIP}" >/dev/null && [[ "${OPTIMIZATION}" != "debug" ]]; then
        "${STRIP}" "${CROSS_NIM_BINARY}" 2>/dev/null || true
    fi
    
    log_success "Cross-compilation completed: ${CROSS_NIM_BINARY}"
}
#Test binary (only if not cross-compiling)
test_binary() {
    if [[ "${CROSS_COMPILING}" == "no" ]]; then
        log_info "Testing binary..."
        if "${CROSS_NIM_BINARY}" --version &>/dev/null; then
            log_success "Binary test passed"
        else
            log_warn "Binary test failed"
        fi
    else
        log_info "Skipping binary test (cross-compiled for ${TARGET_ARCH})"
    fi
}
#Create distribution
create_distribution() {
    log_info "Creating distribution...\n"
    #Set Vars
    local dist_name="nim-${TARGET_ARCH}-${TARGET_OS}-${OPTIMIZATION}-${ACTUAL_VERSION#v}"
    local dist_dir="${BUILD_DIR}/${dist_name}"
    #Create dirs
    rm -rf "${dist_dir}"
    nim_dirs=("bin" "config" "compiler" "lib" "nimpretty" "nimsuggest" "src/lib" "stdlib" "tools")
    mkdir -p "${dist_dir}"
    for dir in "${nim_dirs[@]}"; do
        mkdir -p "${dist_dir}/${dir}"
    done
    #Copy Dirs
    for dir in "${nim_dirs[@]}"; do
        if [[ -d "${SOURCE_DIR}/${dir}" ]]; then
            cp -frv "${SOURCE_DIR}/${dir}/." "${dist_dir}/${dir}"
            log_info "Copied ${SOURCE_DIR}/${dir} ==> ${dist_dir}/${dir}"
        else
            log_warn "${SOURCE_DIR}/${dir} does not exist"
        fi
    done
    #Copy Files
    for file in "copying.txt" "koch.nim" "nim.nimble" "LICENSE" "README.md"; do
        [[ -f "${SOURCE_DIR}/${file}" ]] && cp -fv "${SOURCE_DIR}/${file}" "${dist_dir}/${file}"
    done
    #Copy /bin
    cp -fv "${CROSS_NIM_BINARY}" "${dist_dir}/bin/nim"
    chmod +x "${dist_dir}/bin/"*
    #Copy Koch
    if [[ -f "${SOURCE_DIR}/koch" ]]; then
      cp -fv "${SOURCE_DIR}/koch" "${dist_dir}/koch"
      chmod +x "${dist_dir}/koch"
    else
      log_warn "${SOURCE_DIR}/koch does not exist"
    fi
    #Exit
    DIST_DIR="${dist_dir}"
    DIST_NAME="${dist_name}"
    log_success "Distribution created: ${DIST_DIR}"
}
#Create tarball
create_tarball() {
    log_info "Creating tarball (compression: ${COMPRESSION})...\n"
    
    pushd "${BUILD_DIR}" &>/dev/null
    local tarball_name="${DIST_NAME}.tar.gz"
    
    if [[ "${VERBOSE}" == "yes" ]]; then
      tar -cf "${tarball_name}" --use-compress-program="gzip -${COMPRESSION}" -v "${DIST_NAME}/"
    else
      tar -cf "${tarball_name}" --use-compress-program="gzip -${COMPRESSION}" "${DIST_NAME}/"
    fi
    
    [[ ! -f "${tarball_name}" ]] && { log_error "Tarball creation failed"; exit 1; }
    
    local output_path="${OUTPUT_DIR}/${tarball_name}"
    mv "${tarball_name}" "${output_path}"
    
    local tarball_size
    tarball_size="$(du -h "${output_path}" | cut -f1)"
    local dir_size
    dir_size="$(du -sh "${DIST_DIR}" | cut -f1)"
    
    FINAL_TARBALL="${output_path}"
    echo
    log_success "Tarball: ${FINAL_TARBALL} (${tarball_size} <== ${dir_size})"
}
#Show summary
show_summary() {
    echo
    log_success "=== Build Completed ==="
    echo "Target: ${TARGET_ARCH}-${TARGET_OS}"
    echo "Version: ${ACTUAL_VERSION}"
    echo "Package: $(basename "${FINAL_TARBALL}")"  
    echo "Location: ${FINAL_TARBALL}"
    if [[ "${CLEANUP}" == "no" ]]; then
      echo "Temp (Build Dir): ${BUILD_DIR}"
    fi
    echo "Size: $(du -h "${FINAL_TARBALL}" | cut -f1)"
    echo
    echo "Usage on target system:"
    echo "  tar -xzf $(basename "${FINAL_TARBALL}")"
    echo "  export PATH=\$PATH:\$PWD/${DIST_NAME}/bin"
    echo "  nim --version"
    echo
    echo -e "Build time: $((SECONDS/60))m $((SECONDS%60))s\n"
}
#-------------------------------------------------------#

#-------------------------------------------------------#
#Main function
main() {
    echo "=== Nim Cross-Compilation Script v${SCRIPT_VERSION} ==="
    echo
    
    parse_args "$@"
    init_config
    show_config
    
    trap cleanup EXIT
    
    check_prerequisites
    clone_nim_repository
    checkout_nim_version
    clone_csources
    bootstrap_nim
    cross_compile_nim
    test_binary
    create_distribution
    create_tarball
    show_summary
}
main "$@"
#-------------------------------------------------------#
