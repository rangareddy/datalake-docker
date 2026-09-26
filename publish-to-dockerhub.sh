#!/bin/bash
# Push every locally built rangareddy1988/ranga-* image to Docker Hub.
#
# Publishing is gated on demos/e2e_test.sh. That script writes .e2e-passed on a fully
# green run, listing the ID of every ranga-* image that was live at the time; this one
# refuses to push an image whose current ID is not in that list. Rebuilding a Dockerfile
# changes the image ID, so "edited a Dockerfile and pushed without retesting" fails here
# instead of reaching whoever pulls the image next.
#
#   ./docker_build/build_docker_images.sh
#   sh docker_run/run_datalake.sh restart
#   ./demos/e2e_test.sh
#   ./publish-to-dockerhub.sh
#
# E2E_OVERRIDE=1 skips the gate. It exists for the case where the stack cannot be run at
# all on this machine; it is not the normal path and it says so on the way past.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DOCKER_HUB_USERNAME="${DOCKER_HUB_USERNAME:-rangareddy1988}"
ATTEST="$REPO_DIR/.e2e-passed"
# One stack version, so one tag pair per image. Scoping to it means a stale tag left
# over from an older build is not pushed along with the current set.
IMAGE_VERSION="${IMAGE_VERSION:-1.0.0}"

image_list="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
	| grep -E "/ranga-[a-z0-9-]+:($IMAGE_VERSION|latest) " | sort)"
if [ -z "$image_list" ]; then
	echo "No rangareddy1988/ranga-* images tagged $IMAGE_VERSION. Run ./docker_build/build_docker_images.sh first."
	exit 0
fi

# ---------------------------------------------------------------- the gate
if [ "${E2E_OVERRIDE:-0}" = "1" ]; then
	echo "!! E2E_OVERRIDE=1: publishing without a green end-to-end run."
elif [ ! -f "$ATTEST" ]; then
	cat >&2 <<-MSG
		Refusing to publish: no record of a green end-to-end run.

		  sh docker_run/run_datalake.sh restart
		  ./demos/e2e_test.sh

		That writes .e2e-passed once every check passes. Set E2E_OVERRIDE=1 to bypass.
	MSG
	exit 1
else
	echo "Gate: $(sed -n '2p' "$ATTEST" | sed 's/^# //')"
	untested=""
	while read -r ref id; do
		grep -qx "$ref $id" "$ATTEST" || untested="$untested\n  $ref ($id)"
	done <<<"$image_list"
	if [ -n "$untested" ]; then
		# shellcheck disable=SC2059
		printf "Refusing to publish. These images were built or rebuilt after the last green run:$untested\n\nRe-run demos/e2e_test.sh, or set E2E_OVERRIDE=1 to bypass.\n" >&2
		exit 1
	fi
	echo "Gate: every image to be pushed was exercised by that run."
fi

# ---------------------------------------------------------------- push
failed=0
while read -r ref _id; do
	echo "Pushing $ref ..."
	docker push "$ref" || {
		echo "Error pushing $ref" >&2
		failed=1
	}
done <<<"$image_list"

[ "$failed" -eq 0 ] || exit 1
echo "Publishing process complete."
