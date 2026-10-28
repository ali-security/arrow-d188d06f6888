# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

ARG base
FROM ${base} AS vcpkg-base

ARG arch
ARG arch_short
ARG manylinux

ENV MANYLINUX_VERSION=${manylinux}

# CentOS 7 (manylinux2014) mirrors are retired, point yum at vault.centos.org
RUN if [ -f /etc/yum.repos.d/CentOS-Base.repo ]; then \
      sed -i -e 's/^mirrorlist=/#mirrorlist=/' \
             -e 's|^#\?baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' \
             /etc/yum.repos.d/*.repo; \
      if [ "$(uname -m)" = "aarch64" ]; then \
        sed -i -e 's|vault.centos.org/centos/|vault.centos.org/altarch/|' \
               -e 's|vault.centos.org/\$contentdir/|vault.centos.org/altarch/|' \
               -e 's|vault.centos.org/altarch/\$releasever/|vault.centos.org/altarch/7.9.2009/|' \
               -e 's|vault.centos.org/altarch/7/|vault.centos.org/altarch/7.9.2009/|' \
               /etc/yum.repos.d/*.repo; \
      fi; \
    fi
# AlmaLinux 8 (manylinux_2_28) rotated its RPM signing key in 2024
RUN if [ -f /etc/almalinux-release ]; then \
      rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux; \
    fi

# Ensure dnf is installed, especially for the manylinux2014 base
RUN yum install -y dnf

# Install basic dependencies
RUN dnf install -y git flex curl autoconf zip perl-IPC-Cmd wget kernel-headers

# A system Python is required for ninja and vcpkg in this Dockerfile.
# On manylinux2014 base images, system Python is 2.7.5, while
# on manylinux_2_28, no system python is installed.
# We therefore override the PATH with Python 3.8 in /opt/python
# so that we have a consistent Python version across base images.
ENV CPYTHON_VERSION=cp38
ENV PATH=/opt/python/${CPYTHON_VERSION}-${CPYTHON_VERSION}/bin:${PATH}

# Install CMake
# AWS SDK doesn't work with CMake=3.22 due to https://gitlab.kitware.com/cmake/cmake/-/issues/22524
ARG cmake=3.21.4
COPY ci/scripts/install_cmake.sh arrow/ci/scripts/
RUN /arrow/ci/scripts/install_cmake.sh ${arch} linux ${cmake} /usr/local

# Install Ninja
ARG ninja=1.10.2
COPY ci/scripts/install_ninja.sh arrow/ci/scripts/
RUN /arrow/ci/scripts/install_ninja.sh ${ninja} /usr/local

# Install ccache
ARG ccache=4.1
COPY ci/scripts/install_ccache.sh arrow/ci/scripts/
RUN /arrow/ci/scripts/install_ccache.sh ${ccache} /usr/local

# Install vcpkg
ARG vcpkg
COPY ci/vcpkg/*.patch \
     ci/vcpkg/*linux*.cmake \
     arrow/ci/vcpkg/
COPY ci/scripts/install_vcpkg.sh \
     arrow/ci/scripts/
ENV VCPKG_ROOT=/opt/vcpkg
RUN arrow/ci/scripts/install_vcpkg.sh ${VCPKG_ROOT} ${vcpkg}
ENV PATH="${PATH}:${VCPKG_ROOT}"

ARG build_type=release
ENV CMAKE_BUILD_TYPE=${build_type} \
    VCPKG_FORCE_SYSTEM_BINARIES=1 \
    VCPKG_OVERLAY_TRIPLETS=/arrow/ci/vcpkg \
    VCPKG_DEFAULT_TRIPLET=${arch_short}-linux-static-${build_type} \
    VCPKG_FEATURE_FLAGS="manifests"
COPY ci/vcpkg/vcpkg.json arrow/ci/vcpkg/

FROM vcpkg-base
# Restore the vcpkg ports from a pre-built binary cache when one is provided
# (ci/vcpkg-bincache in the build context, see .github/workflows/python.yml)
ARG vcpkg_binary_sources=""
# cannot use the S3 feature here because while aws-sdk-cpp=1.9.160 contains
# ssl related fixies as well as we can patch the vcpkg portfile to support
# arm machines it hits ARROW-15141 where we would need to fall back to 1.8.186
# but we cannot patch those portfiles since vcpkg-tool handles the checkout of
# previous versions => use bundled S3 build
RUN --mount=type=bind,source=ci/vcpkg-bincache,target=/vcpkg-bincache \
    VCPKG_BINARY_SOURCES="${vcpkg_binary_sources}" \
    vcpkg install \
        --clean-after-build \
        --x-install-root=${VCPKG_ROOT}/installed \
        --x-manifest-root=/arrow/ci/vcpkg \
        --x-feature=flight \
        --x-feature=gcs \
        --x-feature=json \
        --x-feature=parquet \
        --x-feature=s3

# Configure Python for applications running in the bash shell of this Dockerfile
ARG python=3.8
ENV PYTHON_VERSION=${python}
RUN PYTHON_ROOT=$(find /opt/python -name cp${PYTHON_VERSION/./}-*) && \
    echo "export PATH=$PYTHON_ROOT/bin:\$PATH" >> /etc/profile.d/python.sh

SHELL ["/bin/bash", "-i", "-c"]
ENTRYPOINT ["/bin/bash", "-i", "-c"]

ARG pip_index_url=https://pypi.org/simple
COPY python/requirements-wheel-build.txt /arrow/python/
# the released manylinux wheels were generated with Cython 3.0.3
RUN PIP_INDEX_URL=${pip_index_url} pip install -r /arrow/python/requirements-wheel-build.txt "cython==3.0.3"
