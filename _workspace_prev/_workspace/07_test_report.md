# 07 테스트 보고: 랜딩페이지 + 전체 퍼블리싱 리디자인 (Phase 7, 2026-11-04)

> Tester(wonbikok-tester) 산출 — Rails 8.1 minitest + fixtures, 시스템 테스트는 본 Phase부터 도입.

## 총평: **PASS** — 신규 39건 + 기존 135건 전부 통과, 코드 버그 0건

| 게이트 | 결과 |
|:---|:---|
| `bin/rails test` (기본 러너 — system 제외) | **170 runs, 734 assertions, 0 failures, 0 errors, 0 skips** |
| `bin/rails test:system` | **4 runs, 11 assertions, 0 failures, 0 errors, 0 skips** |
| 합계 (기존 135 + 신규 39) | **174 runs, 745 assertions — 전부 통과** |
| `bin/rubocop` | 94 files inspected, **no offenses** |

베이스라인(작성 전) 135건 통과 확인 후 신규 테스트를 추가했으며, 기존 테스트 135건 회귀 0건. **이번 Phase에서 기존 테스트 파일 수정 없음** (Phase 3-B에서 기계적 치환된 3파일 그대로 통과).

## 1. 신규 테스트 목록 (39건)

### `test/models/beta_application_test.rb` — 17 tests / 63 assertions

fixtures 미사용(암호화 컬럼 — 모델 API 생성, test_helper의 create_owner_user 선례 준수).

| 테스트 | Rule ID / 근거 |
|:---|:---|
| 필수 항목만으로 생성 가능 | 13.6 정상 |
| marketing_agreed 기본 false | 13.6 (마케팅 수신 선택·분리) |
| marketing_agreed true + 선택 3항목 저장 | 13.6 정상 |
| 필수 항목 누락별 무효 (name·title·contact_type·contact_value·academy_type·terms_agreed=false) | 13.6 예외 |
| 정의되지 않은 키(title/contact_type/academy_type) 무효 | 13.6 예외 |
| 원생 수 구간 잘못된 키 무효 + 빈 값 허용(선택) | 13.6 경계 |
| 이메일 형식 오류 3종 무효 | 13.6 예외 |
| 전화 형식 오류 3종 무효 | 13.6 예외 |
| 전화 하이픈·공백 정규화 저장 | 정규화 (User 선례) |
| 이메일 좌우 공백 제거 | 정규화 |
| **TEN-003** DB에 암호문 저장 (raw SQL로 평문 부재 확인) | TEN-003 |
| **TEN-003** 저장값 평문 복원 | TEN-003 |
| **TEN-003** deterministic 동등 조회 with_contact (타 이메일·타 수단 미조회) | TEN-003 / 13.6 중복 감지 |
| 동일 연락처 두 번째 create! → **RecordNotUnique** (유니크 인덱스 — 동시 제출 경합 방어) | WARNING-2 반영 검증 |
| 다른 연락처는 생성 가능 | 유니크 경계 |
| **TEN-002** 금지 컬럼 부재 (resident_number/ssn/birth_date/ip_address/user_agent/referrer) | TEN-002 |
| **TEN-002** 수집 컬럼 = 13.6 폼 항목 정확 일치 (초과 수집 없음) | TEN-002 / TEN-006 |

### `test/controllers/landing_controller_test.rb` — 7 tests / 32 assertions

| 테스트 | 검증 내용 |
|:---|:---|
| 비인증 `/` 200 + 랜딩 레이아웃 (`main#landing_main`) | root 변경(2026-11-04) |
| 랜딩 레이아웃에 앱 셸 하단탭 내비 없음 (`nav[aria-label=주요 메뉴]` 0개) | 리디자인 레이아웃 분리 |
| SEO 메타: title·description·og:title·og:description 값 일치 | 13.7 |
| 전환 지점 렌더: `cta_hero` 앵커 / `form_start` 폼 / FAQ `details summary` | 13.5 |
| 인증 원장 `/` → **303** `/dashboard` | root 게이트 |
| 온보딩 미완료 원장도 랜딩은 게이트 없이 `/dashboard`로 (skip 2종) | 게이트 skip 정합 |
| 비인증 `/dashboard` → 로그인 리다이렉트 | 기존 인증 게이트 유지 |

### `test/controllers/beta_applications_controller_test.rb` — 11 tests / 98 assertions

| 테스트 | Rule ID / 근거 |
|:---|:---|
| 신청 폼 페이지 공개 렌더 (비인증 200) | 13.6 / 공개 라우트 |
| 정상 제출 303 완료 화면 + 레코드 1건 + 필드값·동의 기본값 검증 | 13.6 / Turbo PRG |
| 완료 화면 200, 접수 안내만 표시, SLA 문구("24시간"/"즉시") 부재 | 13.6 (시간 약속 금지) |
| 필수 동의 누락 → **422** 랜딩 재렌더 + 오류 요약 + 속성 라벨 노출 | Turbo 규약 / 13.6 |
| 잘못된 이메일 → 422 + 커스텀 메시지(`activerecord.errors.messages.invalid_email`) | 13.6 |
| 본문 누락 → 400 (Strong Parameters) | 세션 테스트 선례 |
| **TEN-002** 허용 목록 외 필드(ip_address·resident_number) 무시 + 정상 필드 저장 | TEN-002 |
| 동일 연락처 재제출 → 303 멱등 종결 + 레코드 1건 유지 + notice 없음 | 13.6 (중복 노출 금지) |
| 연락 수단이 다르면 별도 신청 (email vs phone) | 유니크 인덱스 경계 |
| 전화 하이픈 제출 → 정규화 + DB 암호문 확인 (컨트롤러 플로우 경유) | TEN-003 |
| 11회째 제출 → rate limit: 랜딩 303 리다이렉트 + alert 문구 + 미생성 | 13.6 스팸 방어 (10회/1시간) |

### `test/application_system_test_case.rb` (신규) + `test/system/landing_responsive_test.rb` — 4 tests / 11 assertions

| 테스트 | 검증 내용 |
|:---|:---|
| 360px 뷰포트 가로 스크롤 없음 (`scrollWidth <= 360`) | PRD 16장 반응형 |
| CTA 2지점(`cta_hero`) 확인 + 헤더 CTA 클릭 → `#beta` 앵커 이동 + 폼 표시 | 13.5 |
| 베타 폼 필드 표시·입력 가능 (이름 fill_in + select/input 3종) | 13.6 |
| FAQ 아코디언 열림/닫힘 (`details[open]` 토글) | 13.3 시안 상호작용 |

## 2. 기존 회귀 결과

- 작성 전 베이스라인: 135 runs, 541 assertions, 0 failures (2026-11-04 Phase 6 보고와 동일).
- 완료 후: 기존 135건 전부 통과, **수정한 기존 테스트 0건** (라우트 이동에 따른 Phase 3-B의 3파일 치환분은 이미 반영돼 있어 본 Phase 개입 불필요).

## 3. 개발 중 수정한 신규 테스트 (전부 테스트 측 원인 — 코드 버그 아님)

| # | 증상 | 원인 분류 | 조치 |
|:---|:---|:---|:---|
| 1 | `invalid_email` 메시지 단언 실패("Translation missing") | 테스트 오류 — 커스텀 메시지 키는 `activerecord.errors.messages.*` 하위 | 키 경로 수정 |
| 2 | "email vs phone 중복 아님" 테스트 422 | 테스트 설계 오류 — "same@example.com"은 전화 형식 검증을 통과할 수 없어 422가 정상 | 유효한 전화번호로 재작성 |
| 3 | 360px 뷰포트 테스트에서 scrollWidth=485 | **환경 제약** — headless Chrome 신모드 최소 윈도우 폭 500px로 `window.resize_to`가 클램프됨(레이아웃 버그 아님. 485는 500px 뷰포트에서의 콘텐츠 폭) | CDP `Emulation.setDeviceMetricsOverride`(360×740)로 뷰포트 강제 → 360px 기준 검증 성공 |
| 4 | `details[:open]`이 "false" 문자열 반환 | 테스트 오류 — Selenium 속성 반환 타입 문제 | CSS 셀렉터 `details[open]` 방식으로 교체 |
| 5 | CTA 클릭 Ambiguous (2매치) | 테스트 오류 — 헤더·히어로 2곳이 모두 `cta_hero` | `within "header"`로 범위 한정 |

## 4. [코드 버그] 0건

구현 버그로 판명된 실패 없음. 중복 멱등(303·레코드 1건), 유니크 인덱스 차단, 422 재렌더, rate limit, 인증 게이트, 암호화 저장 모두 구현 동작과 일치.

## 5. 스킵·자동화 밖 항목

| 항목 | 사유 |
|:---|:---|
| 로그 마스킹(`contact_value => "[FILTERED]"`) 자동화 미포함 | 로그 파일 검증은 자동화 밖 — Phase 6 스모크에서 이미 실증. 필요 시 CI 로그 단계 추가 가능 |
| 랜딩 카피 하드코딩 스캔 생략 | 리뷰(05_review.md) 확인 + 통합 테스트가 ko.yml 키 값 대조(메타·완료 문구)로 간접 검증 |
| 실기기(실제 모바일 기기) 확인 | 헤드리스 에뮬레이션 한계 — 배포 전 실기기 1회 권장(리뷰어 권고와 동일) |

## 6. 커버리지 공백·권고

1. **CI 게이트 공백**: `config/ci.rb`의 "Tests: System" 스텝이 주석 상태 → 신규 시스템 테스트(4건)가 `bin/ci`에서 미실행. `bin/rails test` 기본 러너는 `test/system`을 포함하지 않음. **주석 해제 권장** (1라인, 본 Phase 범위 밖이라 미수정).
2. rate limit은 IP 단위(동일 IP)만 검증 — 분산 제출 시나리오는 과투자 금지 원칙상 미커버.
3. 422 재렌더 시 폼 위치 자동 스크롤 부재는 구현 한계(03_implementation.md §7-3) — UX 과제이며 자동화 검증 불요.
4. beta_applications fixtures 미작성(암호화 컬럼 정책) — 향후 이 모델을 fixture로 써야 할 경우 raw SQL 삽입이 되어 TEN-003 우회 위험이 있으니 모델 API 생성을 유지할 것.

## 7. 신규/변경 파일 (Phase 7)

| 파일 | 구분 |
|:---|:---|
| `test/models/beta_application_test.rb` | 신규 (17 tests) |
| `test/controllers/landing_controller_test.rb` | 신규 (7 tests) |
| `test/controllers/beta_applications_controller_test.rb` | 신규 (11 tests) |
| `test/system/landing_responsive_test.rb` | 신규 (4 tests) |
| `test/application_system_test_case.rb` | 신규 (headless_chrome, 시스템 테스트 베이스) |
| 기존 테스트 파일 | 수정 없음 |
