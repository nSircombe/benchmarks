#!/bin/bash

set -eu
set -o pipefail

basedir="$PWD/OpenFOAM-v1712-TX2-armclang-18.3-OpenMPI-3.0.0"
[ $# -gt 0 ] && basedir="$(readlink -f "$1")"

if [ -d "$basedir" ]; then
    echo "$0: Installation direcotry already exists: $basedir" >&2
    echo "$0: Stop." >&2
    exit 1
fi

mkdir "$basedir"

tgz_of="OpenFOAM-v1712.tgz"
tgz_tp="ThirdParty-v1712.tgz"

if [ ! -f "$tgz_of" ] || [ ! -f "$tgz_tp" ]; then
    echo "$0: Missing source code archives. Have you run fetch.sh?" >&2
    echo "$0: Stop." >&2
    exit 2
fi

echo "Unzipping $tgz_of..."
tar -xf "$tgz_of" -C "$basedir"
echo "Unzipping $tgz_tp..."
tar -xf "$tgz_tp" -C "$basedir"

pushd "$basedir/OpenFOAM-v1712"

bashrc="etc/bashrc"
wmake_gcc="wmake/rules/linuxARM64Gcc"
wmake_arm="wmake/rules/linuxARM64Arm"
csettings="${wmake_arm}/c"
cppsettings="${wmake_arm}/c++"
cflags="${wmake_arm}/cOpt"
cppflags="${wmake_arm}/c++Opt"

if [ ! -f "$bashrc" ]; then
    echo "$0: File does not exist: $PWD/$bashrc" >&2
    echo "$0: Stop." >&2
    exit 3
fi

# Use the GNU compiler (best performance) and OpenMPI (default MPI setting, so easiest to build)
# The MPI library does not affect performance on a single node
module purge
module load arm/hpc-compiler/18.3 openmpi/3.0.0/arm-18.3

# Set the installtion directory path
sed -i 's,^FOAM_INST_DIR=.*,FOAM_INST_DIR='"$PWD," "$bashrc"

# Set the compiler and flags
cp -r "$wmake_gcc" "$wmake_arm"
sed -i 's/^cc          =.*/cc          = armclang/' "$csettings"
sed -i 's/^CC          =.*/CC          = armclang++ -std=c++11/' "$cppsettings"
sed -i 's/^export WM_COMPILER=.*/export WM_COMPILER=Arm/' "$bashrc"
sed -i 's/^cOPT        =.*/cOPT        = -march=armv8.1-a -mtune=thunderx2t99 -O3 -ffast-math/' "$cflags"
sed -i 's/^c++OPT      =.*/c++OPT      = -march=armv8.1-a -mtune=thunderx2t99 -O3 -ffast-math/' "$cppflags"
cat >>"$cppflags" <<EOF
# Suppress some warnings for flex++ and CGAL
c++LESSWARN = -Wno-old-style-cast -Wno-unused-local-typedefs -Wno-array-bounds -fpermissive
EOF

# Apply required source changes: https://gitlab.com/arm-hpc/packages/wikis/packages/openfoamplus
( cd src/finiteVolume/finiteVolume/ddtSchemes/CrankNicolsonDdtScheme/;
cat <<EOPATCH | patch -p1
--- a/CrankNicolsonDdtScheme.C
+++ b/CrankNicolsonDdtScheme.C
@@ -101,7 +101,7 @@ operator=(const GeoField& gf)

 template<class Type>
 template<class GeoField>
-CrankNicolsonDdtScheme<Type>::DDt0Field<GeoField>&
+typename CrankNicolsonDdtScheme<Type>::template DDt0Field<GeoField>&
 CrankNicolsonDdtScheme<Type>::ddt0_
 (
     const word& name,

EOPATCH
)

set +e +u
source "$bashrc"

# Additional flag changes: enable parallel compilation
export WM_NCOMPPROCS=64

time ./Allwmake |& tee build.log

# If the build fails with 'too many open files' error, try again with a single thread
if [ "$(grep -c 'open files' build.log)" -gt 0 ]; then
    echo "Got 'Too many open files errors. Retrying build with a single parallel job..."
    export WM_NCOMPPROCS=1
    time ./Allwmake |& tee build_1proc.log
fi

# Create a test case directory if the files are available (and the directory doesn't exist already)
popd
testdir="run/block_DrivAer_small-tx2"
if [ -d "$testdir" ]; then
    echo "Test directory already exists: $testdir"
elif [ -f OpenFOAM-v1712-block_DrivAer_small.tar.gz ]; then
    mkdir -p "$testdir"
    tar -xf OpenFOAM-v1712-block_DrivAer_small.tar.gz -C "$testdir" --strip-components 1
elif [ -d OpenFOAM-v1712-block_DrivAer_small ]; then
    mkdir -p "$testdir"
    cp -r OpenFOAM-v1712-block_DrivAer_small "$testdir"
else
    echo "$0: Test case direcotry not available. Have you run fetch.sh?" >&2
    exit 4
fi

echo "Done."

