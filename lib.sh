REPOBASE=/zboot/iocage/jails/pkgbase/root/usr/obj/build/src
REPOURL=http://pkgbase.home.rabson.org/packages
ARCHES="amd64 aarch64"
REG=registry.lab.rabson.org
BUILD=no
PUSH=no
ADD_ANNOTATIONS=no
PKG=pkg

get_abi() {
    local ver=$1; shift
    local arch=$1; shift
    echo FreeBSD:$(echo ${ver} | cut -d. -f1):${arch}
}

# Parse arguments and set branch, tag, has_caroot_data
parse_args() {
    while getopts "B:R:A:P:R:abp" arg; do
	case ${arg} in
	    B)
		REPOBASE="${OPTARG}"
		;;
	    R)
		REPOURL="${OPTARG}"
		;;
	    A)
		ARCHES="${OPTARG}"
		;;
	    P)
		PKG="${OPTARG}"
		;;
	    R)
		REG="${OPTARG}"
		;;
	    a)
		ADD_ANNOTATIONS=yes
		;;
	    b)
		BUILD=yes
		;;
	    p)
		PUSH=yes
		;;
	    *)
		echo "Unknown argument"
	esac
    done
    shift $(( ${OPTIND} - 1 ))
    if [ $# -ne 2 ]; then
	echo "usage: build-foo.sh [-B <repo dir>] [-R <repo url>] [-A <arches>] <branch> <version>" > /dev/stderr
	exit 1
    fi
    branch=$1; shift
    ver=$1; shift
    set -- $(find ${REPOBASE}/${branch}/repo/$(get_abi ${ver} amd64)/latest/ -name 'FreeBSD-certctl*')
    if [ $# -gt 0 ]; then
	has_certctl_package=yes
    else
	has_certctl_package=no
    fi
}

get_apl_path() {
    local branch=$1
    case ${branch} in
	releng/*)
	    ver=$(echo ${branch} | cut -d/ -f2)
	    echo "release/${ver}"
	    ;;
	stable/*)
	    echo "stable"
	    ;;
	main)
	    echo "current"
	    ;;
	*)
	    echo "unsupported branch for alpha.pkgbase.live: ${branch}, assuming current" > /dev/stderr
	    echo "current"
	    exit 1
	    ;;
    esac
}

# Get build version from runtime package metadata
get_build_version() {
    local workdir=$1
    env IGNORE_OSVERSION=yes ABI=${abi} ${PKG} --rootdir ${workdir}/runtime --repo-conf-dir ${workdir}/repos \
	info --raw --raw-format json FreeBSD-runtime | jq --raw-output .version
}

# Get build date from build version
get_build_date() {
    local ver=$1; shift
    case ${ver} in
	13.2p1)
	    echo 202306210000
	    ;;
	13.2p2)
	    echo 202308010000
	    ;;
	14.a?.*)
	    echo ${ver} | sed -E -e 's/14\.a[[:digit:]]\.([[:digit:]]{12}).*/\1/'
	    ;;
	*.snap*)
	    echo ${ver} | sed -E -e 's/.*snap([[:digit:]]{12}).*/\1/'
	    ;;
	*)
	    date +%Y%m%d0000
    esac
}

# Get build time in seconds from epoch
get_build_timestamp() {
    date -j $(get_build_date $1) +%s || exit $?
}

install_packages() {
    local workdir=$1; shift
    local rootdir=$1; shift
    env IGNORE_OSVERSION=yes ABI=${abi} ${PKG} --rootdir ${rootdir} --repo-conf-dir ${workdir}/repos \
	install -yq "$@" || exit $?
}

make_workdir() {
    local branch=$1
    local abi=$2
    local workdir=$(mktemp -d -t freebsd-image)
    mkdir ${workdir}/repos
    cat > ${workdir}/repos/base.conf <<EOF
# FreeBSD pkgbase repo for building the images

FreeBSD-base: {
  url: "${REPOURL}/${branch}/\${ABI}/latest",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/ssl/pkgbase.pub",
  enabled: yes
}
EOF
    cat > ${workdir}/alpha.pkgbase.live.conf <<EOF
# FreeBSD pkgbase repo

FreeBSD-base: {
  url: "https://alpha.pkgbase.live/$(get_apl_path ${branch})/\${ABI}/latest",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/pkg/keys/alpha.pkgbase.live.pub"
  enabled: no
}
EOF
    # Extract FreeBSD-runtime into the workdir to get the version and let
    # builder scripts copy fragments into an image
    mkdir ${workdir}/runtime
    install_packages ${workdir} ${workdir}/runtime FreeBSD-runtime || exit $?

    echo ${workdir}
}

create_container() {
    local workdir=$1; shift
    local buildver=$(get_build_version ${workdir})

    c=$(buildah from --pull=never "$@") || exit $?

    buildah config --annotation "org.freebsd.version=${buildver}" $c
    if [ ${ADD_ANNOTATIONS} = yes ]; then
	buildah config --annotation "org.opencontainers.image.version=${buildver}" $c
	buildah config --annotation "org.opencontainers.image.url=https://www.freebsd.org" $c
	buildah config --annotation "org.opencontainers.image.licenses=BSD2CLAUSE" $c
    fi
    echo $c
}

add_annotation() {
    local c=$1; shift
    local a=$1; shift
    if [ ${ADD_ANNOTATIONS} = yes ]; then
	buildah config --annotation ${a} ${c} || exit $?
    fi
}

install_pkgbase_repo() {
    local workdir=$1
    local m=$2
    cp ${workdir}/alpha.pkgbase.live.conf $m/usr/local/etc/pkg/repos/pkgbase.conf
    mkdir -p $m/usr/local/etc/pkg/keys || return $?
#    fetch --output=$m/usr/local/etc/pkg/keys/alpha.pkgbase.live.pub \
#	https://alpha.pkgbase.live/alpha.pkgbase.live.pub || return $?
}

clean_workdir() {
    local workdir=$1
    chflags -R 0 ${workdir}
    rm -rf ${workdir}
}

get_fqin() {
    # I would prefer the multi-level naming scheme but docker hub doesn't
    # support it.
    # echo localhost/freebsd/${ver}/$1

    echo localhost/freebsd${ver}-$1
}

# build an mtree directories only image
# usage: build_mtree <image name>
build_mtree() {
    local name=$1; shift

    # Note, we expect the same version for each arch and the image will be tagged
    # with the version from the last arch.
    local images=
    local tag=
    local image=$(get_fqin ${name})
    for arch in ${ARCHES}; do
	local abi=$(get_abi ${ver} ${arch})
	local workdir=$(make_workdir ${branch} ${abi})
	tag=$(get_build_version ${workdir})
	local c=$(create_container ${workdir} --arch=${arch} scratch)
	local m=$(buildah mount $c)

	echo Generating ${name} for ${arch}
	local timestamp=$(get_build_timestamp ${tag})

	echo Creating directory structure
	# Install mtree package to a temp directory since it also pulls in
	# FreeBSD-runtime
	mkdir ${workdir}/tmp
	install_packages ${workdir} ${workdir}/tmp FreeBSD-mtree || exit $?
	mtree -deU -p $m/ -f ${workdir}/tmp/etc/mtree/BSD.root.dist > /dev/null
	mtree -deU -p $m/var -f ${workdir}/tmp/etc/mtree/BSD.var.dist > /dev/null
	mtree -deU -p $m/usr -f ${workdir}/tmp/etc/mtree/BSD.usr.dist > /dev/null
	mtree -deU -p $m/usr/include -f ${workdir}/tmp/etc/mtree/BSD.include.dist > /dev/null
	mtree -deU -p $m/usr/lib -f ${workdir}/tmp/etc/mtree/BSD.debug.dist > /dev/null

	# Cleanup
	chflags -R 0 ${workdir}/tmp || exit $?
	rm -rf ${workdir}/tmp || exit $?

	buildah unmount $c
	i=$(buildah commit --timestamp=${timestamp} --rm $c ${image}:latest-${arch})
	images="${images} $i"
	clean_workdir ${workdir}
    done
    if buildah manifest exists ${image}:latest; then
	buildah manifest rm ${image}:latest || exit $?
    fi
    buildah manifest create ${image}:latest ${images} || exit $?
}

# usage: build_image <from image> <image name> <tag suffix> <fixup func> packages...
build_image() {
    local from=$1; shift
    local name=$1; shift
    local suffix=$1; shift
    local fixup=$1; shift

    local images=
    local tag=
    local image=$(get_fqin ${name})
    for arch in ${ARCHES}; do
	local abi=$(get_abi ${ver} ${arch})
	local workdir=$(make_workdir ${branch} ${abi})
	tag=$(get_build_version ${workdir})
	c=$(create_container ${workdir} $(get_fqin ${from}):latest-${arch})
	m=$(buildah mount $c)

	echo Generating ${name} for ${arch}
	local timestamp=$(get_build_timestamp ${tag})

	echo Installing packages: "$@"
	install_packages ${workdir} $m "$@" || exit $?

	# Cleanup
	${fixup} $m $c $workdir || exit $?
	env ABI=${abi} ${PKG} --rootdir $m --repo-conf-dir ${workdir}/repos clean -ayq || exit $?

	# We will get some strays since we may have cherry-picked files from
	# runtime in the parent image(s)
	find $m -name '*.pkgsave' | xargs rm

	# Normalise local.sqlite by dumping and restoring
	#sqlite3 $m/var/db/pkg/local.sqlite ".dump" > ${workdir}/local.sql
	#rm -f $m/var/db/pkg/local.sqlite
	#sqlite3 $m/var/db/pkg/local.sqlite ".read ${workdir}/local.sql"

	buildah unmount $c || exit $?
	i=$(buildah commit --timestamp=${timestamp} --rm $c ${image}:latest${suffix}-${arch})
	images="${images} $i"
	clean_workdir ${workdir}
    done
    tagged_image=${image}:${tag}${suffix}
    if buildah manifest exists ${tagged_image}; then
	buildah manifest rm ${tagged_image} || exit $?
    fi
    buildah manifest create ${tagged_image} ${images} || exit $?
    buildah tag ${tagged_image} ${image}:latest${suffix}
}

push_image() {
    local name=$1; shift
    local img=freebsd${ver}-${name}
    local tag=$(podman image inspect localhost/${img}:latest \
	      | jq --raw-output '.[0].Annotations["org.freebsd.version"]')

    echo "Pushing ${REG}/${img}:${tag}"
    buildah manifest push --quiet --all localhost/${img}:latest docker://${REG}/${img}:latest
    buildah manifest push --quiet --all localhost/${img}:latest docker://${REG}/${img}:${tag}
    if buildah manifest exists localhost/${img}:latest-debug; then
	echo "Pushing ${REG}/${img}:${tag}-debug"
	buildah manifest push --quiet --all localhost/${img}:latest-debug docker://${REG}/${img}:latest-debug
	buildah manifest push --quiet --all localhost/${img}:latest-debug docker://${REG}/${img}:${tag}-debug
    fi
}
