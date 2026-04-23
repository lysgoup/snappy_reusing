FROM ubuntu:focal AS libunwind-builder

RUN apt-get update && \
    apt-get install -y \
        git \
        build-essential \
        autoconf \
        libtool

RUN git clone https://github.com/libunwind/libunwind.git /libunwind && \
    cd /libunwind && \
    git checkout v1.6.2 && \
    autoreconf --install && \
    ./configure --enable-static --enable-shared --enable-setjmp=no && \
    make -j && \
    make install DESTDIR=/tmp/libunwind_prefix && \
    mkdir /libunwind_build && \
    cd /libunwind_build && \
    tar --directory=/tmp/libunwind_prefix -cf libunwind.tar.gz usr && \
    rm -rf /libunwind /tmp/libunwind_prefix


FROM ubuntu:focal AS llvm-builder-deps

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        git \
        python3 \
        wget \
        build-essential \
        ninja-build \
        cmake

RUN mkdir -p /llvm-project && \
    cd /llvm-project && \
    git clone --depth 1 https://github.com/llvm/llvm-project.git \
        --branch release/11.x \
        source


FROM llvm-builder-deps AS llvm-builder

RUN cd /llvm-project && \
    cmake -Ssource/llvm -Bbuild-assert \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS='clang;compiler-rt;lld' \
        -DLLVM_TARGETS_TO_BUILD='X86' \
        -DLLVM_PARALLEL_LINK_JOBS=2 \
        -DLLVM_ENABLE_ASSERTIONS=ON && \
    cmake --build build-assert && \
    cd build-assert && \
    cpack -G "STGZ" && \
    cd /llvm-project && \
    mv build-assert/LLVM-11.1.0-Linux.sh . && \
    rm -rf build-assert


FROM llvm-builder-deps AS fuzzer-builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        libc++-dev \
        libc++abi-dev \
        curl \
        lsb-release \
        ca-certificates \
        gnupg \
        apt-utils \
        zlib1g-dev \
        libgcrypt-dev \
        libmount-dev \
        pkg-config

# Install Rust (nightly)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        > /tmp/rustup-init.sh && \
    sh /tmp/rustup-init.sh -y --default-toolchain nightly && \
    rm /tmp/rustup-init.sh

ENV PATH="/root/.cargo/bin:$PATH"

# Install Corrosion v0.1.0
RUN git clone https://github.com/AndrewGaspar/corrosion.git /tmp/corrosion && \
    cd /tmp/corrosion && git checkout v0.1.0 && cd / && \
    cmake -S/tmp/corrosion -B/tmp/corrosion-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCORROSION_BUILD_TESTS=OFF && \
    cmake --build /tmp/corrosion-build -- -j && \
    cmake --install /tmp/corrosion-build && \
    rm -rf /tmp/corrosion /tmp/corrosion-build

# Generate DFSan ABI lists for external libraries
RUN mkdir /extra_abilists && \
    nm --dynamic /usr/lib/x86_64-linux-gnu/libz.so \
        | awk '{ if ($2 == "T") print "fun:" $3 "=uninstrumented" }' \
        > /extra_abilists/libz_abilist.txt && \
    nm --dynamic /usr/lib/x86_64-linux-gnu/libgcrypt.so \
        | awk '{ if ($2 == "T") print "fun:" $3 "=uninstrumented" }' \
        > /extra_abilists/libgcrypt_abilist.txt && \
    nm --dynamic /usr/lib/x86_64-linux-gnu/libmount.so \
        | awk '{ if ($2 == "T") print "fun:" $3 "=uninstrumented" }' \
        > /extra_abilists/libmount_abilist.txt

COPY --from=libunwind-builder /libunwind_build/libunwind.tar.gz /tmp/
RUN cd / && tar xf /tmp/libunwind.tar.gz && ldconfig

COPY --from=llvm-builder /llvm-project/LLVM-11.1.0-Linux.sh /llvm-project/
RUN /llvm-project/LLVM-11.1.0-Linux.sh --skip-license --prefix=/usr/local

# Build fuzzer from local source
COPY . /angora/source
RUN cmake -S/angora/source -B/angora/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ && \
    cmake --build /angora/build -- -j && \
    cmake --install /angora/build && \
    rm -rf /angora/build

# Build plain libcxx
RUN cmake -S/llvm-project/source/llvm -B/llvm-project/build-plain \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/plain-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build /llvm-project/build-plain -- cxx cxxabi && \
    cmake --install /llvm-project/build-plain --component cxx && \
    cmake --install /llvm-project/build-plain --component cxxabi && \
    rm -rf /llvm-project/build-plain

RUN angora-clang -c \
        /llvm-project/source/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
        -o /llvm-project/StandaloneFuzzTargetMainAngoraFast.o && \
    ar rc /llvm-project/libStandaloneFuzzTargetAngoraFast.a \
        /llvm-project/StandaloneFuzzTargetMainAngoraFast.o && \
    rm /llvm-project/StandaloneFuzzTargetMainAngoraFast.o

# Build Angora track libcxx (original approach: angora-clang as compiler + USE_DFSAN=1)
RUN cmake -S/llvm-project/source/llvm -B/llvm-project/build-track \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/track-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=angora-clang \
        -DCMAKE_CXX_COMPILER=angora-clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    USE_DFSAN=1 cmake --build /llvm-project/build-track -- cxx cxxabi && \
    cmake --install /llvm-project/build-track --component cxx && \
    cmake --install /llvm-project/build-track --component cxxabi && \
    rm -rf /llvm-project/build-track

RUN USE_TRACK=1 angora-clang -c \
        /llvm-project/source/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
        -o /llvm-project/StandaloneFuzzTargetMainAngoraTrack.o && \
    ar rc /llvm-project/libStandaloneFuzzTargetAngoraTrack.a \
        /llvm-project/StandaloneFuzzTargetMainAngoraTrack.o && \
    rm /llvm-project/StandaloneFuzzTargetMainAngoraTrack.o

ENV ANGORA_LIBCXX_FAST_PREFIX=/llvm-project/plain-prefix
ENV ANGORA_LIBCXX_TRACK_PREFIX=/llvm-project/track-prefix

VOLUME ["/data"]
WORKDIR /data
