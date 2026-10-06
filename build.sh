#!/usr/bin/env bash


# rols: ROLS_TEST_TIMEOUT=SECONDS bounds odin test for test and single_test; unset means no limit.
# odin test runs in its own process group, and on timeout the whole group gets SIGKILL, so the tests binary that
# odin test starts dies too. INT, TERM, HUP and QUIT are passed on to the group. The exit status is 124 on timeout.
# Set it lower than any outer timeout (GNU timeout, a CI cancel, an agent tool limit): an outer kill of the
# build.sh process group does not reach the test group, and a SIGKILL of perl leaves the tests running.
rols_odin_test() {
    if [[ -z $ROLS_TEST_TIMEOUT ]]; then
        odin test "$@"
        return
    fi
    if [[ ! $ROLS_TEST_TIMEOUT =~ ^[1-9][0-9]*$ ]]; then
        echo "ROLS_TEST_TIMEOUT must be a whole number of seconds above 0, not '$ROLS_TEST_TIMEOUT'" >&2
        return 2
    fi
    perl -e '
        my $timeout = shift;
        defined(my $pid = fork) or die "fork: $!\n";
        if ($pid == 0) {
            setpgrp(0, 0);
            exec @ARGV or die "exec $ARGV[0]: $!\n";
        }
        setpgrp($pid, $pid);
        my $timed_out = 0;
        $SIG{$_} = sub { kill $_[0], -$pid } for qw(INT TERM HUP QUIT);
        $SIG{ALRM} = sub {
            $timed_out = 1;
            print STDERR "odin test ran longer than ROLS_TEST_TIMEOUT=$timeout s; killed its process group\n";
            kill "KILL", -$pid;
        };
        alarm $timeout;
        waitpid($pid, 0);
        my $status = $?;
        alarm 0;
        exit 124 if $timed_out;
        exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
    ' "$ROLS_TEST_TIMEOUT" odin test "$@"
}

if [[ $1 == "single_test" ]]
then
    shift

    #BUG in odin test, it makes the executable with the same name as a folder and gets confused.
    cd tests

    # rols: odin test under the optional ROLS_TEST_TIMEOUT
    rols_odin_test ../tests -collection:src=../src -define:ODIN_TEST_NAMES="$@" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

    if ([ $? -ne 0 ])
    then
        echo "Test failed"
        exit 1
    fi

	exit 0
fi

if [[ $1 == "test" ]]
then
    shift

    #BUG in odin test, it makes the executable with the same name as a folder and gets confused.
    cd tests

    # rols: odin test under the optional ROLS_TEST_TIMEOUT
    rols_odin_test ../tests -collection:src=../src "$@" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

    if ([ $? -ne 0 ])
    then
        echo "Test failed"
        exit 1
    fi

	exit 0
fi

if [[ $1 == "build_test" ]]
then
    shift

    #BUG in odin test, it makes the executable with the same name as a folder and gets confused.
    cd tests

    odin build ../tests -build-mode:test -collection:src=../src "$@" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

    if ([ $? -ne 0 ])
    then
        echo "Build failed"
        exit 1
    fi

	exit 0
fi

if [[ -z "$OLS_VERSION" ]]; then
	OLS_VERSION="dev-$(date -u '+%Y-%m-%d')-$(git rev-parse --short HEAD)"
fi

echo "OLS_VERSION=$OLS_VERSION"

if [[ $1 == "release" ]]
then
    shift

    odin build src/ -show-timings -collection:src=src -out:ols -no-bounds-check -o:speed -define:VERSION=$OLS_VERSION "$@"
    exit 0
fi

if [[ $1 == "debug" ]]
then
    shift

    odin build src/ -show-timings -collection:src=src -out:ols -microarch:native -no-bounds-check -use-separate-modules -define:VERSION=$OLS_VERSION-debug -debug "$@"
    exit 0
fi

odin build src/ -show-timings -collection:src=src -out:ols -microarch:native -no-bounds-check -o:speed -define:VERSION=$OLS_VERSION "$@"
