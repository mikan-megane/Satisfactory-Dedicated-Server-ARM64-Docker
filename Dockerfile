FROM ubuntu:22.04 AS fex-builder
SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    curl python3 sudo expect-dev software-properties-common \
    squashfs-tools squashfuse git python-setuptools pkgconf clang \
    binfmt-support systemd cmake ninja-build \
    libncurses6 libncurses5 libtinfo5 libtinfo6 libncurses-dev \
    libsdl2-dev libepoxy-dev libssl-dev llvm lld \
    qtbase5-dev qtchooser qt5-qmake qtbase5-dev-tools libqt5core5a libqt5gui5 libqt5widgets5 \
    qtdeclarative5-dev qml-module-qtquick2 qml-module-qtquick-controls2 qml-module-qtquick-window2 nasm \
    && rm -rf /var/lib/apt/lists/*

RUN add-apt-repository -y ppa:fex-emu/fex \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --recurse-submodules https://github.com/FEX-Emu/FEX.git
WORKDIR FEX
RUN git checkout 0072b289bbf9f59b89c117158118375397532aad \
    && git submodule update --init --recursive
RUN sed -i 's@USE_LEGACY_BINFMTMISC "Uses legacy method of setting up binfmt_misc" FALSE@USE_LEGACY_BINFMTMISC "Uses legacy method of setting up binfmt_misc" TRUE@' ./CMakeLists.txt
RUN mkdir Build
WORKDIR Build
RUN CC=clang CXX=clang++ cmake -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DUSE_LINKER=lld -DENABLE_LTO=True -DBUILD_TESTS=False -DENABLE_ASSERTIONS=False -G Ninja ..
RUN ninja \
    && DESTDIR=/fex-install ninja install \
    && rm -rf /FEX

FROM ubuntu:22.04
SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y --no-install-recommends \
    curl python3 sudo expect-dev squashfs-tools squashfuse \
    binfmt-support systemd \
    libncurses6 libncurses5 libtinfo5 libtinfo6 \
    libsdl2-2.0-0 libepoxy0 libssl3 \
    libqt5core5a libqt5gui5 libqt5widgets5 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fex-builder /fex-install/ /

RUN useradd -m steam
RUN sudo -u steam bash -c "unbuffer FEXRootFSFetcher -y -x"

USER steam
WORKDIR /home/steam/Steam
RUN curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxf -
WORKDIR /home/steam
ENTRYPOINT ["/bin/bash"]