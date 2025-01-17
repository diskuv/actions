#!/bin/sh
set -euf

setup_WORKSPACE_VARNAME=$1
shift
setup_WORKSPACE=$1
shift

if [ -x /usr/bin/cygpath ]; then
    setup_WORKSPACE=$(/usr/bin/cygpath -au "$setup_WORKSPACE")
fi

# ------------------ Variables and functions ------------------------

# shellcheck source=./common-values.sh
. .ci/sd4/common-values.sh

if [ "${VERBOSE:-}" = "true" ]; then
    do_tar_rf() {
        tar rvf "$@"
    }
else
    do_tar_rf() {
        tar rf "$@"
    }
fi

# Make the standard input work as an OCaml string.
# This currently only escapes backslashes and double quotes.
escape_arg_as_ocaml_string() {
    escape_arg_as_ocaml_string_ARG=$1
    shift
    printf "%s" "$escape_arg_as_ocaml_string_ARG" | sed 's#\\#\\\\#g; s#"#\\"#g;'
}

# Fixup opam_root on Windows to be mixed case. Set original_* and unix_* as well.
fixup_opam_root

# Set TEMP variable for Windows
export_temp_for_windows

# Load VS studio environment
if [ -e .ci/sd4/vsenv.sh ]; then
    # shellcheck disable=SC1091
    . .ci/sd4/vsenv.sh
fi

# -------------------------------------------------------------------

docker_fqin_preusername= # fully qualified image name (hostname[:port]/username/reponame[:tag]), the parts before the username (hostname[:port]/)
if [ -n "${docker_registry:-}" ]; then
    docker_fqin_preusername="$docker_registry/"
fi

# Extend dockcross. https://github.com/dockcross/dockcross#how-to-extend-dockcross-images
dockcross_image_id=
dockcross_cli_image_args=
if [ "${in_docker:-}" = "true" ] && [ -n "${dockcross_image:-}" ]; then
    echo "Doing docker build"
    section_begin docker-build "Summary: docker build --quiet --tag ${docker_fqin_preusername}dkml-workflows/dockcross"

    install -d .ci/sd4/docker-image
    #   Since GitLab CI limits environment variables to 255 characters, if you need to exceed that there are five (5)
    #   variations of `dockcross_packages_apt` and `dockcross_packages_yum` to spread the packages over.
    printf "FROM %s\nENV DEFAULT_DOCKCROSS_IMAGE %sdkml-workflows/dockcross:latest\nRUN if command -v apt-get; then apt-get install -y rsync %s %s %s %s %s && rm -rf /var/lib/apt/lists/*; fi\nRUN if command -v yum; then yum install -y rsync %s %s %s %s %s && yum clean all && rm -rf /var/cache/yum; fi" \
        "${dockcross_image:-}" "${docker_fqin_preusername}" \
        "${dockcross_packages_apt:-}" "${dockcross_packages_apt2:-}" "${dockcross_packages_apt3:-}" "${dockcross_packages_apt4:-}" "${dockcross_packages_apt5:-}" \
        "${dockcross_packages_yum:-}" "${dockcross_packages_yum2:-}" "${dockcross_packages_yum3:-}" "${dockcross_packages_yum4:-}" "${dockcross_packages_yum5:-}" \
        >.ci/sd4/docker-image/Dockerfile
    docker build --quiet --tag "${docker_fqin_preusername}dkml-workflows/dockcross:latest" .ci/sd4/docker-image

    # Save image id to re-use for all remaining dockcross invocations
    docker images --format "{{.ID}} {{.CreatedAt}}" | sort -rk 2 | awk 'NR==1{print $1}' | tee .ci/sd4/docker-image-id
    dockcross_image_id=$(cat .ci/sd4/docker-image-id)
    dockcross_cli_image_args="--image $dockcross_image_id"

    section_end docker-build
fi

# -------------------------------------------------------------------

section_begin setup-info "Summary: setup-dkml"

SKIP_OPAM_MODIFICATIONS=${SKIP_OPAM_MODIFICATIONS:-false} # default is false

# shellcheck disable=SC2154
echo "
=============
setup-dkml.sh
=============
.
---------
Arguments
---------
WORKSPACE_VARNAME=$setup_WORKSPACE_VARNAME
WORKSPACE=$setup_WORKSPACE
.
------
Inputs
------
DISKUV_OPAM_REPOSITORY=${DISKUV_OPAM_REPOSITORY:-}
OCAML_OPAM_REPOSITORY=${OCAML_OPAM_REPOSITORY:-}
DKML_COMPILER=${DKML_COMPILER:-}
OCAML_COMPILER=${OCAML_COMPILER:-}
CONF_DKML_CROSS_TOOLCHAIN=${CONF_DKML_CROSS_TOOLCHAIN:-}
SKIP_OPAM_MODIFICATIONS=${SKIP_OPAM_MODIFICATIONS:-}
SECONDARY_SWITCH=${SECONDARY_SWITCH:-}
PRIMARY_SWITCH_SKIP_INSTALL=${PRIMARY_SWITCH_SKIP_INSTALL:-}
MANYLINUX=${MANYLINUX:-}
DKML_HOME=${DKML_HOME:-}
VERBOSE=${VERBOSE:-}
.
----------------------
DkML Release Constants
----------------------
DKML_VERSION=$DKML_VERSION
DEFAULT_DISKUV_OPAM_REPOSITORY_TAG=$DEFAULT_DISKUV_OPAM_REPOSITORY_TAG
DEFAULT_OCAML_OPAM_REPOSITORY_TAG=$DEFAULT_OCAML_OPAM_REPOSITORY_TAG
DEFAULT_DKML_COMPILER=$DEFAULT_DKML_COMPILER
BOOTSTRAP_OPAM_VERSION=$BOOTSTRAP_OPAM_VERSION
.
-------
Context
-------
PC_PROJECT_DIR=${PC_PROJECT_DIR:-}
GIT_LOCATION=${GIT_LOCATION:-}
.
------
Matrix
------
dkml_host_abi=$dkml_host_abi
abi_pattern=$abi_pattern
opam_root=${opam_root}
opam_root_cacheable=${opam_root_cacheable}
original_opam_root=${original_opam_root}
original_opam_root_cacheable=${original_opam_root_cacheable}
unix_opam_root=${unix_opam_root}
unix_opam_root_cacheable=${unix_opam_root_cacheable}
docker_registry=${docker_registry:-}
dockcross_image=${dockcross_image:-}
dockcross_run_extra_args=${dockcross_run_extra_args:-}
docker_runner=${docker_runner:-}
in_docker=${in_docker:-}
ocaml_options=${ocaml_options:-}
.
----
Pins
----
"
set | grep ^PIN_
echo ".
"
case "$dkml_host_abi" in
windows_*)
    # shellcheck disable=SC2153
    echo "
-------------
Visual Studio
-------------
VS_DIR=$VS_DIR
VS_VCVARSVER=$VS_VCVARSVER
VS_WINSDKVER=$VS_WINSDKVER
VS_MSVSPREFERENCE=$VS_MSVSPREFERENCE
VS_CMAKEGENERATOR=$VS_CMAKEGENERATOR
.
"
    ;;
esac
section_end setup-info

do_bootstrap() {
    install -d .ci/sd4/bs
    cd .ci/sd4/bs

    if [ ! -e stamp ] || [ "$(cat stamp)" != "${BOOTSTRAP_OPAM_VERSION}${dkml_host_abi}" ]; then
        echo 'Bootstrap opam from dkml-component-opam release ...'
        if command -v curl > /dev/null 2> /dev/null; then
            curl -s -L -o opam.tar.gz "https://github.com/diskuv/dkml-component-opam/releases/download/${BOOTSTRAP_OPAM_VERSION}/dkml-component-staging-opam.tar.gz"
        else
            wget -q -O opam.tar.gz "https://github.com/diskuv/dkml-component-opam/releases/download/${BOOTSTRAP_OPAM_VERSION}/dkml-component-staging-opam.tar.gz"
        fi
        tar tfz opam.tar.gz
        tar xfz opam.tar.gz "./staging-files/${dkml_host_abi}/"
        rm -rf bin/
        mv "staging-files/${dkml_host_abi}/bin" .
        rm -rf "${abi_pattern}"
        printf "%s" "${BOOTSTRAP_OPAM_VERSION}${dkml_host_abi}" >stamp
    fi

    rm -f opam.tar.gz
    cd ../../..
}
section_begin bootstrap-opam 'Bootstrap opam'
do_bootstrap
section_end bootstrap-opam

# Start environment distribution tarball
#   We use .tar rather than .tar.gz/.tar.bz2 because we can repeatedly add to an uncompressed .tar. But we need to
#   start with an empty tarball since some tar programs will only add ('tar rf xyz.tar') to an existing .tar.
install -d .ci/sd4/dist
tar cf .ci/sd4/dist/run-with-env.tar -T /dev/null

do_get_dockcross() {
    if [ "${in_docker:-}" = "true" ] && [ -n "${dockcross_image:-}" ]; then
        # The dockcross script is super-slow
        section_begin get-dockcross 'Get dockcross binary (ManyLinux)'
        install -d .ci/sd4
        #   shellcheck disable=SC2086
        docker run ${dockcross_run_extra_args:-} --rm "${dockcross_image_id}" >.ci/sd4/dockcross.gen

        # PROBLEM 1
        # ---------
        # Super-annoying stderr output from dockcross at line:
        #    tty -s && [ -z "$MSYS" ] && TTY_ARGS=-ti
        # When there is no tty, get:
        #   tty: ignoring all arguments
        #   not a tty
        # So replace 'tty -s &&' with 'false &&'
        sed 's/tty -s &&/false \&\&/' .ci/sd4/dockcross.gen >.ci/sd4/dockcross-real
        rm -f .ci/sd4/dockcross.gen
        chmod +x .ci/sd4/dockcross-real

        # PROBLEM 2
        # ---------
        # By default dockcross for ManyLinux will chown -R all python packages; super-slow (~10 seconds)!
        # Confer: https://github.com/dockcross/dockcross/blob/master/manylinux-common/pre_exec.sh
        # That kills speed for any repetitive dockcross invocation.
        #
        # BUT it is unnecessary to chown -R when the current user is root, because inside the Docker container
        # the files are already root!
        #
        # The chown -R (within pre_exec.sh) is not run when the user ids are not passed in.
        # Confer: https://github.com/dockcross/dockcross/blob/96d87416f639af0204bdd42553e4b99315ca8476/imagefiles/entrypoint.sh#L21-L53
        #
        # So explicitly call the entrypoint if root!
        if echo "${dockcross_run_extra_args:-}" | grep -q linux/386; then
            # https://github.com/dockcross/dockcross/blob/master/linux-x86/linux32-entrypoint.sh
            # But only when `--platform linux/386` because the container image may be overridden.
            dockcross_entrypoint=/dockcross/linux32-entrypoint.sh
        else
            dockcross_entrypoint=/dockcross/entrypoint.sh
        fi
        cat > .ci/sd4/dockcross <<EOF
#!/bin/bash
set -euf
BUILDER_UID="\$( id -u )"
BUILDER_GID="\$( id -g )"
if [ "\$BUILDER_UID" = 0 ] && [ "\$BUILDER_GID" = 0 ]; then
    # ---------- Start of dockcross script snippet -------
    # Verbatim from
    # https://github.com/dockcross/dockcross/blob/96d87416f639af0204bdd42553e4b99315ca8476/imagefiles/dockcross#L175-L204
    # except 1) disabling of USER_IDS

    # Bash on Ubuntu on Windows
    UBUNTU_ON_WINDOWS=\$([ -e /proc/version ] && grep -l Microsoft /proc/version || echo "")
    # MSYS, Git Bash, etc.
    MSYS=\$([ -e /proc/version ] && grep -l MINGW /proc/version || echo "")
    # CYGWIN
    CYGWIN=\$([ -e /proc/version ] && grep -l CYGWIN /proc/version || echo "")

    #if [ -z "\$UBUNTU_ON_WINDOWS" -a -z "\$MSYS" -a "\$OCI_EXE" != "podman" ]; then
    #    USER_IDS=(-e BUILDER_UID="\$( id -u )" -e BUILDER_GID="\$( id -g )" -e BUILDER_USER="\$( id -un )" -e BUILDER_GROUP="\$( id -gn )")
    #fi

    # Change the PWD when working in Docker on Windows
    if [ -n "\$UBUNTU_ON_WINDOWS" ]; then
        WSL_ROOT="/mnt/"
        CFG_FILE=/etc/wsl.conf
            if [ -f "\$CFG_FILE" ]; then
                    CFG_CONTENT=\$(cat \$CFG_FILE | sed -r '/[^=]+=[^=]+/!d' | sed -r 's/\s+=\s/=/g')
                    eval "\$CFG_CONTENT"
                    if [ -n "\$root" ]; then
                            WSL_ROOT=\$root
                    fi
            fi
        HOST_PWD=\`pwd -P\`
        HOST_PWD=\${HOST_PWD/\$WSL_ROOT//}
    elif [ -n "\$MSYS" ]; then
        HOST_PWD=\$PWD
        HOST_PWD=\${HOST_PWD/\//}
        HOST_PWD=\${HOST_PWD/\//:\/}
    elif [ -n "\$CYGWIN" ]; then
        for f in pwd readlink cygpath ; do
            test -n "\$(type "\${f}" )" || { echo >&2 "Missing functionality (\${f}) (in cygwin)." ; exit 1 ; } ;
        done ;
        HOST_PWD="\$( cygpath -w "\$( readlink -f "\$( pwd ;)" ; )" ; )" ;
    else
        HOST_PWD=\$PWD
        [ -L \$HOST_PWD ] && HOST_PWD=\$(readlink \$HOST_PWD)
    fi

    # ---------- End of dockcross script snippet -------

    # Handle: dockcross --args "-v X:Y --platform P"
    ARGS=
    if [ "\$#" -ge 1 ] && [ "\$1" = "--args" ]; then
        shift
        ARGS=\$1
        shift
    fi

    # Handle: dockcross --args "-v X:Y --platform P" --image "..." --
    # Confer: https://github.com/dockcross/dockcross/blob/96d87416f639af0204bdd42553e4b99315ca8476/imagefiles/dockcross#L97C1-L134
    ARG_ARGS=
    ARG_IMAGE="${dockcross_image_id}"
    while [[ \$# != 0 ]]; do
        case \$1 in
            --)
                shift
                break
                ;;
            --args|-a)
                ARG_ARGS="\$2"
                shift 2
                ;;
            --image|-i)
                ARG_IMAGE="\$2"
                shift 2
                ;;
            -*)
                echo Unknown option \"\$1\" >&2
                exit 67
                ;;
            *)
                break
                ;;
        esac
    done

    # Directly invoke entrypoint
    exec docker run --entrypoint /bin/bash \
        --rm \
        \${ARG_ARGS} \
         -v "\$HOST_PWD":/work \
        "\${ARG_IMAGE}" ${dockcross_entrypoint} "\$@"
else
    HERE=\$(dirname "\$0")
    HERE=\$(cd "\$HERE" && pwd)
    export OCI_EXE=docker # default to podman if available, which breaks complaining about HTTPS vs HTTP on GitHub Actions communicating to http (docker) local registry.
    exec "\$HERE/dockcross-real" "\$@"
fi
EOF
        chmod +x .ci/sd4/dockcross

        # Bundle for consumers of setup-dkml.yml
        do_tar_rf .ci/sd4/dist/run-with-env.tar .ci/sd4/dockcross .ci/sd4/dockcross-real

        section_end get-dockcross
    fi
}
do_get_dockcross

# Get Opam Cache
do_get_opam_cache() {
    if [ "$unix_opam_root_cacheable" = "$unix_opam_root" ]; then return; fi
    if [ ! -e "$unix_opam_root_cacheable" ]; then return; fi
    section_begin get-opam-cache "Transferring Opam cache to $original_opam_root_cacheable"
    echo Starting transfer # need some output or GitLab CI will not display the section duration
    transfer_dir "$unix_opam_root_cacheable" "$unix_opam_root"
    echo Finished transfer
    section_end get-opam-cache
}
do_get_opam_cache

# Setup Opam

do_write_opam_scripts() {
    # ---------------------
    # Empty opam repository
    # ---------------------

    install -d .ci/sd4/eor
    cat >.ci/sd4/eor/repo <<EOF
opam-version: "2.0"
browse: "https://opam.ocaml.org/pkg/"
upstream: "https://github.com/ocaml/opam-repository/tree/master/"
EOF

    # ---------------
    # Create Opam troubleshooting script
    #   Dump logs modified within the last 4 hours
    # ---------------

    cat >.ci/sd4/troubleshoot-opam.sh <<EOF
#!/bin/sh
set -euf
OPAMROOT=\$1
shift
if find . -maxdepth 0 -mmin -240 2>/dev/null >/dev/null; then
    FINDARGS="-mmin -240" # is -mmin supported? BSD (incl. macOS), MSYS2, GNU
else
    FINDARGS="-mtime -1" # use 1 day instead. Solaris
fi
printf "\n\n========= [START OF TROUBLESHOOTING] ===========\n\n" >&2
find "\$OPAMROOT"/log -mindepth 1 -maxdepth 1 \$FINDARGS -name "*.out" ! -name "log-*.out" ! -name "ocaml-variants-*.out" | while read -r dump_on_error_LOG; do
    dump_on_error_BLOG=\$(basename "\$dump_on_error_LOG")
    printf "\n\n========= [TROUBLESHOOTING] %s ===========\n\n" "\$dump_on_error_BLOG" >&2
    awk -v BLOG="\$dump_on_error_BLOG" '{print "[" BLOG "]", \$0}' "\$dump_on_error_LOG" >&2
done
printf "\nScroll up to see the [TROUBLESHOOTING] logs that begin at the [START OF TROUBLESHOOTING] line\n" >&2
EOF

    chmod +x .ci/sd4/troubleshoot-opam.sh
    do_tar_rf .ci/sd4/dist/run-with-env.tar .ci/sd4/troubleshoot-opam.sh

    # ---------------
    # Create Opam support scripts (not needed for all platforms)
    #   The PATH to find opam must work internally in setup-dkml.yml (sd4/bs/bin)
    # ---------------

    USER_ID=$(id -u)
    GROUP_ID=$(id -g)
    USER_NAME=$(id -un)
    GROUP_NAME=$(id -gn)

    case "${opam_root}" in
    /* | ?:*) # /a/b/c or C:\Windows
        validate_supports_docker() {
            echo "Docker only supported with relative paths for the opam root, not: ${opam_root}"
            exit 3
        }
        ;;
    *) # relative path
        validate_supports_docker() {
            true
        }
        cat >.ci/sd4/run-in-docker <<EOF
#!/bin/sh
set -euf
export PATH="/work/.ci/local/bin:/work/.ci/sd4/bs/bin:\$PATH"
export OPAMROOT=/work/${opam_root}
export OPAMROOTISOK=1

# Reset environment so no conflicts with a parent Opam or OCaml system
unset OPAM_SWITCH_PREFIX
unset OPAMSWITCH
unset CAML_LD_LIBRARY_PATH
unset OCAMLLIB
unset OCAML_TOPLEVEL_PATH

prog=\$1
shift

# Optionally skip troubleshooting
troubleshooting=1
if [ "\$#" -ge 1 ] && [ "\$prog" = opam ] && [ "\$1" = "--no-troubleshooting" ]; then
    shift
    troubleshooting=0
fi

echo "Running inside Docker container: \$prog \$*" >&2
set +e
"\$prog" "\$@"
exitcode=\$?
if [ \$troubleshooting = 1 ] && [ \$prog = opam ]; then
    [ \$exitcode = 0 ] || "/work/.ci/sd4/troubleshoot-opam.sh" \$OPAMROOT
fi
exit \$exitcode
EOF
        chmod +x .ci/sd4/run-in-docker
        ;;
    esac

    cat >.ci/sd4/deescalate <<EOF
#!/bin/sh
set -euf

if [ -e /work/.ci/sd4/bs/bin/deps.tar.gz ]; then
    tar xCfz / /work/.ci/sd4/bs/bin/deps.tar.gz
fi

groupadd -g ${GROUP_ID} ${GROUP_NAME}
useradd -l -m -u ${USER_ID} -g ${GROUP_ID} ${USER_NAME}
exec runuser -u ${USER_NAME} -g ${GROUP_NAME} -- "\$@"
EOF

    chmod +x .ci/sd4/deescalate

    # -----------------------------------
    # Create run-with-env
    # -----------------------------------

    install -d .ci/sd4/dist

    if [ -x .ci/sd4/dockcross ]; then
        # Adding empty dockcross root volume avoids:
        #    cp: target ‘/home/root/’ is not a directory
        #    chown: cannot access ‘/home/root’: No such file or directory
        # from https://github.com/dockcross/dockcross/blob/96d87416f639af0204bdd42553e4b99315ca8476/imagefiles/entrypoint.sh#L31-L32
        install -d .ci/sd4/edr

        cat >.ci/sd4/run-with-env <<EOF
#!/bin/sh
set -euf

HERE=\$(dirname "\$0")
HERE=\$(cd "\$HERE" && pwd)
PROJECT_DIR=\$(cd "\$HERE"/../.. && pwd)

# Optionally enable terminal if and only if '-it' option given
termargs=
if [ "\$#" -ge 1 ] && [ "\$1" = "-it" ]; then
    shift
    termargs=-it
fi

exec bash "\${PROJECT_DIR}"/.ci/sd4/dockcross ${dockcross_cli_image_args} --args "\${termargs} -v \${PROJECT_DIR}/.ci/sd4/edr:/home/root ${dockcross_run_extra_args:-}" /work/.ci/sd4/run-in-docker "\$@"
EOF
        chmod +x .ci/sd4/run-with-env

        validate_supports_docker

        # Bundle for consumers of setup-dkml.yml
        echo '__ run-in-docker __'
        cat .ci/sd4/run-in-docker
        echo '___________________'
        do_tar_rf .ci/sd4/dist/run-with-env.tar .ci/sd4/run-with-env .ci/sd4/run-in-docker .ci/sd4/edr

    elif [ "${in_docker:-}" = "true" ] && [ -n "${docker_runner:-}" ]; then

        cat >.ci/sd4/run-with-env <<EOF
#!/bin/sh
set -euf
exec ${docker_runner:-} /work/.ci/sd4/deescalate /work/.ci/sd4/run-in-docker "\$@"
EOF
        chmod +x .ci/sd4/run-with-env

        validate_supports_docker

        # Bundle for consumers of setup-dkml.yml
        echo '__ run-in-docker __'
        cat .ci/sd4/run-in-docker
        echo '________________________'
        echo '__ deescalate __'
        cat .ci/sd4/deescalate
        echo '________________'
        do_tar_rf .ci/sd4/dist/run-with-env.tar .ci/sd4/run-with-env .ci/sd4/run-in-docker .ci/sd4/deescalate

    else

        cat >.ci/sd4/run-with-env <<EOF
#!/bin/sh
set -euf

HERE=\$(dirname "\$0")
HERE=\$(cd "\$HERE" && pwd)
PROJECT_DIR=\$(cd "\$HERE"/../.. && pwd)

export PATH="\${PROJECT_DIR}/.ci/local/bin:\${PROJECT_DIR}/.ci/sd4/bs/bin:\$PATH"
export OPAMROOT='${opam_root}'
export OPAMROOTISOK=1

# Reset environment so no conflicts with a parent Opam or OCaml system
unset OPAM_SWITCH_PREFIX
unset OPAMSWITCH
unset CAML_LD_LIBRARY_PATH
unset OCAMLLIB
unset OCAML_TOPLEVEL_PATH

prog=\$1
shift

# Optionally skip troubleshooting
troubleshooting=1
if [ "\$#" -ge 1 ] && [ "\$prog" = opam ] && [ "\$1" = "--no-troubleshooting" ]; then
    shift
    troubleshooting=0
fi

echo "Running: \$prog \$*" >&2
set +e
"\$prog" "\$@"
exitcode=\$?
if [ \$troubleshooting = 1 ] && [ \$prog = opam ]; then
    [ \$exitcode = 0 ] || "\${PROJECT_DIR}/.ci/sd4/troubleshoot-opam.sh" \$OPAMROOT
fi
exit \$exitcode
EOF
        chmod +x .ci/sd4/run-with-env

        # Bundle for consumers of setup-dkml.yml
        do_tar_rf .ci/sd4/dist/run-with-env.tar .ci/sd4/run-with-env

    fi
    echo '__ run-with-env __'
    cat .ci/sd4/run-with-env
    echo '__________________'

    # ------
    # cmdrun
    # ------

    install -d .ci/sd4/opamrun
    cat >.ci/sd4/opamrun/cmdrun <<EOF
#!/bin/sh
set -euf

HERE=\$(dirname "\$0")
HERE=\$(cd "\$HERE" && pwd)
PROJECT_DIR=\$(cd "\$HERE"/../../.. && pwd)

# Add MSVC compiler environment if available
if [ -e "\${PROJECT_DIR}/.ci/sd4/msvcenv" ]; then
    _oldpath="\$PATH"
    # shellcheck disable=SC1091
    . "\${PROJECT_DIR}/.ci/sd4/msvcenv"
    PATH="\$PATH:\$_oldpath"

    # MSVC (link.exe) needs a TMP as well.
    # Confer: https://docs.microsoft.com/en-us/cpp/build/reference/linking?view=msvc-170#link-environment-variables
    if [ -z "\${TMP:-}" ]; then
        # GitHub Actions as of 2022-10 does not set TMP. GitLab CI/CD does.
        TMP="\$RUNNER_TEMP"
    fi
    export TMP
    if [ -x /usr/bin/cygpath ]; then
        TMP=\$(/usr/bin/cygpath -aw "\$TMP")
    fi
fi

# Windows
if [ -n "\${COMSPEC:-}" ]; then
    # We must place MSYS2 in front of path so that MSYS2
    # tar.exe is used instead of Windows tar.exe.
    PATH="/usr/bin:\$PATH"
fi

# Propagate important CI environment variables
export CI='${CI:-}'

exec "\${PROJECT_DIR}/.ci/sd4/run-with-env" "\$@"
EOF
    chmod +x .ci/sd4/opamrun/cmdrun
    echo '__ cmdrun __'
    cat .ci/sd4/opamrun/cmdrun
    echo '____________'

    # -------
    # opamrun
    # -------

    install -d .ci/sd4/opamrun
    cat >.ci/sd4/opamrun/opamrun <<EOF
#!/bin/sh
set -euf

HERE=\$(dirname "\$0")
HERE=\$(cd "\$HERE" && pwd)
PROJECT_DIR=\$(cd "\$HERE"/../../.. && pwd)

exec "\${PROJECT_DIR}/.ci/sd4/opamrun/cmdrun" opam "\$@"
EOF
    chmod +x .ci/sd4/opamrun/opamrun
    echo '__ opamrun __'
    cat .ci/sd4/opamrun/opamrun
    echo '_____________'

    # Bundle for consumers of setup-dkml.yml
    do_tar_rf .ci/sd4/dist/run-with-env.tar .ci/sd4/opamrun
}
section_begin 'write-opam-scripts' 'Write opam scripts'
do_write_opam_scripts
section_end 'write-opam-scripts'

# Expose opamrun (also used for consumers of setup-dkml.yml) to GitHub
if [ -n "${GITHUB_PATH:-}" ]; then
    opamrunabs="$setup_WORKSPACE/.ci/sd4/opamrun"
    if [ -x /usr/bin/cygpath ]; then opamrunabs=$(/usr/bin/cygpath -aw "$opamrunabs"); fi
    echo "$opamrunabs" >>"$GITHUB_PATH"
    # Special case: GITHUB_PATH does not influence msys2.CMD of msys2/setup-msys2@v2, so place in real MSYS2 PATH
    if [ -n "${MSYSTEM:-}" ]; then
        install -d /usr/local/bin
        install .ci/sd4/opamrun/opamrun /usr/local/bin/opamrun
    fi
fi

# Place opamrun in the immediate PATH
PATH="$setup_WORKSPACE/.ci/sd4/opamrun:$PATH"

#   Complicated Opam sequence is because:
#   1. Opam's default curl does not work on Windows,
#      and `opam init` does not provide a way to change it (TODO: need
#      a PR!).
#   2. We have to separate the Opam download cache from the other Opam
#      caches
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ] && [ ! -s "$opam_root/.ci.root-init" ]; then # non-empty init file so can be cached irrespective of existence
    section_begin opam-init 'Initialize opam root'

    # Clear any partial previous attempt
    rm -rf "$opam_root"
    
    # Set --git-location variant
    if [ -n "${GIT_LOCATION:-}" ]; then
        if [ -x /usr/bin/cygpath ]; then
            GIT_LOCATION_MIXED=$(/usr/bin/cygpath -am "$GIT_LOCATION")
            opamrun_gitloc() {
                opamrun "$@" "--git-location=$GIT_LOCATION_MIXED"
            }
        else
            opamrun_gitloc() {
                opamrun "$@" "--git-location=$GIT_LOCATION"
            }
        fi
    else
        opamrun_gitloc() {
            opamrun "$@"
        }
    fi

    case "$dkml_host_abi,${in_docker:-}" in
    windows_*,*)
        eor=$(/usr/bin/cygpath -am "$setup_WORKSPACE"/.ci/sd4/eor)
        cygloc=$(/usr/bin/cygpath -am /)
        case "$(opamrun --version)" in
         2.1.*|2.0.*|1.*) opamrun init --disable-sandboxing --no-setup --kind local --bare "$eor" ;;
         *) opamrun_gitloc init --disable-sandboxing --no-setup --kind local "--cygwin-location=$cygloc" --bare "$eor" ;;
        esac
        case "$(opamrun --version)" in
         2.0.*) echo 'download-command: wget' >>"$opam_root/config" ;;
         *) opamrun option --yes --global download-command=wget ;;
        esac
        ;;
    *,true)
        #  no --git-location needed inside Docker container
        opamrun init --disable-sandboxing --no-setup --kind local --bare "/work/.ci/sd4/eor"
        ;;
    *)
        case "$(opamrun --version)" in
         2.1.*|2.0.*|1.*) opamrun init --disable-sandboxing --no-setup --kind local --bare "$setup_WORKSPACE/.ci/sd4/eor" ;;
         *) opamrun_gitloc init --disable-sandboxing --no-setup --kind local --bare "$setup_WORKSPACE/.ci/sd4/eor" ;;
        esac
        ;;
    esac
    echo yes > "$opam_root/.ci.root-init"

    section_end opam-init
fi

if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    section_begin opam-vars "Summary: opam global variables"
    opamrun --no-troubleshooting var --global || true
    section_end opam-vars
fi

# Build OCaml

do_switch_create() {
    do_switch_create_NAME=$1
    shift

    section_begin "switch-create-$do_switch_create_NAME" "Create opam switch '$do_switch_create_NAME'"
    # Create, or recreate, the Opam switch. The Opam switch should not be
    # cached except for the compiler (confer docs for setup-ocaml GitHub
    # Action) which is the 'dkml' switch (or the 'two' switch).
    # Check if the switch name is present in the Opam root (which may come from cache)
    NOMINALLY_PRESENT=false
    if opamrun switch list --short | grep "^${do_switch_create_NAME}\$"; then NOMINALLY_PRESENT=true; fi

    # Check if the switch is actually present in case of cache incoherence
    # or corrupt Opam state that could result in:
    #   Error:  No config file found for switch dkml. Switch broken?
    if [ $NOMINALLY_PRESENT = true ] && [ ! -e "$opam_root/$do_switch_create_NAME/.opam-switch/switch-config" ]; then
        # Remove the switch name from Opam root, and any partial switch state.
        # Ignore inevitable warnings/failure about missing switch.
        opamrun --no-troubleshooting switch remove "$do_switch_create_NAME" --yes || true
        rm -rf "${opam_root:?}/$do_switch_create_NAME"
        NOMINALLY_PRESENT=false
    fi

    if [ $NOMINALLY_PRESENT = false ]; then
        opamrun switch create "$do_switch_create_NAME" --empty --yes
    fi
    section_end "switch-create-$do_switch_create_NAME"
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_switch_create dkml
    if [ "${SECONDARY_SWITCH:-}" = "true" ]; then
        do_switch_create two
    else
        section_begin "switch-create-two" "Create empty opam switch 'two'"
        # Always create a secondary switch ... just empty. Avoid problems with cache content missing
        # and idempotency.
        opamrun --no-troubleshooting switch remove two --yes || true
        rm -rf "$opam_root/two"
        opamrun switch create two --empty --yes
        section_end "switch-create-two"
    fi
fi

do_switch_active() {
    section_begin "switch-active" "Set dkml as active switch"
    opamrun switch set dkml --yes
    section_end "switch-active"
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_switch_active
fi

case "${DISKUV_OPAM_REPOSITORY:-}" in
  file://*) 
    DISKUV_OPAM_REPOSITORY_URI="${DISKUV_OPAM_REPOSITORY}" ;;
  *)
    DISKUV_OPAM_REPOSITORY_URI="git+https://github.com/diskuv/diskuv-opam-repository.git#${DISKUV_OPAM_REPOSITORY:-$DEFAULT_DISKUV_OPAM_REPOSITORY_TAG}" ;;
esac

do_opam_repositories_add() {
    section_begin "opam-repo-add" "Add 'diskuv' opam repository"
    if ! opamrun --no-troubleshooting repository list -s | grep '^diskuv'; then
        opamrun repository add diskuv "${DISKUV_OPAM_REPOSITORY_URI}" --yes --dont-select
    fi
    section_end "opam-repo-add"
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_opam_repositories_add
fi

do_opam_repositories_config() {
    do_opam_repositories_config_NAME=$1
    shift

    section_begin "opam-repo-$do_opam_repositories_config_NAME" "Attach repositories to $do_opam_repositories_config_NAME"

    if [ ! -s "$opam_root/.ci.$do_opam_repositories_config_NAME.repo-init" ]; then # non-empty init file so can be cached irrespective of existence
        opamrun --no-troubleshooting repository remove default --switch "$do_opam_repositories_config_NAME" --yes || true
        opamrun --no-troubleshooting repository remove diskuv --switch "$do_opam_repositories_config_NAME" --yes || true
        opamrun repository add default --switch "$do_opam_repositories_config_NAME" --yes
        opamrun repository add diskuv --switch "$do_opam_repositories_config_NAME" --yes
        echo yes > "$opam_root/.ci.$do_opam_repositories_config_NAME.repo-init"
    fi

    section_end "opam-repo-$do_opam_repositories_config_NAME"
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_opam_repositories_config dkml
    if [ "${SECONDARY_SWITCH:-}" = "true" ]; then
        do_opam_repositories_config two
    fi
fi

do_opam_repositories_update() {
    section_begin "opam-repo-update" "Update opam repositories"
    # The default repository may be the initial 'eor' (empty) repository
    opamrun repository set-url default "git+https://github.com/ocaml/opam-repository.git#${OCAML_OPAM_REPOSITORY:-$DEFAULT_OCAML_OPAM_REPOSITORY_TAG}" --yes
    # Always set the `diskuv` repository url since it can change
    opamrun repository set-url diskuv "${DISKUV_OPAM_REPOSITORY_URI}" --yes --dont-select
    # Update both `default` and `diskuv` Opam repositories
    opamrun update default diskuv
    section_end "opam-repo-update"
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_opam_repositories_update
fi

do_pins() {
    do_pins_NAME=$1
    shift

    section_begin "opam-pins-$do_pins_NAME" "Opam pins for $do_pins_NAME switch"
    #   adapted from dkml-runtime-common's _common_tool.sh:get_opam_switch_state_toplevelsection
    if [ -e "$opam_root/$do_pins_NAME/.opam-switch/switch-state" ]; then
        #       shellcheck disable=SC2016
        awk -v section="pinned" \
            '$1 ~ ":" {state=0} $1==(section ":") {state=1} state==1{print}' \
            "$opam_root/$do_pins_NAME/.opam-switch/switch-state" \
            > "$opam_root/.ci.$do_pins_NAME.pinned"
    else
        touch "$opam_root/.ci.$do_pins_NAME.pinned"
    fi
    do_pin_add() {
        do_pin_add_NAME=$1; shift
        do_pin_add_VER=$1; shift
        # ex. "astring.1.0.2" - The double-quotes are necessary.
        if ! grep -q "\"$do_pin_add_NAME.$do_pin_add_VER\"" "$opam_root/.ci.$do_pins_NAME.pinned"; then
            opamrun pin add --switch "$do_pins_NAME"  --yes --no-action -k version "$do_pin_add_NAME" "$do_pin_add_VER"
        fi
    }
    ### BEGIN pin-adds. DO NOT EDIT THE LINES IN THIS SECTION
    # Managed by bump-packages.cmake
    do_pin_add angstrom "${PIN_ANGSTROM}"
    do_pin_add astring "${PIN_ASTRING}"
    do_pin_add base "${PIN_BASE}"
    do_pin_add base64 "${PIN_BASE64}"
    do_pin_add bigarray-compat "${PIN_BIGARRAY_COMPAT}"
    do_pin_add bigstringaf "${PIN_BIGSTRINGAF}"
    do_pin_add bos "${PIN_BOS}"
    do_pin_add camlp-streams "${PIN_CAMLP_STREAMS}"
    do_pin_add chrome-trace "${PIN_CHROME_TRACE}"
    do_pin_add cmdliner "${PIN_CMDLINER}"
    do_pin_add conf-bash "${PIN_CONF_BASH}"
    do_pin_add conf-dkml-sys-opam "${PIN_CONF_DKML_SYS_OPAM}"
    do_pin_add conf-pkg-config "${PIN_CONF_PKG_CONFIG}"
    do_pin_add conf-sqlite3 "${PIN_CONF_SQLITE3}"
    do_pin_add cppo "${PIN_CPPO}"
    do_pin_add crunch "${PIN_CRUNCH}"
    do_pin_add csexp "${PIN_CSEXP}"
    do_pin_add cstruct "${PIN_CSTRUCT}"
    do_pin_add ctypes "${PIN_CTYPES}"
    do_pin_add ctypes-foreign "${PIN_CTYPES_FOREIGN}"
    do_pin_add cudf "${PIN_CUDF}"
    do_pin_add digestif "${PIN_DIGESTIF}"
    do_pin_add diskuvbox "${PIN_DISKUVBOX}"
    do_pin_add dkml-apps "${PIN_DKML_APPS}"
    do_pin_add dkml-base-compiler "${PIN_DKML_BASE_COMPILER}"
    do_pin_add dkml-build-desktop "${PIN_DKML_BUILD_DESKTOP}"
    do_pin_add dkml-c-probe "${PIN_DKML_C_PROBE}"
    do_pin_add dkml-compiler-src "${PIN_DKML_COMPILER_SRC}"
    do_pin_add dkml-component-common-desktop "${PIN_DKML_COMPONENT_COMMON_DESKTOP}"
    do_pin_add dkml-component-common-opam "${PIN_DKML_COMPONENT_COMMON_OPAM}"
    do_pin_add dkml-component-common-unixutils "${PIN_DKML_COMPONENT_COMMON_UNIXUTILS}"
    do_pin_add dkml-component-ocamlcompiler-common "${PIN_DKML_COMPONENT_OCAMLCOMPILER_COMMON}"
    do_pin_add dkml-component-ocamlcompiler-network "${PIN_DKML_COMPONENT_OCAMLCOMPILER_NETWORK}"
    do_pin_add dkml-component-ocamlcompiler-offline "${PIN_DKML_COMPONENT_OCAMLCOMPILER_OFFLINE}"
    do_pin_add dkml-component-offline-desktop-full "${PIN_DKML_COMPONENT_OFFLINE_DESKTOP_FULL}"
    do_pin_add dkml-component-offline-opamshim "${PIN_DKML_COMPONENT_OFFLINE_OPAMSHIM}"
    do_pin_add dkml-component-offline-unixutils "${PIN_DKML_COMPONENT_OFFLINE_UNIXUTILS}"
    do_pin_add dkml-component-staging-desktop-full "${PIN_DKML_COMPONENT_STAGING_DESKTOP_FULL}"
    do_pin_add dkml-component-staging-dkmlconfdir "${PIN_DKML_COMPONENT_STAGING_DKMLCONFDIR}"
    do_pin_add dkml-component-staging-ocamlrun "${PIN_DKML_COMPONENT_STAGING_OCAMLRUN}"
    do_pin_add dkml-component-staging-opam32 "${PIN_DKML_COMPONENT_STAGING_OPAM32}"
    do_pin_add dkml-component-staging-opam64 "${PIN_DKML_COMPONENT_STAGING_OPAM64}"
    do_pin_add dkml-component-staging-unixutils "${PIN_DKML_COMPONENT_STAGING_UNIXUTILS}"
    do_pin_add dkml-component-staging-withdkml "${PIN_DKML_COMPONENT_STAGING_WITHDKML}"
    do_pin_add dkml-component-xx-console "${PIN_DKML_COMPONENT_XX_CONSOLE}"
    do_pin_add dkml-exe "${PIN_DKML_EXE}"
    do_pin_add dkml-exe-lib "${PIN_DKML_EXE_LIB}"
    do_pin_add dkml-host-abi "${PIN_DKML_HOST_ABI}"
    do_pin_add dkml-host-abi-windows_x86_64 "${PIN_DKML_HOST_ABI_WINDOWS_X86_64}"
    do_pin_add dkml-install "${PIN_DKML_INSTALL}"
    do_pin_add dkml-install-installer "${PIN_DKML_INSTALL_INSTALLER}"
    do_pin_add dkml-install-runner "${PIN_DKML_INSTALL_RUNNER}"
    do_pin_add dkml-installer-ocaml-common "${PIN_DKML_INSTALLER_OCAML_COMMON}"
    do_pin_add dkml-installer-ocaml-network "${PIN_DKML_INSTALLER_OCAML_NETWORK}"
    do_pin_add dkml-package-console "${PIN_DKML_PACKAGE_CONSOLE}"
    do_pin_add dkml-runtime-common "${PIN_DKML_RUNTIME_COMMON}"
    do_pin_add dkml-runtime-common-native "${PIN_DKML_RUNTIME_COMMON_NATIVE}"
    do_pin_add dkml-runtime-distribution "${PIN_DKML_RUNTIME_DISTRIBUTION}"
    do_pin_add dkml-runtimelib "${PIN_DKML_RUNTIMELIB}"
    do_pin_add dkml-runtimescripts "${PIN_DKML_RUNTIMESCRIPTS}"
    do_pin_add dkml-target-abi-windows_x86_64 "${PIN_DKML_TARGET_ABI_WINDOWS_X86_64}"
    do_pin_add dkml-workflows "${PIN_DKML_WORKFLOWS}"
    do_pin_add dune "${PIN_DUNE}"
    do_pin_add dune-action-plugin "${PIN_DUNE_ACTION_PLUGIN}"
    do_pin_add dune-build-info "${PIN_DUNE_BUILD_INFO}"
    do_pin_add dune-configurator "${PIN_DUNE_CONFIGURATOR}"
    do_pin_add dune-glob "${PIN_DUNE_GLOB}"
    do_pin_add dune-private-libs "${PIN_DUNE_PRIVATE_LIBS}"
    do_pin_add dune-rpc "${PIN_DUNE_RPC}"
    do_pin_add dune-rpc-lwt "${PIN_DUNE_RPC_LWT}"
    do_pin_add dune-site "${PIN_DUNE_SITE}"
    do_pin_add dyn "${PIN_DYN}"
    do_pin_add either "${PIN_EITHER}"
    do_pin_add eqaf "${PIN_EQAF}"
    do_pin_add extlib "${PIN_EXTLIB}"
    do_pin_add ezjsonm "${PIN_EZJSONM}"
    do_pin_add feather "${PIN_FEATHER}"
    do_pin_add fiber "${PIN_FIBER}"
    do_pin_add fix "${PIN_FIX}"
    do_pin_add fmt "${PIN_FMT}"
    do_pin_add fpath "${PIN_FPATH}"
    do_pin_add graphics "${PIN_GRAPHICS}"
    do_pin_add hex "${PIN_HEX}"
    do_pin_add hmap "${PIN_HMAP}"
    do_pin_add host-arch-x86_64 "${PIN_HOST_ARCH_X86_64}"
    do_pin_add integers "${PIN_INTEGERS}"
    do_pin_add iostream "${PIN_IOSTREAM}"
    do_pin_add jane-street-headers "${PIN_JANE_STREET_HEADERS}"
    do_pin_add jingoo "${PIN_JINGOO}"
    do_pin_add jsonm "${PIN_JSONM}"
    do_pin_add jsonrpc "${PIN_JSONRPC}"
    do_pin_add jst-config "${PIN_JST_CONFIG}"
    do_pin_add lambda-term "${PIN_LAMBDA_TERM}"
    do_pin_add logs "${PIN_LOGS}"
    do_pin_add lsp "${PIN_LSP}"
    do_pin_add lwt "${PIN_LWT}"
    do_pin_add lwt_react "${PIN_LWT_REACT}"
    do_pin_add mccs "${PIN_MCCS}"
    do_pin_add mdx "${PIN_MDX}"
    do_pin_add menhir "${PIN_MENHIR}"
    do_pin_add menhirCST "${PIN_MENHIRCST}"
    do_pin_add menhirLib "${PIN_MENHIRLIB}"
    do_pin_add menhirSdk "${PIN_MENHIRSDK}"
    do_pin_add merlin-lib "${PIN_MERLIN_LIB}"
    do_pin_add metapp "${PIN_METAPP}"
    do_pin_add metaquot "${PIN_METAQUOT}"
    do_pin_add mew "${PIN_MEW}"
    do_pin_add mew_vi "${PIN_MEW_VI}"
    do_pin_add msys2 "${PIN_MSYS2}"
    do_pin_add msys2-clang64 "${PIN_MSYS2_CLANG64}"
    do_pin_add num "${PIN_NUM}"
    do_pin_add ocaml "${PIN_OCAML}"
    do_pin_add ocaml-compiler-libs "${PIN_OCAML_COMPILER_LIBS}"
    do_pin_add ocaml-lsp-server "${PIN_OCAML_LSP_SERVER}"
    do_pin_add ocaml-syntax-shims "${PIN_OCAML_SYNTAX_SHIMS}"
    do_pin_add ocaml-version "${PIN_OCAML_VERSION}"
    do_pin_add ocamlbuild "${PIN_OCAMLBUILD}"
    do_pin_add ocamlc-loc "${PIN_OCAMLC_LOC}"
    do_pin_add ocamlfind "${PIN_OCAMLFIND}"
    do_pin_add ocamlformat "${PIN_OCAMLFORMAT}"
    do_pin_add ocamlformat-lib "${PIN_OCAMLFORMAT_LIB}"
    do_pin_add ocamlformat-rpc-lib "${PIN_OCAMLFORMAT_RPC_LIB}"
    do_pin_add ocp-indent "${PIN_OCP_INDENT}"
    do_pin_add ocplib-endian "${PIN_OCPLIB_ENDIAN}"
    do_pin_add odoc "${PIN_ODOC}"
    do_pin_add odoc-parser "${PIN_ODOC_PARSER}"
    do_pin_add ordering "${PIN_ORDERING}"
    do_pin_add parsexp "${PIN_PARSEXP}"
    do_pin_add posixat "${PIN_POSIXAT}"
    do_pin_add pp "${PIN_PP}"
    do_pin_add ppx_assert "${PIN_PPX_ASSERT}"
    do_pin_add ppx_base "${PIN_PPX_BASE}"
    do_pin_add ppx_cold "${PIN_PPX_COLD}"
    do_pin_add ppx_compare "${PIN_PPX_COMPARE}"
    do_pin_add ppx_derivers "${PIN_PPX_DERIVERS}"
    do_pin_add ppx_deriving "${PIN_PPX_DERIVING}"
    do_pin_add ppx_enumerate "${PIN_PPX_ENUMERATE}"
    do_pin_add ppx_expect "${PIN_PPX_EXPECT}"
    do_pin_add ppx_globalize "${PIN_PPX_GLOBALIZE}"
    do_pin_add ppx_hash "${PIN_PPX_HASH}"
    do_pin_add ppx_here "${PIN_PPX_HERE}"
    do_pin_add ppx_ignore_instrumentation "${PIN_PPX_IGNORE_INSTRUMENTATION}"
    do_pin_add ppx_inline_test "${PIN_PPX_INLINE_TEST}"
    do_pin_add ppx_optcomp "${PIN_PPX_OPTCOMP}"
    do_pin_add ppx_pipebang "${PIN_PPX_PIPEBANG}"
    do_pin_add ppx_sexp_conv "${PIN_PPX_SEXP_CONV}"
    do_pin_add ppx_yojson_conv_lib "${PIN_PPX_YOJSON_CONV_LIB}"
    do_pin_add ppxlib "${PIN_PPXLIB}"
    do_pin_add ptime "${PIN_PTIME}"
    do_pin_add qrc "${PIN_QRC}"
    do_pin_add re "${PIN_RE}"
    do_pin_add react "${PIN_REACT}"
    do_pin_add refl "${PIN_REFL}"
    do_pin_add result "${PIN_RESULT}"
    do_pin_add rresult "${PIN_RRESULT}"
    do_pin_add seq "${PIN_SEQ}"
    do_pin_add sexplib "${PIN_SEXPLIB}"
    do_pin_add sexplib0 "${PIN_SEXPLIB0}"
    do_pin_add sha "${PIN_SHA}"
    do_pin_add shexp "${PIN_SHEXP}"
    do_pin_add spawn "${PIN_SPAWN}"
    do_pin_add sqlite3 "${PIN_SQLITE3}"
    do_pin_add stdcompat "${PIN_STDCOMPAT}"
    do_pin_add stdio "${PIN_STDIO}"
    do_pin_add stdlib-shims "${PIN_STDLIB_SHIMS}"
    do_pin_add stdune "${PIN_STDUNE}"
    do_pin_add stringext "${PIN_STRINGEXT}"
    do_pin_add time_now "${PIN_TIME_NOW}"
    do_pin_add tiny_httpd "${PIN_TINY_HTTPD}"
    do_pin_add topkg "${PIN_TOPKG}"
    do_pin_add traverse "${PIN_TRAVERSE}"
    do_pin_add trie "${PIN_TRIE}"
    do_pin_add tsort "${PIN_TSORT}"
    do_pin_add tyxml "${PIN_TYXML}"
    do_pin_add uchar "${PIN_UCHAR}"
    do_pin_add uri "${PIN_URI}"
    do_pin_add utop "${PIN_UTOP}"
    do_pin_add uucp "${PIN_UUCP}"
    do_pin_add uuidm "${PIN_UUIDM}"
    do_pin_add uuseg "${PIN_UUSEG}"
    do_pin_add uutf "${PIN_UUTF}"
    do_pin_add with-dkml "${PIN_WITH_DKML}"
    do_pin_add xdg "${PIN_XDG}"
    do_pin_add yojson "${PIN_YOJSON}"
    do_pin_add zed "${PIN_ZED}"
    ### END pin-adds. DO NOT EDIT THE LINES ABOVE
    section_end "opam-pins-$do_pins_NAME"

    # --------------
    # REMAINING PINS
    # --------------

    # These come after [pin-adds] section since [pin-adds] may need to be overridden by
    # users' choice.

    # dkml-base-compiler

    if [ "${DKML_COMPILER:-}" != '@repository@' ] && [ -z "${DKML_COMPILER:-}" ] && [ -z "${OCAML_COMPILER:-}" ]; then
        section_begin checkout-dkml-base-compiler "Pin dkml-base-compiler to default ${DEFAULT_DKML_COMPILER} (neither dkml-base-compiler nor OCAML_COMPILER specified) for $do_pins_NAME switch"
        opamrun pin add --switch "$do_pins_NAME" --yes --no-action dkml-base-compiler "https://github.com/diskuv/dkml-compiler.git#${DEFAULT_DKML_COMPILER}"
        section_end checkout-dkml-base-compiler
    elif [ "${DKML_COMPILER:-}" != '@repository@' ] && [ -n "${DKML_COMPILER:-}" ] && [ -z "${OCAML_COMPILER:-}" ]; then
        section_begin checkout-dkml-base-compiler "Pin dkml-base-compiler to $DKML_COMPILER (dkml-base-compiler specified; no OCAML_COMPILER specified) for $do_pins_NAME switch"
        case "$DKML_COMPILER" in
         file://*) opamrun pin add --switch "$do_pins_NAME" --yes --no-action dkml-base-compiler "${DKML_COMPILER}" ;;
         *) opamrun pin add --switch "$do_pins_NAME" --yes --no-action dkml-base-compiler "https://github.com/diskuv/dkml-compiler.git#${DKML_COMPILER}" ;;
        esac
        section_end checkout-dkml-base-compiler
    elif [ -n "${OCAML_COMPILER:-}" ]; then
        # Validate OCAML_COMPILER (OCAML_COMPILER specified)
        case "${OCAML_COMPILER:-}" in
        4.12.1) true ;;
        4.14.0) true ;;
        4.14.2) true ;;
        *)
            echo "OCAML_COMPILER version ${OCAML_COMPILER:-} is not supported"
            exit 109
            ;;
        esac

        section_begin checkout-dkml-base-compiler "Pin dkml-base-compiler (OCAML_COMPILER specified) for $do_pins_NAME switch"
        opamrun pin add --switch "$do_pins_NAME" --yes --no-action dkml-base-compiler "https://github.com/diskuv/dkml-compiler.git#${OCAML_COMPILER}-v${DKML_VERSION}"
        section_end checkout-dkml-base-compiler
    fi

    # conf-dkml-cross-toolchain

    if [ "${CONF_DKML_CROSS_TOOLCHAIN:-}" != '@repository@' ]; then
        section_begin checkout-conf-dkml-cross-toolchain "Pin conf-dkml-cross-toolchain for $do_pins_NAME switch"
        opamrun pin add --switch "$do_pins_NAME" --yes --no-action conf-dkml-cross-toolchain "https://github.com/diskuv/conf-dkml-cross-toolchain.git#$CONF_DKML_CROSS_TOOLCHAIN"
        section_end checkout-conf-dkml-cross-toolchain
    fi
}

if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_pins dkml
    if [ "${SECONDARY_SWITCH:-}" = "true" ]; then
        do_pins two
    fi
fi

do_use_vsstudio() {
    do_use_vsstudio_NAME=$1
    shift
    case "$dkml_host_abi" in
    windows_*)
        section_begin "use-vsstudio-$do_use_vsstudio_NAME" "Use Visual Studio in dkml-* Opam packages (Windows) for $do_use_vsstudio_NAME switch"

        # shellcheck disable=SC2153
        E_VS_DIR=$(escape_arg_as_ocaml_string "$VS_DIR")
        # shellcheck disable=SC2153
        E_VS_VCVARSVER=$(escape_arg_as_ocaml_string "$VS_VCVARSVER")
        # shellcheck disable=SC2153
        E_VS_WINSDKVER=$(escape_arg_as_ocaml_string "$VS_WINSDKVER")
        # shellcheck disable=SC2153
        E_VS_MSVSPREFERENCE=$(escape_arg_as_ocaml_string "$VS_MSVSPREFERENCE")
        # shellcheck disable=SC2153
        E_VS_CMAKEGENERATOR=$(escape_arg_as_ocaml_string "$VS_CMAKEGENERATOR")

        case "$(opamrun --version)" in
        2.0.*)
            if [ "${in_docker}" = "true" ]; then
                echo Opam 2.0 support in dockcross to use a portable opam var prefix not yet implemented
                exit 67
            fi
            OP=$(opamrun var prefix --switch "$do_use_vsstudio_NAME")
            OPSC=$OP/.opam-switch/switch-config
            if grep setenv: "$OPSC"; then
                echo "INFO: Updating switch-config. Old was:"
                awk '{print ">> " $0}' "$OPSC"

                awk '$1=="setenv:"{x=1} x==0{print} x==1 && $0=="]"{x=0}' "$OPSC" >"$OPSC".trimmed
                mv "$OPSC".trimmed "$OPSC"
            fi
            echo 'setenv: [' >>"$OPSC"
            echo '  [DKML_COMPILE_SPEC = "1"]' >>"$OPSC"
            echo '  [DKML_COMPILE_TYPE = "VS"]' >>"$OPSC"
            echo "  [DKML_COMPILE_VS_DIR = \"$E_VS_DIR\"]" >>"$OPSC"
            echo "  [DKML_COMPILE_VS_VCVARSVER = \"$E_VS_VCVARSVER\"]" >>"$OPSC"
            echo "  [DKML_COMPILE_VS_WINSDKVER = \"$E_VS_WINSDKVER\"]" >>"$OPSC"
            echo "  [DKML_COMPILE_VS_MSVSPREFERENCE = \"$E_VS_MSVSPREFERENCE\"]" >>"$OPSC"
            echo "  [DKML_COMPILE_VS_CMAKEGENERATOR = \"$E_VS_CMAKEGENERATOR\"]" >>"$OPSC"
            echo "  [DKML_HOST_ABI = \"${dkml_host_abi}\"]" >>"$OPSC"
            echo ']' >>"$OPSC"
            cat "$OPSC" # print
            ;;
        *)
            opamrun option --switch "$do_use_vsstudio_NAME" setenv= # reset
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+='DKML_COMPILE_SPEC = "1"'
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+='DKML_COMPILE_TYPE = "VS"'
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+="DKML_COMPILE_VS_DIR = \"$E_VS_DIR\""
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+="DKML_COMPILE_VS_VCVARSVER = \"$E_VS_VCVARSVER\""
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+="DKML_COMPILE_VS_WINSDKVER = \"$E_VS_WINSDKVER\""
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+="DKML_COMPILE_VS_MSVSPREFERENCE = \"$E_VS_MSVSPREFERENCE\""
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+="DKML_COMPILE_VS_CMAKEGENERATOR = \"$E_VS_CMAKEGENERATOR\""
            opamrun option --switch "$do_use_vsstudio_NAME" setenv+="DKML_HOST_ABI = \"${dkml_host_abi}\""
            opamrun option --switch "$do_use_vsstudio_NAME" setenv # print
            ;;
        esac

        # shellcheck disable=SC2016
        opamrun exec --switch "$do_use_vsstudio_NAME" -- sh -c 'echo $VCToolsRedistDir'

        section_end "use-vsstudio-$do_use_vsstudio_NAME"
        ;;
    esac
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_use_vsstudio dkml
    if [ "${SECONDARY_SWITCH:-}" = "true" ]; then
        do_use_vsstudio two
    fi
fi

# Because dune.X.Y.Z+shim (and any user DkML packages) requires DkML installed (after all, it is just
# a with-dkml.exe shim), we need either dkmlvars-v2.sexp or DkML environment
# variables. Confer: Dkml_runtimelib.Dkml_context.get_dkmlversion
#
# grep matches either:
#   [... [DiskuvOCamlVersion = "1.0.1"] ...]
#   DiskuvOCamlVersion = "1.0.1"
do_setenv() {
    do_setenv_SWITCH=$1
    shift
    section_begin "setenv-$do_setenv_SWITCH" "Set opam option for $do_setenv_SWITCH switch"
    opamrun option --switch "$do_setenv_SWITCH" setenv > ".ci/sd4/setenv.$do_setenv_SWITCH.txt"
    if ! grep -q '\(^|\[\)DiskuvOCamlVarsVersion ' ".ci/sd4/setenv.$do_setenv_SWITCH.txt"; then
        opamrun option --switch "$do_setenv_SWITCH" setenv+='DiskuvOCamlVarsVersion = "2"'
    fi
    if ! grep -q '\(^|\[\)DiskuvOCamlVersion ' ".ci/sd4/setenv.$do_setenv_SWITCH.txt"; then
        opamrun option --switch "$do_setenv_SWITCH" setenv+="DiskuvOCamlVersion = \"$DKML_VERSION\""
    fi
    if [ "$do_setenv_SWITCH" = dkml ] && [ -n "${DKML_HOME:-}" ]; then
      do_setenv_DKMLHOME_ESCAPED="$DKML_HOME"
      do_setenv_USRBIN_ESCAPED="$DKML_HOME/usr/bin"
      do_setenv_BIN_ESCAPED="$DKML_HOME/bin"
      if [ -x /usr/bin/cygpath ]; then
        do_setenv_DKMLHOME_ESCAPED=$(/usr/bin/cygpath -aw "$do_setenv_DKMLHOME_ESCAPED" | sed 's/\\/\\\\/g')
        do_setenv_USRBIN_ESCAPED=$(/usr/bin/cygpath -aw "$do_setenv_USRBIN_ESCAPED" | sed 's/\\/\\\\/g')
        do_setenv_BIN_ESCAPED=$(/usr/bin/cygpath -aw "$do_setenv_BIN_ESCAPED" | sed 's/\\/\\\\/g')
      fi
      if ! grep -q '\(^|\[\)DiskuvOCamlHome ' ".ci/sd4/setenv.$do_setenv_SWITCH.txt"; then
          opamrun option --switch "$do_setenv_SWITCH" setenv+="DiskuvOCamlHome = \"$do_setenv_DKMLHOME_ESCAPED\""
      fi
      if ! grep -q '\(^|\[\)DiskuvOCamlBinaryPaths ' ".ci/sd4/setenv.$do_setenv_SWITCH.txt"; then
          opamrun option --switch "$do_setenv_SWITCH" setenv+="DiskuvOCamlBinaryPaths = \"$do_setenv_USRBIN_ESCAPED;$do_setenv_BIN_ESCAPED\""
      fi
      if ! grep -q '\(^|\[\)DiskuvOCamlDeploymentId ' ".ci/sd4/setenv.$do_setenv_SWITCH.txt"; then
          opamrun option --switch "$do_setenv_SWITCH" setenv+="DiskuvOCamlDeploymentId = \"setup-dkml-switch-$do_setenv_SWITCH\""
      fi
    fi
    case "${dkml_host_abi}" in
    windows_*)
        if ! grep -q '\(^|\[\)DiskuvOCamlMSYS2Dir ' ".ci/sd4/setenv.$do_setenv_SWITCH.txt"; then
            if [ -x /usr/bin/cygpath ]; then
                MSYS2_DIR_NATIVE=$(/usr/bin/cygpath -aw /)
            else
                # If we are already inside MSYS2 then MSYSTEM_PREFIX should be set. But cygpath should be there as well!!
                echo "FATAL: Could not locate MSYS2: there was no cygpath"
                exit 3
            fi
            MSYS2_DIR_NATIVE_ESCAPED=$(printf "%s" "$MSYS2_DIR_NATIVE" | sed 's/\\/\\\\/g')
            opamrun option --switch "$do_setenv_SWITCH" setenv+="DiskuvOCamlMSYS2Dir = \"$MSYS2_DIR_NATIVE_ESCAPED\""
        fi
    esac
    section_end "setenv-$do_setenv_SWITCH"
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    do_setenv dkml
    if [ "${SECONDARY_SWITCH:-}" = "true" ]; then
        do_setenv two
    fi
fi

do_install_compiler() {
    do_install_compiler_NAME=$1
    shift
    section_begin "install-compiler-$do_install_compiler_NAME" "Install OCaml compiler for $do_install_compiler_NAME switch"
    opamrun pin list --switch "$do_install_compiler_NAME"
    # shellcheck disable=SC2086
    opamrun upgrade --switch "$do_install_compiler_NAME" --yes dkml-base-compiler conf-dkml-cross-toolchain ${ocaml_options:-}
    section_end "install-compiler-$do_install_compiler_NAME"
}
do_summary() {
    do_summary_NAME=$1
    shift
    section_begin "summary-$do_summary_NAME" "Summary: $do_summary_NAME switch"
    opamrun var --switch "$do_summary_NAME"
    opamrun exec --switch "$do_summary_NAME" -- ocamlc -config
    section_end "summary-$do_summary_NAME"
}
if [ "${SKIP_OPAM_MODIFICATIONS:-}" = "false" ]; then
    if ! [ "${PRIMARY_SWITCH_SKIP_INSTALL:-}" = "true" ]; then
        do_install_compiler dkml
    fi
    if [ "${SECONDARY_SWITCH:-}" = "true" ]; then
        do_install_compiler two
    fi
    if ! [ "${PRIMARY_SWITCH_SKIP_INSTALL:-}" = "true" ]; then
        do_summary dkml
    fi
    if [ "${SECONDARY_SWITCH:-}" = "true" ]; then
        do_summary two
    fi
fi
