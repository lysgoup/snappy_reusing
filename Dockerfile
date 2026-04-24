FROM ubuntu:16.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        build-essential git wget curl \
        ninja-build \
        python3 python3-pip \
        lsb-release software-properties-common gnupg \
        zlib1g-dev && \
    apt-get clean

# CMake 3.22.1 binary install
RUN wget https://github.com/Kitware/CMake/releases/download/v3.22.1/cmake-3.22.1-linux-x86_64.tar.gz && \
    tar -zxf cmake-3.22.1-linux-x86_64.tar.gz && \
    cp -r cmake-3.22.1-linux-x86_64/bin /usr/local/ && \
    cp -r cmake-3.22.1-linux-x86_64/share /usr/local/ && \
    rm -rf cmake-3.22.1-linux-x86_64.tar.gz cmake-3.22.1-linux-x86_64

# Clone LLVM 11 source — kept on disk for the libcxx build below
RUN git clone --depth 1 https://github.com/llvm/llvm-project.git \
        --branch release/11.x /llvm-project

# Apply LLVM 11 patches
COPY patches/0001-Add-Custom-sanitizer.patch \
    /llvm-project/
COPY patches/0001-Ignore-STACKMAP-instruction-in-x87-stackifier.patch \
    /llvm-project/
COPY patches/0001-XRay-compiler-rt-x86_64-Fix-CFI-directives-in-assemb.patch \
    /llvm-project/
COPY patches/0001-DFSan-Fix-call-to-__dfsan_mem_transfer_callback.patch \
    /llvm-project/
RUN cd /llvm-project && \
    git apply ./*.patch

# Build LLVM 11 toolchain (clang, compiler-rt/dfsan, lld) and install to /usr/local
RUN cmake -S/llvm-project/llvm -B/build-llvm \
        -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS='clang;compiler-rt;lld' \
        -DLLVM_TARGETS_TO_BUILD='X86' \
        -DLLVM_PARALLEL_LINK_JOBS=2 \
        -DLLVM_ENABLE_ASSERTIONS=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja -C /build-llvm && \
    ninja -C /build-llvm install && \
    rm -rf /build-llvm

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
        pkg-config \
    && \
    mkdir -p ~/.ssh && \
    ssh-keyscan github.com >> ~/.ssh/known_hosts && \
    ssh-keyscan bitbucket.org >> ~/.ssh/known_hosts

# Rust nightly
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        > /tmp/rustup-init.sh && \
    sh /tmp/rustup-init.sh -y --default-toolchain nightly && \
    rm /tmp/rustup-init.sh
ENV PATH="/root/.cargo/bin:${PATH}"

# Corrosion (Rust-CMake integration used by Angora's CMake build)
RUN mkdir -p /corrosion && \
    cd /corrosion && \
    git clone https://github.com/AndrewGaspar/corrosion.git source && \
    . /root/.cargo/env && \
    cmake -Ssource -Bbuild \
        -DCMAKE_BUILD_TYPE=Release \
        -DCORROSION_BUILD_TESTS=OFF && \
    cmake --build build -- -j && \
    cd build && \
    make install && \
    rm -rf /corrosion

# Build Angora fuzzer and install to /usr/local
# (angora-clang / angora-clang++ end up in /usr/local/bin)
RUN mkdir -p /angora
COPY . /angora
WORKDIR /angora
RUN git submodule update --init common/externals/AFL-Snapshot-LKM
RUN CARGO_NET_GIT_FETCH_WITH_CLI=true \
    cmake -S. -Bbuild \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build build -- -j 24 && \
    cmake --install build

# Build plain libcxx
RUN cd /llvm-project && \
    cmake -Sllvm -Bbuild-plain \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/plain-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build build-plain -- cxx cxxabi && \
    cd build-plain && \
    ninja install-cxx install-cxxabi && \
    cd .. && \
    rm -rf build-plain

# Build Angora track libcxx
RUN cd /llvm-project && \
    INSTR_FLAGS="$(FLAGS_MODE=1 USE_DFSAN=1 angora-clang++ --compiler)"; \
    cmake -Sllvm -Bbuild-track \
        -GNinja \
        -DCMAKE_INSTALL_PREFIX=/llvm-project/track-prefix \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DLLVM_ENABLE_PROJECTS='libcxx;libcxxabi' \
        -DLLVM_USE_SANITIZER='Custom' \
        -DLLVM_CUSTOM_SANITIZER_FLAGS="$INSTR_FLAGS" \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_SHARED=OFF && \
    cmake --build build-track -- cxx cxxabi && \
    cd build-track && \
    ninja install-cxx install-cxxabi && \
    cd .. && \
    rm -rf build-track

ENV ANGORA_LIBCXX_FAST_PREFIX=/llvm-project/plain-prefix
ENV ANGORA_LIBCXX_TRACK_PREFIX=/llvm-project/track-prefix

VOLUME ["/data"]
WORKDIR /data
