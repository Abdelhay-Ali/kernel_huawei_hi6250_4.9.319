#!/usr/bin/env bash

msg(){
    echo
    echo "==> $*"
    echo
}

err(){
    echo 1>&2
    echo "==> $*" 1>&2
    echo 1>&2
}

set_output(){
    echo "$1=$2" >> $GITHUB_OUTPUT
}

extract_tarball(){
    echo "Extracting $1 to $2"
    tar xf "$1" -C "$2"
}
#: <<'END'
workdir="$GITHUB_WORKSPACE"
arch="$1"
compiler="$2"
defconfig="$3"
image="$4"
repo_name="${GITHUB_REPOSITORY/*\/}"
zipper_path="${ZIPPER_PATH:-zipper}"
kernel_path="${KERNEL_PATH:-.}"
name="${NAME:-$repo_name}"
python_version="${PYTHON_VERSION:-3}"

msg "Updating container..."
apt update && apt upgrade -y
msg "Installing essential packages..."
apt install -y --no-install-recommends git make bc bison openssl \
    curl zip kmod cpio flex libelf-dev libssl-dev libtfm-dev wget \
    device-tree-compiler ca-certificates python3 python2 xz-utils
ln -sf "/usr/bin/python${python_version}" /usr/bin/python
set_output hash "$(cd "$kernel_path" && git rev-parse HEAD || exit 127)"

msg "Installing toolchain..."
if [[ $arch = "arm64" ]]; then
    arch_opts="ARCH=${arch} SUBARCH=${arch}"
    export ARCH="$arch"
    export SUBARCH="$arch"

    if [[ $compiler = gcc/* ]]; then
        ver_number="${compiler/gcc\/}"
        make_opts=""
        host_make_opts=""
        apt update && apt install sudo

        if ! apt install -y --no-install-recommends gcc-9 g++-9; then
            err "Compiler package not found, refer to the README for details"
            exit 1
        fi
        
        wget -c https://releases.linaro.org/components/toolchain/binaries/7.5-2019.12/aarch64-elf/gcc-linaro-7.5.0-2019.12-x86_64_aarch64-elf.tar.xz --no-check-certificate
        tar -xvf gcc-linaro-7.5.0-2019.12-x86_64_aarch64-elf.tar.xz
        git config --global --add safe.directory /github/workspace

        ln -sf /usr/bin/gcc-"$ver_number" /usr/bin/gcc
        ln -sf /usr/bin/g++-"$ver_number" /usr/bin/g++
        # ln -sf /usr/bin/aarch64-linux-gnu-gcc-"$ver_number" /usr/bin/aarch64-linux-gnu-gcc
        # ln -sf/github/workspace/gcc-linaro-7.5.0-2019.12-x86_64_aarch64-elf/bin/aarch64-elf-gcc-7.5.0 /usr/bin/aarch64-linux-gnu-gcc

        #ln -sf /usr/bin/aarch64-linux-gnu-gcc-"$ver_number" /usr/bin/aarch64-linux-gnu-gcc

        ln -sf /usr/bin/arm-linux-gnueabi-gcc-"$ver_number" /usr/bin/arm-linux-gnueabi-gcc

        #export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE="/github/workspace/gcc-linaro-7.5.0-2019.12-x86_64_aarch64-elf/bin/aarch64-elf-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    elif [[ $compiler = clang/* ]]; then
        ver="${compiler/clang\/}"
        ver_number="${ver/\/binutils}"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"
        
        if $binutils; then
            additional_packages="binutils binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi"
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            # Most android kernels still need binutils as the assembler, but it will
            # not be used when the Makefile is patched to make use of LLVM_IAS option
            additional_packages="binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi"
            make_opts="CC=clang LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        if ! apt install -y --no-install-recommends clang-"$ver_number" \
            lld-"$ver_number" llvm-"$ver_number" $additional_packages; then
            err "Compiler package not found, refer to the README for details"
            exit 1
        fi

        ln -sf /usr/bin/clang-"$ver_number" /usr/bin/clang
        ln -sf /usr/bin/clang-"$ver_number" /usr/bin/clang++
        ln -sf /usr/bin/ld.lld-"$ver_number" /usr/bin/ld.lld

        for i in /usr/bin/llvm-*-"$ver_number"; do
            ln -sf "$i" "${i/-$ver_number}"
        done

        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    elif [[ $compiler = proton-clang/* ]]; then
        ver="${compiler/proton-clang\/}"
        ver_number="${ver/\/binutils}"
        url="https://github.com/kdrag0n/proton-clang/archive/${ver_number}.tar.gz"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        # Due to different time in container and the host,
        # disable certificate check
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/proton-clang-"${ver_number}".tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        if $binutils; then
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        apt install -y --no-install-recommends libgcc-10-dev || exit 127
        extract_tarball /tmp/proton-clang-"${ver_number}".tar.gz /
        cd /proton-clang-"${ver_number}"* || exit 127
        proton_path="$(pwd)"
        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="$proton_path/bin:${PATH}"
        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    elif [[ $compiler = aosp-clang/* ]]; then
        ver="${compiler/aosp-clang\/}"
        ver_number="${ver/\/binutils}"
        url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/${ver_number}.tar.gz"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-clang.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/master.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-arm64.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/heads/master.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-arm.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/+archive/refs/heads/master.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-host.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        mkdir -p /aosp-clang /aosp-gcc-arm64 /aosp-gcc-arm /aosp-gcc-host
        extract_tarball /tmp/aosp-clang.tar.gz /aosp-clang
        extract_tarball /tmp/aosp-gcc-arm64.tar.gz /aosp-gcc-arm64
        extract_tarball /tmp/aosp-gcc-arm.tar.gz /aosp-gcc-arm
        extract_tarball /tmp/aosp-gcc-host.tar.gz /aosp-gcc-host

        for i in /aosp-gcc-host/bin/x86_64-linux-*; do
            ln -sf "$i" "${i/x86_64-linux-}"
        done

        if $binutils; then
            make_opts="CC=clang"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang LD=ld.lld NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        apt install -y --no-install-recommends libgcc-10-dev || exit 127

        export PATH="/aosp-clang/bin:/aosp-gcc-arm64/bin:/aosp-gcc-arm/bin:/aosp-gcc-host/bin:$PATH"
        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-android-"
        export CROSS_COMPILE_ARM32="arm-linux-androideabi-"
    else
        err "Unsupported toolchain string. refer to the README for more detail"
        exit 100
    fi
else
    err "Currently this action only supports arm64, refer to the README for more detail"
    exit 100
fi

cd "$workdir"/"$kernel_path" || exit 127
start_time="$(date +%s)"
date="$(date +%d%m%Y-%I%M)"
tag="$(git branch | sed 's/*\ //g')"
echo "branch/tag: $tag"
echo "make options:" $arch_opts $make_opts $host_make_opts
msg "Generating defconfig from \`make $defconfig\`..."
make ARCH=arm64 distclean
if ! make ARCH=arm64 O=out2 phenix_defconfig; then
    err "Failed generating .config, make sure it is actually available in arch/${arch}/configs/ and is a valid defconfig file"
    exit 2
fi
msg "Begin building kernel..."

#make O=out $arch_opts $make_opts $host_make_opts -j8 prepare

if ! make ARCH=arm64 O=out2 -j8; then
   err "ccb Failed building kernel, probably the toolchain is not compatible with the kernel, or kernel source problem"
  #  exit 3
fi

set_output elapsed_time "$(echo "$(date +%s)"-"$start_time" | bc)"
msg "Packaging the kernel..."
zip_filename="${name}-${tag}-${date}.zip"
#END
ls
pwd
    
tools/mkbootimg --kernel out2/arch/arm64/boot/Image.gz --base 0x0 --cmdline "loglevel=4 coherent_pool=512K page_tracker=on slub_min_objects=12 unmovable_isolate1=2:192M,3:224M,4:256M printktimer=0xfff0a000,0x534,0x538 androidboot.selinux=enforcing buildvariant=user" --base 0x00478000 --pagesize 2048 --kernel_offset 0x00008000 --ramdisk_offset 0x0ff88000 --second_offset 0x00e88000 --tags_offset 0x07988000 --os_version 9.0.0 --os_patch_level 2020-01 --header_version 0 --output Kernel-4.9.319-enforcing-v1.img

mv  Kernel-4.9.319-enforcing-v1.img Kernel-4.9.319-enforcing-${date}.img

set_output outfile Kernel-4.9.319-enforcing-${date}.img
    msg "No zip template provided, releasing the kernel image instead"
    #set_output outfile out2/arch/arm64/boot/Image.gz
    #set_output outfile fs/sync.c
    #cd outfile out2/arch/arm64/boot
    pwd
    ls
    exit 0

