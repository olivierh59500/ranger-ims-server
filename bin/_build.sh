# -*- sh-basic-offset: 2 -*-
##
# Copyright (c) 2005-2015 Apple Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##

. "${wd}/bin/_py.sh";


# Provide a default value: if the variable named by the first argument is
# empty, set it to the default in the second argument.
conditional_set () {
  local var="$1"; shift;
  local default="$1"; shift;
  if [ -z "$(eval echo "\${${var}:-}")" ]; then
    eval "${var}=\${default:-}";
  fi;
}


c_macro () {
  local sys_header="$1"; shift;
  local version_macro="$1"; shift;

  local value="$(printf "#include <${sys_header}>\n${version_macro}\n" | cc -x c -E - 2>/dev/null | tail -1)";

  if [ "${value}" = "${version_macro}" ]; then
    # Macro was not replaced
    return 1;
  fi;

  echo "${value}";
}


# Checks for presence of a C header, optionally with a version comparison.
# With only a header file name, try to include it, returning nonzero if absent.
# With 3 params, also attempt a version check, returning nonzero if too old.
# Param 2 is a minimum acceptable version number
# Param 3 is a #define from the source that holds the installed version number
# Examples:
#   Assert that ldap.h is present
#     find_header "ldap.h"
#   Assert that ldap.h is present with a version >= 20344
#     find_header "ldap.h" 20344 "LDAP_VENDOR_VERSION"
find_header () {
  local sys_header="$1"; shift;
  if [ $# -ge 1 ]; then
      local   min_version="$1"; shift;
      local version_macro="$1"; shift;
  fi;

  # No min_version given:
  # Check for presence of a header. We use the "-c" cc option because we don't
  # need to emit a file; cc exits nonzero if it can't find the header
  if [ -z "${min_version:-}" ]; then
    echo "#include <${sys_header}>" | cc -x c -c - -o /dev/null 2> /dev/null;
    return "$?";
  fi;

  # Check for presence of a header of specified version
  local found_version="$(c_macro "${sys_header}" "${version_macro}")";

  if [ -n "${found_version}" ] && cmp_version "${min_version}" "${found_version}"; then
    return 0;
  else
    return 1;
  fi;
};


# Initialize all the global state required to use this library.
init_build () {
  local lwd="$(pwd)";
  cd "${wd}";

  init_py;

  # These variables are defaults for things which might be configured by
  # environment; only set them if they're un-set.
  conditional_set wd "$(pwd)";
  conditional_set do_get "true";
  conditional_set do_setup "true";
  conditional_set force_setup "false";
  conditional_set requirements "${wd}/requirements-dev.txt"

      dev_home="${wd}/.develop";
     dev_roots="${dev_home}/roots";
  dep_packages="${dev_home}/pkg";
   dep_sources="${dev_home}/src";

  py_virtualenv="${dev_home}/virtualenv";
      py_bindir="${py_virtualenv}/bin";

  python="${bootstrap_python}";
  export PYTHON="${python}";

  if [ -z "${TWEXT_PKG_CACHE-}" ]; then
    dep_packages="${dev_home}/pkg";
  else
    dep_packages="${TWEXT_PKG_CACHE}";
  fi;

  project="$(setup_print name)" || project="<unknown>";

  # Find some hashing commands
  # sha1() = sha1 hash, if available
  # md5()  = md5 hash, if available
  # hash() = default hash function
  # $hash  = name of the type of hash used by hash()

  hash="";

  if find_cmd openssl > /dev/null; then
    if [ -z "${hash}" ]; then hash="md5"; fi;
    # remove "(stdin)= " from the front which openssl emits on some platforms
    md5 () { "$(find_cmd openssl)" dgst -md5 "$@" | sed 's/^.* //'; }
  elif find_cmd md5 > /dev/null; then
    if [ -z "${hash}" ]; then hash="md5"; fi;
    md5 () { "$(find_cmd md5)" "$@"; }
  elif find_cmd md5sum > /dev/null; then
    if [ -z "${hash}" ]; then hash="md5"; fi;
    md5 () { "$(find_cmd md5sum)" "$@"; }
  fi;

  if find_cmd sha1sum > /dev/null; then
    if [ -z "${hash}" ]; then hash="sha1sum"; fi;
    sha1 () { "$(find_cmd sha1sum)" "$@"; }
  fi;
  if find_cmd shasum > /dev/null; then
    if [ -z "${hash}" ]; then hash="sha1"; fi;
    sha1 () { "$(find_cmd shasum)" "$@"; }
  fi;

  if [ "${hash}" = "sha1" ]; then
    hash () { sha1 "$@"; }
  elif [ "${hash}" = "md5" ]; then
    hash () { md5 "$@"; }
  elif find_cmd cksum > /dev/null; then
    hash="hash";
    hash () { cksum "$@" | cut -f 1 -d " "; }
  elif find_cmd sum > /dev/null; then
    hash="hash";
    hash () { sum "$@" | cut -f 1 -d " "; }
  else
    hash () { echo "INTERNAL ERROR: No hash function."; exit 1; }
  fi;

  cd "${lwd}";
}


setup_print () {
  local what="$1"; shift;

  PYTHONPATH="${wd}:${PYTHONPATH:-}" "${bootstrap_python}" - 2>/dev/null << EOF
from __future__ import print_function
import setup
print(setup.${what})
EOF
}


# If do_get is turned on, get an archive file containing a dependency via HTTP.
www_get () {
  if ! "${do_get}"; then return 0; fi;

  local  md5="";
  local sha1="";

  local OPTIND=1;
  while getopts "m:s:" option; do
    case "${option}" in
      'm')  md5="${OPTARG}"; ;;
      's') sha1="${OPTARG}"; ;;
    esac;
  done;
  shift $((${OPTIND} - 1));

  local name="$1"; shift;
  local path="$1"; shift;
  local  url="$1"; shift;

  if "${force_setup}"; then
    rm -rf "${path}";
  fi;
  if [ ! -d "${path}" ]; then
    local ext="$(echo "${url}" | sed 's|^.*\.\([^.]*\)$|\1|')";
    local decompress="";
    local unpack="";

    untar () { tar -xvf -; }
    unzipstream () { local tmp="$(mktemp -t ccsXXXXX)"; cat > "${tmp}"; unzip "${tmp}"; rm "${tmp}"; }
    case "${ext}" in
      gz|tgz) decompress="gzip -d -c"; unpack="untar"; ;;
      bz2)    decompress="bzip2 -d -c"; unpack="untar"; ;;
      tar)    decompress="untar"; unpack="untar"; ;;
      zip)    decompress="cat"; unpack="unzipstream"; ;;
      *)
        echo "Error in www_get of URL ${url}: Unknown extension ${ext}";
        exit 1;
        ;;
    esac;

    echo "";

    if [ -n "${dep_packages}" ] && [ -n "${hash}" ]; then
      mkdir -p "${dep_packages}";

      local cache_basename="$(echo ${name} | tr '[ ]' '_')-$(echo "${url}" | hash)-$(basename "${url}")";
      local cache_file="${dep_packages}/${cache_basename}";

      check_hash () {
        local file="$1"; shift;

        local sum="$(md5 "${file}" | perl -pe 's|^.*([0-9a-f]{32}).*$|\1|')";
        if [ -n "${md5}" ]; then
          echo "Checking MD5 sum for ${name}...";
          if [ "${md5}" != "${sum}" ]; then
            echo "ERROR: MD5 sum for downloaded file is wrong: ${sum} != ${md5}";
            return 1;
          fi;
        else
          echo "MD5 sum for ${name} is ${sum}";
        fi;

        local sum="$(sha1 "${file}" | perl -pe 's|^.*([0-9a-f]{40}).*$|\1|')";
        if [ -n "${sha1}" ]; then
          echo "Checking SHA1 sum for ${name}...";
          if [ "${sha1}" != "${sum}" ]; then
            echo "ERROR: SHA1 sum for downloaded file is wrong: ${sum} != ${sha1}";
            return 1;
          fi;
        else
          echo "SHA1 sum for ${name} is ${sum}";
        fi;
      }

      if [ ! -f "${cache_file}" ]; then
        echo "No cache file: ${cache_file}";

        echo "Downloading ${name}...";

        #
        # That didn't work. Try getting a copy from the upstream source.
        #
        local tmp="$(mktemp -t ccsXXXXX)";
        curl -L "${url}" -o "${tmp}";
        echo "";

        if [ ! -s "${tmp}" ] || grep '<title>404 Not Found</title>' "${tmp}" > /dev/null; then
          rm -f "${tmp}";
          echo "${name} is not available from upstream source: ${url}";
          exit 1;
        elif ! check_hash "${tmp}"; then
          rm -f "${tmp}";
          echo "${name} from upstream source is invalid: ${url}";
          exit 1;
        fi;

        #
        # OK, we should be good
        #
        mv "${tmp}" "${cache_file}";
      else
        #
        # We have the file cached, just verify hash
        #
        if ! check_hash "${cache_file}"; then
          exit 1;
        fi;
      fi;

      echo "Unpacking ${name} from cache...";
      get () { cat "${cache_file}"; }
    else
      echo "Downloading ${name}...";
      get () { curl -L "${url}"; }
    fi;

    rm -rf "${path}";
    local lwd="$(pwd)";
    cd "$(dirname "${path}")";
    get | ${decompress} | ${unpack};
    cd "${lwd}";
  fi;
}


# Run 'make' with the given command line, prepending a -j option appropriate to
# the number of CPUs on the current machine, if that can be determined.
jmake () {
  local ncpu="";

  case "$(uname -s)" in
    Darwin|Linux)
      ncpu="$(getconf _NPROCESSORS_ONLN)";
      ;;
    FreeBSD)
      ncpu="$(sysctl hw.ncpu)";
      ncpu="${ncpu##hw.ncpu: }";
      ;;
  esac;

  if [ -n "${ncpu:-}" ] && [[ "${ncpu}" =~ ^[0-9]+$ ]]; then
    make -j "${ncpu}" "$@";
  else
    make "$@";
  fi;
}

# Declare a dependency on a C project built with autotools.
# Support for custom configure, prebuild, build, and install commands
# prebuild_cmd, build_cmd, and install_cmd phases may be skipped by
# passing the corresponding option with the empty string as the value.
# By default, do: ./configure --prefix ... ; jmake ; make install
c_dependency () {
  local f_hash="";
  local configure="configure";
  local prebuild_cmd="";
  local build_cmd="jmake";
  local install_cmd="make install";

  local OPTIND=1;
  while getopts "m:s:c:p:b:" option; do
    case "${option}" in
      'm') f_hash="-m ${OPTARG}"; ;;
      's') f_hash="-s ${OPTARG}"; ;;
      'c') configure="${OPTARG}"; ;;
      'p') prebuild_cmd="${OPTARG}"; ;;
      'b') build_cmd="${OPTARG}"; ;;
    esac;
  done;
  shift $((${OPTIND} - 1));

  local name="$1"; shift;
  local path="$1"; shift;
  local  uri="$1"; shift;

  # Extra arguments are processed below, as arguments to configure.

  mkdir -p "${dep_sources}";

  local srcdir="${dep_sources}/${path}";
  local dstroot="${dev_roots}/${name}";

  www_get ${f_hash} "${name}" "${srcdir}" "${uri}";

  export              PATH="${dstroot}/bin:${PATH}";
  export    C_INCLUDE_PATH="${dstroot}/include:${C_INCLUDE_PATH:-}";
  export   LD_LIBRARY_PATH="${dstroot}/lib:${dstroot}/lib64:${LD_LIBRARY_PATH:-}";
  export          CPPFLAGS="-I${dstroot}/include ${CPPFLAGS:-} ";
  export           LDFLAGS="-L${dstroot}/lib -L${dstroot}/lib64 ${LDFLAGS:-} ";
  export DYLD_LIBRARY_PATH="${dstroot}/lib:${dstroot}/lib64:${DYLD_LIBRARY_PATH:-}";
  export   PKG_CONFIG_PATH="${dstroot}/lib/pkgconfig:${PKG_CONFIG_PATH:-}";

  if "${do_setup}"; then
    if "${force_setup}"; then
        rm -rf "${dstroot}";
    fi;
    if [ ! -d "${dstroot}" ]; then
      echo "Building ${name}...";
      local lwd="$(pwd)";
      cd "${srcdir}";
      "./${configure}" --prefix="${dstroot}" "$@";
      if [ ! -z "${prebuild_cmd}" ]; then
        eval ${prebuild_cmd};
      fi;
      eval ${build_cmd};
      eval ${install_cmd};
      cd "${lwd}";
    else
      echo "Using built ${name}.";
      echo "";
    fi;
  fi;
}


ruler () {
  if "${do_setup}"; then
    echo "____________________________________________________________";
    echo "";

    if [ $# -gt 0 ]; then
      echo "$@";
    fi;
  fi;
}


using_system () {
  if "${do_setup}"; then
    local name="$1"; shift;
    echo "Using system version of ${name}.";
    echo "";
  fi;
}


#
# Build C dependencies
#
c_dependencies () {
  local    c_glue_root="${dev_roots}/c_glue";
  local c_glue_include="${c_glue_root}/include";

  export C_INCLUDE_PATH="${c_glue_include}:${C_INCLUDE_PATH:-}";

  ####
}


#
# Build Python dependencies
#
py_dependencies () {
  python="${py_bindir}/python";
  py_ve_tools="${dev_home}/ve_tools";

  export PATH="${py_virtualenv}/bin:${PATH}";
  export PYTHON="${python}";

  ve_pythonpath="${py_ve_tools}/lib";

  # Work around a change in Xcode tools that breaks Python modules in OS X
  # 10.9.2 and prior due to a hard error if the -mno-fused-madd is used, as
  # it was in the system Python, and is therefore passed along by disutils.
  if [ "$(uname -s)" = "Darwin" ]; then
    if "${bootstrap_python}" -c 'import distutils.sysconfig; print distutils.sysconfig.get_config_var("CFLAGS")' \
       | grep -e -mno-fused-madd > /dev/null; then
      export ARCHFLAGS="-Wno-error=unused-command-line-argument-hard-error-in-future";
    fi;
  fi;

  if ! "${do_setup}"; then return 0; fi;

  # Set up virtual environment

  if "${force_setup}"; then
    # Nuke the virtual environment first
    rm -rf "${py_virtualenv}";
  fi;

  if [ ! -d "${py_virtualenv}" ]; then
    bootstrap_virtualenv;
    PYTHONPATH="${ve_pythonpath}"          \
      "${bootstrap_python}" -m virtualenv  \
        --system-site-packages             \
        "${py_virtualenv}";
  fi;

  local lwd="$(pwd)";
  cd "${wd}";

  # Make sure setup got called enough to write the version file.
  PYTHONPATH="${ve_pythonpath}" PYTHONPATH="${PYTHONPATH}" "${python}" "${wd}/setup.py" check > /dev/null;

  if [ -d "${dev_home}/pip_downloads" ]; then
    pip_install="pip_install_from_cache";
  else
    pip_install="pip_download_and_install";
  fi;

  ruler "Preparing Python requirements";
  echo "";
  "${pip_install}" --requirement="${requirements}";

  for option in $("${bootstrap_python}" -c 'import setup; print "\n".join(setup.extras_requirements.keys())'); do
    ruler "Preparing Python requirements for optional feature: ${option}";
    echo "";
    if ! "${pip_install}" --editable="${wd}[${option}]"; then
      echo "Feature ${option} is optional; continuing.";
    fi;
  done;

  cd "${lwd}";

  echo "";
}


bootstrap_virtualenv () {
  mkdir -p "${py_ve_tools}";
  mkdir -p "${py_ve_tools}/lib";
  mkdir -p "${py_ve_tools}/junk";

  for pkg in             \
      setuptools-20.3.1  \
      pip-8.1.1          \
      virtualenv-15.0.1  \
  ; do
      local    name="${pkg%-*}";
      local version="${pkg#*-}";
      local  first="$(echo "${name}" | sed 's|^\(.\).*$|\1|')";
      local    url="https://pypi.python.org/packages/source/${first}/${name}/${pkg}.tar.gz";

      ruler "Downloading ${pkg}";

      local tmp="$(mktemp -d -t ccsXXXXX)";

      curl -L "${url}" | tar -C "${tmp}" -xvzf -;

      local lwd="$(pwd)";
      cd "${tmp}/$(basename "${pkg}")";
      PYTHONPATH="${ve_pythonpath}"                  \
        "${bootstrap_python}" setup.py install       \
            --install-base="${py_ve_tools}"          \
            --install-lib="${py_ve_tools}/lib"       \
            --install-headers="${py_ve_tools}/junk"  \
            --install-scripts="${py_ve_tools}/junk"  \
            --install-data="${py_ve_tools}/junk"     \
            ;                                        \
      cd "${lwd}";

      rm -rf "${tmp}";
  done;
}


pip_download () {
  mkdir -p "${dev_home}/pip_downloads";

  "${python}" -m pip install               \
    --disable-pip-version-check            \
    --download="${dev_home}/pip_downloads" \
    --pre --allow-all-external             \
    --no-cache-dir                         \
    --log-file="${dev_home}/pip.log"       \
    "$@";
}


pip_install_from_cache () {
  "${python}" -m pip install                 \
    --upgrade                                \
    --disable-pip-version-check              \
    --pre --allow-all-external               \
    --no-index                               \
    --no-cache-dir                           \
    --find-links="${dev_home}/pip_downloads" \
    --log-file="${dev_home}/pip.log"         \
    "$@";
}


pip_download_and_install () {
  "${python}" -m pip install                 \
    --upgrade                                \
    --disable-pip-version-check              \
    --pre --allow-all-external               \
    --no-cache-dir                           \
    --log-file="${dev_home}/pip.log"         \
    "$@";
}


#
# Set up for development
#
develop () {
  init_build;
  c_dependencies;
  py_dependencies;
}


develop_clean () {
  init_build;

  # Clean
  rm -rf "${dev_roots}";
  rm -rf "${py_virtualenv}";
}


develop_distclean () {
  init_build;

  # Clean
  rm -rf "${dev_home}";
}
