#!/usr/bin/env bash
# Tests for the framework verdict reader in render-extensions.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$(mktemp -d)"
trap 'rm -rf "${FIXTURES}"' EXIT

# Only the individual predicates are under test, so each is lifted out of the
# script rather than running the whole sweep. A rename, or a column-zero brace
# inside a body, would otherwise yield an empty or truncated extraction that
# eval accepts in silence, leaving every check that follows it testing a stale
# definition or nothing at all. Fail on the spot instead.
#
# The eval happens here rather than in a command substitution at the call
# site, because `exit` inside `$( )` ends only the subshell: the empty body
# would still reach eval and the run would carry on regardless.
eval_function() {
	local name="$1" body
	body=$(sed -n "/^${name}()/,/^}/p" "${HERE}/../render-extensions.sh")
	if [[ -z "${body}" ]]; then
		printf 'FAIL could not extract %s() from render-extensions.sh\n' "${name}" >&2
		exit 1
	fi
	eval "${body}"
}

eval_function framework_verdict

passed=0
failed=0
check() {
	local description="$1" expected="$2" actual="$3"
	if [[ "${expected}" == "${actual}" ]]; then
		passed=$((passed + 1))
		printf 'ok   %s\n' "${description}"
	else
		failed=$((failed + 1))
		printf 'FAIL %s\n     expected %s, got %s\n' "${description}" "${expected}" "${actual}"
	fi
}

write_fixture() {
	printf '%s' "$2" >"${FIXTURES}/$1.json"
	printf '%s' "${FIXTURES}/$1.json"
}

passing=$(write_fixture passing '{"status":"pass","summary":{"total":3,"pass":3,"fail":0,"skip":0},"layers":{"conformance":{"total":1,"pass":1,"fail":0,"skip":0},"render":{"total":2,"pass":2,"fail":0,"skip":0}}}')
failing=$(write_fixture failing '{"status":"fail","summary":{"total":3,"pass":1,"fail":2,"skip":0},"layers":{"render":{"total":3,"pass":1,"fail":2,"skip":0}}}')
allskip=$(write_fixture allskip '{"status":"skip","summary":{"total":2,"pass":0,"fail":0,"skip":2}}')
# An empty Lua table encodes as an object, not an array, so summary can arrive
# as {} and every field must default rather than read as null.
empty=$(write_fixture empty '{"status":"skip","summary":{}}')

check 'a passing run reports its counts' 'pass	3	3	0	0	2' "$(framework_verdict "${passing}")"
check 'a failing run reports its counts' 'fail	3	1	2	0	3' "$(framework_verdict "${failing}")"
check 'an all-skip run is reported as skip' 'skip	2	0	0	2	0' "$(framework_verdict "${allskip}")"
check 'an empty summary defaults to zeroes' 'skip	0	0	0	0	0' "$(framework_verdict "${empty}")"
check 'a missing file reports none' 'none	0	0	0	0	0' "$(framework_verdict "${FIXTURES}/absent.json")"
check 'unparseable JSON reports none' 'none	0	0	0	0	0' "$(
	write_fixture broken 'not json' >/dev/null
	framework_verdict "${FIXTURES}/broken.json"
)"

# An extension contributing only a project type is the case that matters here.
# generate.lua names a contributed project type as a gap rather than
# half-generating it, so conformance passes, smoke only skips, and the run
# reports pass having rendered nothing at all.
project_only=$(write_fixture project_only '{"status":"pass",
  "summary":{"total":4,"pass":3,"fail":0,"skip":1},
  "layers":{"conformance":{"total":3,"pass":3,"fail":0,"skip":0},
            "smoke":{"total":1,"pass":0,"fail":0,"skip":1}}}')
check 'a run that rendered nothing reports zero rendered' 'pass	4	3	0	1	0' \
	"$(framework_verdict "${project_only}")"

# The framework's JSON is written inside the container by the repository's
# own extension, so a repository can put anything there. Only a bounded enum
# and four integers may reach the published catalogue: a string, a boolean
# and an array must all default to zero rather than travel through @tsv and
# later --argjson into a field the design promises is numeric.
hostile=$(write_fixture hostile '{"status":"pass",
  "summary":{"total":"5","pass":true,"fail":[1,2,3],"skip":0},
  "layers":{"render":{"total":2,"pass":"2","fail":false,"skip":0}}}')
check 'a repository-supplied string, boolean and array default to zero' 'pass	0	0	0	0	0' \
	"$(framework_verdict "${hostile}")"

# The caller never reads framework_verdict through $( ); it reads it through
# `IFS=$'\t' read -r ... < <(framework_verdict ...)`. Command substitution
# strips a missing trailing newline, so a check built on $( ) cannot see a
# fallback that forgets one: it must go through the same process-substitution
# form the caller uses, or the read hitting EOF without a delimiter (and, under
# `set -euo pipefail`, aborting the whole calling function) stays invisible.
missing_read_status=0
IFS=$'\t' read -r missing_status missing_total missing_pass missing_fail missing_skip missing_rendered < <(
	framework_verdict "${FIXTURES}/absent.json"
) || missing_read_status=$?
check 'reading a missing-file verdict through process substitution succeeds' '0' "${missing_read_status}"
check 'a missing-file verdict yields six fields via process substitution' 'none	0	0	0	0	0' \
	"$(printf '%s\t%s\t%s\t%s\t%s\t%s' "${missing_status}" "${missing_total}" "${missing_pass}" "${missing_fail}" "${missing_skip}" "${missing_rendered}")"

eval_function framework_decides

# The framework speaks for an entry only where it actually rendered, and only
# when it reached a verdict. An all-skip run exits 0 and would otherwise be
# read as a clean pass, which is how a layer comes to assert nothing inside a
# run that says PASS.
check 'suite mode with failures is decided by the framework' 'yes' "$(framework_decides suite fail 2 5)"
check 'schema mode with passes is decided by the framework' 'yes' "$(framework_decides schema pass 0 4)"
check 'an all-skip suite run falls back to the render' 'no' "$(framework_decides suite skip 0 0)"
check 'a framework that did not run falls back' 'no' "$(framework_decides suite none 0 0)"
check 'conformance mode never decides the status' 'no' "$(framework_decides conformance fail 3 0)"
check 'render-only mode never decides the status' 'no' "$(framework_decides render-only fail 3 0)"

# The regression this rule exists to prevent. An extension contributing only a
# project type passes conformance and skips its only smoke case, so the run
# reports pass. Taking that verdict would mark the entry green and skip the
# render it gets today, asserting nothing.
check 'a pass that rendered nothing falls back to the render' 'no' \
	"$(framework_decides schema pass 0 0)"

eval_function override_applies

# The framework may add a failure the render missed, but must never erase one
# the render already found: a clone, policy, dependency or render failure is a
# fact about the entry that a later, decoupled probe cannot disprove.
check 'a prior failure is never erased by a framework pass' 'no' \
	"$(override_applies fail schema pass 0 4)"
check 'a prior pass is overridden by the same framework result' 'yes' \
	"$(override_applies pass schema pass 0 4)"

eval_function run_framework

# run_framework's only externally observable action is the docker_run_render
# call it makes, so that call is stubbed here to capture the mount_cache it
# was given rather than run for real: this proves the decision without a
# container. The constants below stand in for the readonly ones
# render-extensions.sh sets at top level, which this eval does not pick up.
# Read by the eval'd run_framework body, which shellcheck cannot see through
# the sed extraction above.
# shellcheck disable=SC2034
FRAMEWORK_DIR="${FIXTURES}/framework"
# shellcheck disable=SC2034
FRAMEWORK_RUNNER="${FRAMEWORK_DIR}/_extensions/extension-test/run.lua"
# shellcheck disable=SC2034
FRAMEWORK_MAX_GENERATED=40
# shellcheck disable=SC2034
FRAMEWORK_TIMEOUT=600

captured_mount_cache=""
captured_root=""
docker_run_render() {
	captured_root="$4"
	captured_mount_cache="$6"
}

run_framework suite "${FIXTURES}/workdir" "${FIXTURES}/logdir" 0 pass
check 'a clean pre-framework status keeps the shared cache in suite mode' 'yes' "${captured_mount_cache}"

# The framework roots at the clone root, which is where detect_test_mode
# looked. Today's render roots at the project path instead, which for a
# project entry is a subdirectory holding neither _extensions/ nor tests/.
# Rooting the framework there would make every such entry probe a tree with
# no extension in it, all-skip, and fall back, while the catalogue published
# a mode the entry could never exercise.
check 'the framework roots at the clone root, not the render directory' \
	"${FIXTURES}/workdir/repo" "${captured_root}"

captured_mount_cache=""
run_framework suite "${FIXTURES}/workdir" "${FIXTURES}/logdir" 0 fail
check 'a policy or dependency failure loses the shared cache in suite mode' 'no' "${captured_mount_cache}"

eval_function framework_runs

# The framework runs only where its verdict can be used. override_applies
# discards the verdict of an entry that already failed, so running it anyway
# executes the code of a repository the pipeline deliberately refused to
# execute, burns a container timeout on a clone that does not exist, and
# publishes case counts from a probe whose result was thrown away.
check 'a passing entry in suite mode runs the framework' 'yes' "$(framework_runs suite pass)"
check 'a passing entry in schema mode runs the framework' 'yes' "$(framework_runs schema pass)"
check 'a render-only entry never runs the framework' 'no' "$(framework_runs render-only pass)"
check 'a failed entry never runs the framework' 'no' "$(framework_runs suite fail)"
check 'a skipped entry never runs the framework' 'no' "$(framework_runs conformance skip)"

eval_function count_renders

# A framework failure sets status="fail" with stage="extension-test", not
# stage="render", even though render_extension had already run the render
# before the framework decided the entry. The count must not drop that entry:
# doing so both under-reports "Rendered N/M" and can trip the "no render was
# executed" error over a batch that failed wholesale through the framework.
extension_test_stage=$(write_fixture extension_test_stage '[{"status":"fail","stage":"extension-test"}]')
clone_stage=$(write_fixture clone_stage '[{"status":"fail","stage":"clone"}]')
check 'an extension-test failure is counted as a render' '1' "$(count_renders "${extension_test_stage}")"
check 'a clone failure is not counted as a render' '0' "$(count_renders "${clone_stage}")"

printf '\n%d checks, %d failed\n' "$((passed + failed))" "${failed}"
[[ "${failed}" -eq 0 ]]
