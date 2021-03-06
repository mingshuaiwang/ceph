#!/usr/bin/env bash

set -x

die() {
    echo "$@"
    exit 1
}

do_run() {
    if [ "$1" == "--tee" ]; then
      shift
      tee_out="$1"
      shift
      "$@" | tee $tee_out
    else
      "$@"
    fi
}

run_expect_succ() {
    echo "RUN_EXPECT_SUCC: " "$@"
    do_run "$@"
    [ $? -ne 0 ] && die "expected success, but got failure! cmd: $@"
}

run() {
    echo "RUN: " $@
    do_run "$@"
}

if [ -n "$CEPH_BIN" ] ; then
   # CMake env
   RADOS_TOOL="$CEPH_BIN/rados"
   CEPH_TOOL="$CEPH_BIN/ceph"
   DEDUP_TOOL="$CEPH_BIN/ceph-dedup-tool"
else
   # executables should be installed by the QA env 
   RADOS_TOOL=$(which rados)
   CEPH_TOOL=$(which ceph)
   DEDUP_TOOL=$(which ceph-dedup-tool)
fi

POOL=dedup_pool
OBJ=test_rados_obj

[ -x "$RADOS_TOOL" ] || die "couldn't find $RADOS_TOOL binary to test"
[ -x "$CEPH_TOOL" ] || die "couldn't find $CEPH_TOOL binary to test"

run_expect_succ "$CEPH_TOOL" osd pool create "$POOL" 8

function test_dedup_ratio_fixed()
{
  # case 1
  dd if=/dev/urandom of=dedup_object_1k bs=1K count=1
  dd if=dedup_object_1k of=dedup_object_100k bs=1K count=100

  $RADOS_TOOL -p $POOL put $OBJ ./dedup_object_100k
  RESULT=$($DEDUP_TOOL --op estimate --pool $POOL --chunk-size 1024  --chunk-algorithm fixed --fingerprint-algorithm sha1 --debug | grep result | awk '{print$4}')
  if [ 1024 -ne $RESULT ];
  then
    die "Estimate failed expecting 1024 result $RESULT"
  fi

  # case 2
  dd if=/dev/zero of=dedup_object_10m bs=10M count=1

  $RADOS_TOOL -p $POOL put $OBJ ./dedup_object_10m
  RESULT=$($DEDUP_TOOL --op estimate --pool $POOL --chunk-size 4096  --chunk-algorithm fixed --fingerprint-algorithm sha1 --debug | grep result | awk '{print$4}')
  if [ 4096 -ne $RESULT ];
  then
    die "Estimate failed expecting 4096 result $RESULT"
  fi

  # case 3 max_thread
  for num in `seq 0 20`
  do
    dd if=/dev/zero of=dedup_object_$num bs=4M count=1
    $RADOS_TOOL -p $POOL put dedup_object_$num ./dedup_object_$num
  done

  RESULT=$($DEDUP_TOOL --op estimate --pool $POOL --chunk-size 4096  --chunk-algorithm fixed --fingerprint-algorithm sha1 --max-thread 4 --debug | grep result | awk '{print$2}')

  if [ 98566144 -ne $RESULT ];
  then
    die "Estimate failed expecting 98566144 result $RESULT"
  fi

  rm -rf ./dedup_object_1k ./dedup_object_100k ./dedup_object_10m
  for num in `seq 0 20`
  do
    rm -rf ./dedup_object_$num
  done
  $RADOS_TOOL -p $POOL rm $OBJ 
  for num in `seq 0 20`
  do
    $RADOS_TOOL -p $POOL rm dedup_object_$num
  done
}

function test_dedup_chunk_scrub()
{

  CHUNK_POOL=dedup_chunk_pool
  run_expect_succ "$CEPH_TOOL" osd pool create "$CHUNK_POOL" 8

  echo "hi there" > foo

  echo "hi there" > bar
 
  echo "there" > foo-chunk

  echo "CHUNK" > bar-chunk
  
  $CEPH_TOOL osd pool set $POOL fingerprint_algorithm sha1 --yes-i-really-mean-it

  $RADOS_TOOL -p $POOL put foo ./foo
  $RADOS_TOOL -p $POOL put bar ./bar

  $RADOS_TOOL -p $CHUNK_POOL put bar-chunk ./bar-chunk
  $RADOS_TOOL -p $CHUNK_POOL put foo-chunk ./foo-chunk

  $RADOS_TOOL -p $POOL set-chunk bar 0 8 --target-pool $CHUNK_POOL bar-chunk 0 --with-reference
  $RADOS_TOOL -p $POOL set-chunk foo 0 8 --target-pool $CHUNK_POOL foo-chunk 0 --with-reference

  echo "There hi" > test_obj
  # dirty
  $RADOS_TOOL -p $POOL put foo ./test_obj
  # flush
  $RADOS_TOOL -p $POOL put foo ./test_obj
  sleep 2

  rados ls -p $CHUNK_POOL
  CHUNK_OID=$(echo -n "There hi" | sha1sum)

  POOL_ID=$(ceph osd pool ls detail | grep $POOL |  awk '{print$2}')
  $DEDUP_TOOL --op add-chunk-ref --chunk-pool $CHUNK_POOL --object $CHUNK_OID --target-ref bar --target-ref-pool-id $POOL_ID
  RESULT=$($DEDUP_TOOL --op get-chunk-ref --chunk-pool $CHUNK_POOL --object $CHUNK_OID)

  $DEDUP_TOOL --op chunk-scrub --chunk-pool $CHUNK_POOL

  RESULT=$($DEDUP_TOOL --op get-chunk-ref --chunk-pool $CHUNK_POOL --object $CHUNK_OID | grep bar)
  if [ -n "$RESULT" ] ; then
    $CEPH_TOOL osd pool delete $POOL $POOL --yes-i-really-really-mean-it
    $CEPH_TOOL osd pool delete $CHUNK_POOL $CHUNK_POOL --yes-i-really-really-mean-it
    die "Scrub failed expecting bar is removed"
  fi

  $CEPH_TOOL osd pool delete $CHUNK_POOL $CHUNK_POOL --yes-i-really-really-mean-it
  
  rm -rf ./foo ./bar ./foo-chunk ./bar-chunk ./test_obj
  $RADOS_TOOL -p $POOL rm foo
  $RADOS_TOOL -p $POOL rm bar
}

function test_dedup_ratio_rabin()
{
  # case 1
  echo "abcdefghijklmnop" >> dedup_16
  for num in `seq 0 63`
  do
    dd if=./dedup_16  bs=16 count=1 >> dedup_object_1k
  done

  for num in `seq 0 11`
  do
    dd if=dedup_object_1k bs=1K count=1 >> test_rabin_object
  done
  $RADOS_TOOL -p $POOL put $OBJ ./test_rabin_object
  RESULT=$($DEDUP_TOOL --op estimate --pool $POOL --min-chunk 1015  --chunk-algorithm rabin --fingerprint-algorithm rabin --debug | grep result -a | awk '{print$4}')
  if [ 4096 -ne $RESULT ];
  then
    die "Estimate failed expecting 4096 result $RESULT"
  fi

  echo "a" >> test_rabin_object_2
  dd if=./test_rabin_object bs=8K count=1 >> test_rabin_object_2
  $RADOS_TOOL -p $POOL put $OBJ"_2" ./test_rabin_object_2
  RESULT=$($DEDUP_TOOL --op estimate --pool $POOL --min-chunk 1012 --chunk-algorithm rabin --fingerprint-algorithm rabin --debug | grep result -a | awk '{print$4}')
  if [ 11259 -ne $RESULT ];
  then
    die "Estimate failed expecting 11259 result $RESULT"
  fi

  RESULT=$($DEDUP_TOOL --op estimate --pool $POOL --min-chunk 1024 --chunk-mask-bit 3  --chunk-algorithm rabin --fingerprint-algorithm rabin --debug | grep result -a | awk '{print$4}')
  if [ 7170 -ne $RESULT ];
  then
    die "Estimate failed expecting 7170 result $RESULT"
  fi

  rm -rf ./dedup_object_1k ./test_rabin_object ./test_rabin_object_2 ./dedup_16

}

test_dedup_ratio_fixed
test_dedup_chunk_scrub
test_dedup_ratio_rabin

$CEPH_TOOL osd pool delete $POOL $POOL --yes-i-really-really-mean-it

echo "SUCCESS!"
exit 0


