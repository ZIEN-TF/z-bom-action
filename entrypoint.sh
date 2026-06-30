#!/usr/bin/env bash
#
# Z-BOM SBOM Checker — composite action entrypoint.
# git-tracked 소스를 Z-BOM에 제출하고, 완료까지 폴링한 뒤 결과를 PR 코멘트/Job Summary로 보고한다.
#
set -euo pipefail

err() { echo "::error::z-bom: $*" >&2; }
info() { echo "z-bom: $*"; }

for cmd in curl jq git; do
  command -v "$cmd" >/dev/null 2>&1 || { err "'$cmd' not found on runner"; exit 1; }
done

URL="${ZBOM_URL%/}"
[ -n "$URL" ] && [ -n "${ZBOM_TOKEN:-}" ] || { err "url/token are required"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ARC="$TMP/source.zip"

# 1) git-tracked 소스만 zip (.git·미추적·빌드 산출물 제외)
info "archiving git-tracked source (path=${ZBOM_PATH:-.})"
if [ "${ZBOM_PATH:-.}" = "." ]; then
  git archive --format=zip -o "$ARC" HEAD
else
  git archive --format=zip -o "$ARC" HEAD -- "$ZBOM_PATH"
fi

# 2) 제출 (멱등키 = repo:type:commit → 같은 커밋 재실행 시 새 점검을 만들지 않음)
IDEM="${ZBOM_REPO}:${ZBOM_TYPE}:${ZBOM_COMMIT}"
info "submitting → $URL/api/ci/scan (repo=$ZBOM_REPO type=$ZBOM_TYPE commit=${ZBOM_COMMIT:0:8})"
submit="$(curl -fsS -X POST "$URL/api/ci/scan" \
  -H "Authorization: Token $ZBOM_TOKEN" \
  -H "Idempotency-Key: $IDEM" \
  -F source=GITHUB \
  -F "repo=$ZBOM_REPO" \
  -F "type=$ZBOM_TYPE" \
  -F "commit=$ZBOM_COMMIT" \
  -F "branch=$ZBOM_BRANCH" \
  -F "trigger=$ZBOM_TRIGGER" \
  -F "file=@$ARC")" || { err "submit failed"; exit 1; }

RID="$(echo "$submit" | jq -r '.analysisRunId // empty')"
[ -n "$RID" ] || { err "no analysisRunId in response: $submit"; exit 1; }
info "analysis run: $RID (idempotent=$(echo "$submit" | jq -r '.idempotent // false'))"

if [ "${ZBOM_WAIT:-true}" != "true" ]; then
  info "wait=false → skip polling"
  { echo "run-id=$RID"; echo "status=SUBMITTED"; } >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# 3) 완료까지 폴링
deadline=$(( $(date +%s) + ${ZBOM_TIMEOUT:-1800} ))
STATUS="UNKNOWN"
while :; do
  run="$(curl -fsS "$URL/api/analysis-runs/$RID" -H "Authorization: Token $ZBOM_TOKEN")" \
    || { err "poll request failed"; break; }
  STATUS="$(echo "$run" | jq -r '.status // "UNKNOWN"')"
  info "status=$STATUS"
  case "$STATUS" in COMPLETED|FAILED) break ;; esac
  if [ "$(date +%s)" -ge "$deadline" ]; then err "timeout after ${ZBOM_TIMEOUT}s (status=$STATUS)"; break; fi
  sleep "${ZBOM_POLL_INTERVAL:-10}"
done

# 4) 결과 요약
RESULT="$(curl -fsS "$URL/api/analysis-runs/$RID/result" -H "Authorization: Token $ZBOM_TOKEN" || echo '{}')"
crit=$(echo "$RESULT" | jq -r '.cveSeverity.CRITICAL // 0')
high=$(echo "$RESULT" | jq -r '.cveSeverity.HIGH // 0')
med=$(echo "$RESULT"  | jq -r '.cveSeverity.MEDIUM // 0')
low=$(echo "$RESULT"  | jq -r '.cveSeverity.LOW // 0')
total=$(echo "$RESULT" | jq -r '.totalCve // 0')
sbom=$(echo "$RESULT" | jq -r '.sbomCount // 0')
riskCve=$(echo "$RESULT" | jq -r '.riskCve // empty')
riskSev=$(echo "$RESULT" | jq -r '.riskSeverity // empty')
riskScore=$(echo "$RESULT" | jq -r '.riskScore // empty')

# 마크다운 본문(업서트용 마커 포함)
marker="<!-- z-bom-action -->"
icon="✅"; [ "$STATUS" = "FAILED" ] && icon="❌"
body="$marker
## $icon Z-BOM SBOM 점검 · \`$STATUS\`

**컴포넌트(SBOM)** $sbom · **대응 필요 CVE** $total

| 심각도 | Critical | High | Medium | Low |
|---|---|---|---|---|
| 개수 | $crit | $high | $med | $low |"
if [ -n "$riskCve" ]; then
  body="$body

**최고 위험**: \`$riskCve\` ($riskSev${riskScore:+ · CVSS $riskScore})"
fi
body="$body

<sub>repo \`$ZBOM_REPO\` · commit \`${ZBOM_COMMIT:0:8}\` · run \`$RID\`</sub>"

# Job Summary
echo "$body" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# 5) PR 코멘트 업서트 (마커로 기존 코멘트 찾아 갱신, 없으면 생성)
if [ "${ZBOM_COMMENT:-true}" = "true" ] && [ -n "${ZBOM_PR:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  repo_api="${GITHUB_API_URL:-https://api.github.com}/repos/$ZBOM_REPO"
  cid="$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    "$repo_api/issues/$ZBOM_PR/comments?per_page=100" \
    | jq -r --arg m "$marker" 'map(select(.body|contains($m)))|.[0].id // empty')" || cid=""
  payload="$(jq -n --arg b "$body" '{body:$b}')"
  if [ -n "$cid" ]; then
    curl -fsS -X PATCH -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      "$repo_api/issues/comments/$cid" -d "$payload" >/dev/null && info "updated PR comment #$cid"
  else
    curl -fsS -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      "$repo_api/issues/$ZBOM_PR/comments" -d "$payload" >/dev/null && info "created PR comment"
  fi
fi

# outputs
{
  echo "run-id=$RID"
  echo "status=$STATUS"
  echo "total-cve=$total"
  echo "result-json<<__ZBOM__"
  echo "$RESULT"
  echo "__ZBOM__"
} >> "${GITHUB_OUTPUT:-/dev/null}"

# 6) 게이팅
if [ "$STATUS" = "FAILED" ]; then err "analysis failed"; exit 1; fi
case "${ZBOM_FAIL_ON:-none}" in
  critical) gate=$crit ;;
  high) gate=$((crit + high)) ;;
  medium) gate=$((crit + high + med)) ;;
  low) gate=$((crit + high + med + low)) ;;
  *) gate=0 ;;
esac
if [ "${ZBOM_FAIL_ON:-none}" != "none" ] && [ "$gate" -gt 0 ]; then
  err "fail-on=$ZBOM_FAIL_ON matched $gate CVE(s)"; exit 1
fi
info "done"
