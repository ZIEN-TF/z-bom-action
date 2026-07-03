# Z-BOM SBOM Checker (GitHub Action)

> **English**: Submits your git-tracked source to a **self-hosted (on-premises) Z-BOM instance** for SBOM/CVE analysis and reports the results as a PR comment / Job Summary. This action is a *client* for Z-BOM — it requires a Z-BOM deployment reachable from your runner and does **not** work standalone.

PR마다 **git-tracked 소스를 Z-BOM에 제출 → 분석 완료까지 대기 → SBOM/CVE 결과를 PR 코멘트·Job Summary로 보고**하는 composite 액션입니다. 인증은 Z-BOM 발급 **CI 토큰**(`Z_BOM_TOKEN`)을 사용합니다.

> ⚠️ **온프레미스 Z-BOM 서비스가 필요합니다.** 이 액션은 사내(온프레미스) 환경에 구축된 Z-BOM 서비스를 호출하는 **클라이언트**입니다. Z-BOM 서버 없이는 동작하지 않습니다. 소스 아카이브는 여러분이 `url`로 지정한 Z-BOM 서버로만 전송되며, 그 외 외부 서비스로는 전송되지 않습니다. Z-BOM 도입·구축에 관해서는 공급사 [ZIEN](https://zi-en.io)에 문의하세요.

## 결과 예시

분석이 끝나면 PR 코멘트와 Job Summary에 아래 형태의 진단 요약이 남습니다. 같은 PR에서 커밋이 갱신되면 코멘트가 새로 쌓이지 않고 기존 코멘트가 업데이트됩니다.

> ## ✅ Z-BOM SBOM 진단 결과 · `COMPLETED`
>
> | 항목 | 값 |
> |---|---|
> | 점검유형 | 소스코드 |
> | 컴포넌트 | SBOM 142 · HBOM 0 |
> | 취약점 | 🔴 Critical 2 · 🟠 High 5 · 🟡 Medium 11 · ⚪ Low 8 (총 26) |
>
> 📄 [보고서 보기](#) *(사내 Z-BOM 웹 콘솔의 프로젝트 요약 페이지로 연결)*
>
> <sub>repo `acme/backend` · commit `1a2b3c4d` · run `1024`</sub>

**보고서 보기**를 열면 사내 Z-BOM 콘솔에서 요약 너머의 상세 분석을 확인할 수 있습니다.

- 컴포넌트별 SBOM/HBOM 구성과 CVE 목록·심각도
- **익스플로잇 가능 코드 탐지**: 취약 컴포넌트를 버전으로 매칭하는 데서 끝나지 않고, 프로젝트 코드에서 취약점이 실제 트리거되는 지점(**sink**)에 도달하는 호출·데이터 흐름이 있는지까지 분석합니다
- **정탐/오탐(TP/FP) 검증**: sink 도달 여부를 근거로 각 CVE를 정탐(TP)·오탐(FP)으로 검증합니다. 단순 버전 매칭이 쏟아내는 오탐을 걸러내므로, 실제 익스플로잇 가능한 취약점부터 우선 대응할 수 있습니다

`fail-on`을 설정하면(예: `high`) 해당 심각도 이상의 CVE가 발견될 때 잡이 실패해 머지를 차단할 수 있습니다.

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
      - uses: ZIEN-TF/z-bom-action@v1
        with:
          url: ${{ secrets.Z_BOM_URL }}
          token: ${{ secrets.Z_BOM_TOKEN }}
          type: code
```

### 사전 준비
- **Z-BOM 서비스(온프레미스)**: 사내망에 Z-BOM이 구축·운영 중이어야 합니다. 이 액션은 해당 서버의 API(`/api/ci/scan` 등)를 호출할 뿐, 자체적으로 SBOM을 생성하지 않습니다.
- **러너**: Z-BOM 서버에 네트워크로 도달 가능한 **self-hosted 러너**. Z-BOM은 보통 사내망에만 열려 있으므로 GitHub-hosted 러너로는 일반적으로 사용할 수 없습니다. 러너에 `curl`·`jq`·`git` 필요.
- **Secret**: `Z_BOM_URL`(사내 Z-BOM 주소), `Z_BOM_TOKEN`(Z-BOM의 CI/CD 연동 설정 화면에서 발급).
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
