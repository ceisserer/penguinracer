FROM mcr.microsoft.com/devcontainers/javascript-node:1-20-bullseye

# Install basic development utilities
RUN apt-get update && apt-get install -y git openjdk-21-jdk libnss3-dev libnspr4-dev python3-dev python3-setuptools autoconf fontconfig libfontconfig-dev gperf libcups2-dev build-essential zip ccache junit4 libkrb5-dev nasm graphviz python3 python3-dev python3-setuptools qtbase5-dev libkf5coreaddons-dev libkf5i18n-dev libkf5config-dev libkf5windowsystem-dev libkf5kio-dev libqt5x11extras5-dev autoconf libcups2-dev libfontconfig1-dev gperf openjdk-17-jdk doxygen libxslt1-dev xsltproc libxml2-utils libxrandr-dev libx11-dev bison flex libgtk-3-dev libgstreamer-plugins-base1.0-dev libgstreamer1.0-dev ant ant-optional libnss3-dev libavahi-client-dev libxt-dev meson libarchive-zip-perl

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Ensure node user can run sudo without password if needed
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/nopasswd
