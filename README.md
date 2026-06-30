# Z-BOM SBOM Checker (GitHub Action)

PR마다 **git-tracked 소스를 Z-BOM에 제출 → 분석 완료까지 대기 → SBOM/CVE 결과를 PR 코멘트·Job Summary로 보고**하는 composite 액션입니다. 인증은 Z-BOM 발급 **CI 토큰**(`Z_BOM_TOKEN`)을 사용합니다.

## 사용법

`.github/workflows/sbom-checker.yml` ([examples/sbom-checker.yml](examples/sbom-checker.yml)):

```yaml
name: Z-BOM
on: { pull_request: {} }
permissions: { contents: read, pull-requests: write }
jobs:
  sbom_checker:
    runs-on: [self-hosted, zbom]
    steps:
      - uses: actions/checkout@v4
      - uses: zi-en/z-bom-action@v1
        with:
          url: ${{ secrets.Z_BOM_URL }}
          token: ${{ secrets.Z_BOM_TOKEN }}
          type: code
```

### 사전 준비
- **Secret**: `Z_BOM_URL`(사내 Z-BOM 주소), `Z_BOM_TOKEN`(CI/CD 연동 설정 화면에서 발급).
- **러너**: 사내망에서 Z-BOM에 도달 가능한 self-hosted 러너. `curl`·`jq`·`git` 필요.
- **권한**: PR 코멘트를 쓰려면 `permissions: pull-requests: write`.
- `actions/checkout`을 먼저 실행해야 `git archive`로 소스를 패키징할 수 있습니다.

## 입력(inputs)

| 이름 | 기본값 | 설명 |
|---|---|---|
| `url` | (필수) | Z-BOM 서버 주소 |
| `token` | (필수) | Z-BOM CI 토큰 |
| `type` | `code` | 점검 유형 `code` \| `firmware` |
| `path` | `.` | 압축할 소스 경로(git-tracked) |
| `wait` | `true` | 완료까지 대기·보고 |
| `timeout` | `1800` | 최대 대기(초) |
| `poll-interval` | `10` | 상태 폴링 간격(초) |
| `fail-on` | `none` | 해당 심각도 이상 CVE 존재 시 잡 실패: `critical`\|`high`\|`medium`\|`low`\|`none` |
| `comment` | `true` | PR 코멘트 업서트 |
| `github-token` | `${{ github.token }}` | 코멘트 작성용 토큰 |

## 출력(outputs)

| 이름 | 설명 |
|---|---|
| `run-id` | Z-BOM analysis run id |
| `status` | 최종 상태 `COMPLETED`\|`FAILED`\|… |
| `total-cve` | 대응 필요 CVE 수 |
| `result-json` | 결과 요약 JSON 전체 |

## 동작 (Z-BOM API 계약)

1. `git archive`로 추적 소스만 zip (.git·미추적·빌드 산출물 제외).
2. `POST /api/ci/scan` (Token, multipart, `Idempotency-Key: repo:type:commit`) → `analysisRunId`.
   - 같은 커밋 재실행이면 서버가 기존 run을 반환(멱등, 새 버전 안 쌓임).
3. `GET /api/analysis-runs/{id}` 폴링 → `COMPLETED|FAILED` 또는 타임아웃.
4. `GET /api/analysis-runs/{id}/result` → 심각도별 개수·최고위험 CVE·컴포넌트 수.
5. PR 코멘트 업서트(마커로 갱신) + `$GITHUB_STEP_SUMMARY`.
6. `fail-on` 임계 초과 또는 분석 실패 시 잡 실패(exit 1), 그 외 통과.

## 버전 고정
`@v1` 이동 태그를 권장합니다(릴리스마다 `v1` 재지정). 엄격히는 커밋 SHA 고정도 가능합니다.
