set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin
cd "$(dirname "$0")"
mkdir build-policy-clean
cd build-policy-clean
../qemu-policy-source/configure --target-list=x86_64-softmmu --without-default-features --enable-system --enable-tools --enable-whpx --enable-tcg --enable-slirp --enable-zstd --disable-docs --disable-werror --disable-download --disable-debug-info --prefix=/ezvm-qemu --bindir=/ezvm-qemu --datadir=/ezvm-qemu/share --libdir=/ezvm-qemu/lib --libexecdir=/ezvm-qemu
ninja -j 6 qemu-system-x86_64.exe qemu-img.exe tests/unit/test-whpx-reset.exe
./tests/unit/test-whpx-reset.exe --tap
