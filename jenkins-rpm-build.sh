#!/bin/bash

# match nothing when glob does not matches any file
shopt -s nullglob

usage() {
	echo "Usage: $0 [-m <mock config>] [-s] [-d] <file.spec>" 1>&2
	echo "Build RPMs for the given .spec file"
	echo
	echo "   -m,  --mock <mock_config>	the mock environment to use for the build"
	echo "   -s,  --snap			create a snapshot RPM"
	echo "   -d,  --debug			enable debug features, such as retaining the mock environment after a build failure"
	echo
	exit 1
}

# process options
GETOPT=$(getopt -o 'm:sk' -l 'mock:,snap,debug' -n "$0" -- "$@")

if [ $? -ne 0 ]; then
	usage
	exit 1
else
	eval set -- "$GETOPT"
	while true; do
	case "$1" in
		-m|--mock)
			MOCK_BUILDER="$2"
			shift 2
			break
			;;
		-s|--snap)
			SNAP_BUILD=1
			shift
			break
			;;
		-d|--debug)
			DEBUG=1
			KEEP_MOCK_ENV=1
			shift
			break
			;;
		--)
			# no arguments
			usage
			exit 1
			;;
	esac
	done
	shift
fi

MOCK_BUILDER_EL5=epel-5-x86_64
MOCK_BUILDER_EL6=epel-6-x86_64
if [ -z $MOCK_BUILDER ]; then
	MOCK_BUILDER="epel-6-x86_64"
fi

# spec file
spec_file=$1
if [ ! -f $spec_file ]; then
	echo "Error: could not open spec file: $spec_file"
fi


###
### WHAT PACKAGE IS THIS?
###
name="$(rpm -q --queryformat="%{name}\n" --specfile $spec_file | head -n 1)"

if [ -z $name ]; then
	echo "ERROR: could not determine package name"
	exit 1
fi


###
### WHAT VERSION IS THIS?
###

if grep -i '^Version:.*@@version@@' 1>/dev/null; then
	# look up version from git tags
	tag="$(git describe --abbrev=0 || true)"
	tagversion=$(echo $tag | sed 's|.*-\([0-9\.]*\)$|\1|')
	version=${tagversion}
	sed -r -i -e 's/@@version@@/'"$version"'/g' $spec_file
fi

version="$(rpm -q --queryformat="%{version}\n" --specfile $spec_file | head -n 1)"

if [ -z $version ]; then
	echo "ERROR: could not determine package version"
	exit 1
fi


###
### WHAT RELEASE IS THIS?
###
if grep -i '^Version:.*@@version@@' 1>/dev/null; then
	# look up release from git tags
	$lastrelease=$(git tag -l | sort --version-sort | tac | grep -m 1 "rpm-release-$version" | sed 's|.*-\([0-9]*\)$|\1|')
	if [ -z $lastrelease ]; then
		# this is the first release of this version
		$release=1
	else
		# increment release counter
		$release=$[release + 1]
	fi
	sed -r -i -e 's/@@release@@/'"$release"'/g' $spec_file
fi

release="$(rpm -q --queryformat="%{release}\n" --specfile $spec_file | head -n 1 | sed 's|^\([0-9]*\).*$|\1|')"

if [ -z $release ]; then
	echo "ERROR: could not determine package release"
	exit 1
fi

if git tag | grep "^rpm-release-${version}-${release}"; then
	echo "ERROR: rpm-release-${version}-${release} tag already exists"
	exit 1
fi


###
### Finalise spec file
###
echo
echo ":::::"
echo "::::: Package Name:    $name"
echo "::::: Package Version: $version"
echo "::::: Package Release: $release"
echo ":::::"

# Make the build number available (eg. 24)
sed -i "s|@@BUILD_NUMBER@@|$BUILD_NUMBER|g" $spec_file

# Make the build tag available (eg. jenkins-rpm-apache-maven-rpm-release-24)
sed -i "s|@@BUILD_TAG@@|$BUILD_TAG|g" $spec_file

# Make the build url available (eg. http://jenkins-ci:8080/jenkins/job/rpm-apache-maven-rpm-release/24/)
sed -i "s|@@BUILD_URL@@|$BUILD_URL|g" $spec_file

# Make the job name available (eg. rpm-apache-maven-rpm-release)
sed -i "s|@@JOB_NAME@@|$JOB_NAME|g" $spec_file

### Check the spec file for syntax/style errors
/usr/bin/rpmlint $spec_file


###
### PREP SOURCES
###
source0=$(spectool -l $spec_file | grep '^Source0:' | cut -d: -f2- | tr -d ' ')
source0=$(basename $source0)

if [ ! -f $source0 ]; then
	echo
	echo
        echo ":::::"
        echo "::::: building upstream source archive from vcs repo"
        echo ":::::"

        filesuffix=${source0/${name}-${version}}

        if [[ "$filesuffix" =~ tar.gz$ ]] || [[ "$filesuffix" =~ tgz$ ]]; then
                echo "making tar.gz called ${name}-${version}${filesuffix}"
                git archive --format=tar --prefix="${name}-${version}/" -o ${name}-${version}.tar HEAD
                gzip ${name}-${version}.tar
                mv -f ${name}-${version}.tar.gz ${name}-${version}${filesuffix} || true

        elif [[ "$filesuffix" =~ tar.bz2$ ]]; then
                echo "making bz2 called ${name}-${version}${filesuffix}"
                git archive --format=tar --prefix="${name}-${version}/" -o ${name}-${version}.tar HEAD
                bzip2 ${name}-${version}.tar
                mv -f ${name}-${version}.tar.bz2 ${name}-${version}${filesuffix} || true

        elif [[ "$filesuffix" =~ tar$ ]]; then
                echo "making tar called ${name}-${version}${filesuffix}"
                git archive --format=tar --prefix="${name}-${version}/" -o ${name}-${version}${filesuffix} HEAD

                elif [[ "$filesuffix" =~ zip$ ]]; then
                echo "making zip called ${name}-${version}${filesuffix}"
                git archive --format=zip --prefix="${name}-${version}/" -o ${name}-${version}${filesuffix} HEAD

        else
                echo "failed to make archive"
        fi
fi


##
## SNAP
##
## we need to repackage the archive so that its first folder is <version>-<snap>
## not sure if we should do that as part of making the archive, because we don't always do that
## and we need to re-package supplied archives anyway
##
if [ "$SNAP_BUILD" ]; then
	# example: collectd-5.4.1.snap.20130116.161144.git.041ef6c
	snapsuffix="snap.$(date +%F_%T | tr -d .:- | tr _ .).git.$(git log -1 --pretty=format:%h)"

	# add snapshot suffix to the version in the spec file
	sed -r -i -e '/^Version:/s/\s*$/'".$snapsuffix/" $spec_file

	# rename upstream source0 archive to match new version
	mv ${name}-${version}${filesuffix} ${name}-${version}.${snapsuffix}${filesuffix}

	echo
	echo
        echo ":::::"
        echo "::::: building snapshot release: ${name}-${version}.${snapsuffix}"
        echo ":::::"
fi


###
### BUILD!
###
# clean mock environment before builds and tests
#mock -r ${MOCK_BUILDER} --clean

# mock configuration
mock_cmd='/usr/bin/mock'
case "$MOCK_BUILDER" in
        $MOCK_BUILDER_EL5)
                pkg_dist_suffix=".el5"
                mock_cmd="$mock_cmd -D \"_source_filedigest_algorithm 1\""
                mock_cmd="$mock_cmd -D \"_binary_filedigest_algorithm 1\""
                mock_cmd="$mock_cmd -D \"_binary_payload w9.gzdio\""
                ;;
        $MOCK_BUILDER_EL6)
                pkg_dist_suffix=".el6"
                ;;
        *)
                pkg_dist_suffix=""
                ;;
esac


echo
echo
echo ":::::"
echo "::::: building source RPM"
echo ":::::"
rm -f SRPMS/*.src.rpm
rpmbuild -bs --define '%_topdir '"`pwd`" --define '%_sourcedir %{_topdir}' --define "%dist $pkg_dist_suffix" --define "_source_filedigest_algorithm md5" --define "_binary_filedigest_algorithm md5" $spec_file
#sample output: Wrote: /tmp/rctc-repo/SRPMS/rctc-1.10-0.el6.src.rpm

if [ ! -f "SRPMS/${name}-${version}${filesuffix}" ] && [ ! -f "${name}-${version}.${snapsuffix}${filesuffix}" ]; then
	echo "Error: no .src.rpm found."
	exit 1
fi


echo
echo
echo ":::::"
echo "::::: building in mock"
echo ":::::"

# target directory
resultdir="repo/$MOCK_BUILDER"
rm -rf $resultdir
mkdir -p $resultdir

# build
eval $mock_cmd -r $MOCK_BUILDER ${KEEP_MOCK_ENV:+--no-cleanup-after} --resultdir \"$resultdir\" -D \"dist $pkg_dist_suffix\" SRPMS/*.src.rpm


echo
echo
echo ":::::"
echo "::::: the following RPMs were built"
echo ":::::"
find -name '*.rpm'


###
### CREATE REPO
###
# create repo files
echo
echo
echo ":::::"
echo "::::: generating repofiles: $resultdir"
echo ":::::"

case "$MOCK_BUILDER" in
        $MOCK_BUILDER_EL5)
                createrepo -s sha $resultdir
                ;;
        *)
                createrepo $resultdir
                ;;
esac

echo "
[${JOB_NAME}-${MOCK_BUILDER}]
name=CI build of ${JOB_NAME} on ${MOCK_BUILDER} builder
enabled=1
gpgcheck=0
baseurl=${JOB_URL}/ws/${resultdir}/
" > $resultdir/${JOB_NAME}-${resultdir#repo/}.repo

echo
echo
echo ":::::"
echo "::::: yum repository configuration"
echo ":::::"
cat $resultdir/${JOB_NAME}-${resultdir#repo/}.repo

echo
echo
echo ":::::"
echo "::::: DONE"
echo ":::::"
