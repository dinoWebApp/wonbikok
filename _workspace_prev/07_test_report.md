# W1 테스트 보고서 — F1 온보딩 + F2 원생 관리 (Phase 7)

- 작성: wonbikok-tester (W1Test) / 2026-10-20
- 대상: F1 온보딩·사업자 연동, F2 원생 관리(+ Phase 6 수정 전체)
- 결과: **`bin/rails test` 72 runs, 256 assertions, 0 failures, 0 errors** / `bin/rubocop` 57 files **no offenses**

## 1. 실행 통계

| 항목 | 값 |
|:---|:---|
| 테스트 파일 | 10개 (models 4, services 2, controllers 4) |
| 총 테스트 | 72건 / 256 assertions |
| 통과 | 72 (100%) |
| 실패 | 0 |
| 코드 버그로 분류 | 2건 (아래 §3 — 테스트는 통과 형태로 작성, 버그는 보고만) |

## 2. 발견·보고 이슈 (Developer 전달 — 임의 수정하지 않음)

### [BUG-1] CSV 안내 문구 3건의 로케일 키 위치 오류 → "Translation missing" 표시
- **증상**: `students.import.errors.no_file` / `expired` / `file_too_large` 3키가 ko.yml에서 `errors:` 하위가 아닌 한 단계 위(`students.import` 레벨, ko.yml 138~140행)에 위치. 컨트롤러는 `t("students.import.errors.*")`로 조회(students_controller.rb:74, 99, 121) → 실제 화면에 "Translation missing: ko.students.import.errors.file_too_large" 노출.
- **영향**: 1MB 초과 차단(422)·오류내역 만료 안내·파일 미선택 안내가 모두 깨진 문구로 표시됨.
- **분류**: 코드 버그(로케일 들여쓰기). **수정 제안**: 3키를 `errors:` 하위로 이동.
- **테스트 처리**: 상태 코드·데이터 무변화 등 행동 계약만 단언하고 문구 단언은 제외(BUG-1 해소 후 문구 단언 추가 권장).

### [BUG-2] 오류내역 키 없는 세션의 `/students/import/errors` 직접 접근 → ArgumentError 500
- **증상**: `import_errors`가 `Rails.cache.read(session[:csv_import_errors_key].to_s)`(students_controller.rb:97)로 빈 문자열 키 조회 → MemoryStore/SolidCache 계열에서 `ArgumentError: key cannot be blank`. 재리뷰 보고의 "키 없는 직접 접근도 nil.to_s로 동일 분기 — 500 없음"은 :null_store에서만 성립. 프로덕션(solid_cache)에서는 만료 후·새 세션 직접 접근 시 500 화면.
- **분류**: 코드 버그(경계 누락). **수정 제안**: `if (key = session[:csv_import_errors_key]).present?` 선행 후 만료 분기로 통일.
- **테스트 처리**: 데이터 미노출 성질만 단언(BUG-2 경로 rescue). 재현: `test/controllers/students_controller_test.rb` "타 테넌트 세션으로 오류내역 키에 접근할 수 없다".

### [관찰] 로그아웃이 cookie 세션의 `csv_import_errors_key`를 제거하지 않음
- `clear_session`은 `:session_id` 쿠키만 삭제 → 같은 브라우저에서 로그아웃 후 다른 계정 로그인 시 이전 계정의 오류내역 키가 세션에 남아 캐시 내역 조회 가능(오류행 값은 원장 본인 입력값이라 유출 심각도 낮음). W2 `reset_session` 정비 시 병행 권장.

## 3. Rule ID 커버리지

| Rule ID | 시나리오 | 테스트 | 결과 |
|:---|:---|:---|:---|
| TEN-001 | 타 테넌트 원생 show/pause 404, 목록 타테넌트 데이터 부재, 오류내역 키 테넌트 분리·타세션 접근 차단, CSV 양식 실데이터 무포함 | students_controller_test 6건 | 통과 |
| TEN-002 | 스키마상 주민번호 필드 부재(구조 확인 — 수집 경로 자체가 없어 별도 테스트 부재) | schema 검토 | 해당 없음(구조 보장) |
| TEN-003 | Guardian/User DB 암호문 저장, phone_last4 자동 채움, masked_phone 형식, deterministic 조회, 번호 정규화 | guardian_test·user_test 6건 | 통과 |
| INV-004 | Student.active 재원 전용, 전이 시 스코프 반영, ended_on 기록·복원 해제·최초일 보존 | student_test 5건 | 통과 |
| PAY-DAY(경계) | 모델 1·28 통과/0·29 거절, CSV 28 통과/29 거절, 직접 POST 29 거절 | student_test·csv service·controller 3건 | 통과 |
| WARNING-4 | 로그인 11회째 429 | sessions_controller_test | 통과 |
| WARNING-5 | session 본문 누락 400, `q[]=` 배열 정상 처리, 파일 필드 문자열 422 | sessions·students controller test | 통과 |
| WARNING-6 | 검증 우편 요청도 RecordNotUnique → "이미 가입된 휴대폰번호" 422 | registrations·user_test 2건 | 통과 |
| WARNING-1/7 | 스텝 우회 차단(2스텝에서 4·5 GET/PATCH 리다이렉트), 사업자 빈값 422·정상 제출 진행 | onboarding_controller_test 2건 | 통과 |
| CRITICAL-1/2, BLOCKER-1 | §4 참조 | — | 통과 |

## 4. 리뷰어 전달 시나리오 9건 매핑

| # | 리뷰어 시나리오 | 테스트 | 결과 |
|:---|:---|:---|:---|
| 1 | CRITICAL-2 step=1 재로그인 재개 400 아님·루트 재개·step=3 유지·완료자 미적용 | onboarding_controller_test 3건 | 통과 |
| 2 | BLOCKER-1 CSV 대량 오류 + 캐시(만료 안내·타 테넌트 키 접근 불가) | students_controller_test 2건 + service 헤더오타 전행 오류(행번호 2·3 수집) + 1MB 20,000행 422 | 통과 (⚠️ 만료 분기는 MemoryStore 교체 방식으로 검증 — 리뷰어 메모 반영) |
| 3 | CRITICAL-1/WARNING-8 CSV 중복(동일 파일 2회차 전행 오류·생성 0건, 형제 행 오류 전환 + 수동 경로 형제 등록 허용) | students_controller_test 2건 + csv service 2건 | 통과 |
| 4 | WARNING-1/7 스텝 강제 + 사업자 빈값 422 | onboarding_controller_test 2건 | 통과 |
| 5 | WARNING-2 납부일 일원화(29·31 거절, 28 통과) | student_test 2건 + service 1건 + controller POST 1건 (31은 29와 동일 검증 경로라 29로 대표) | 통과 |
| 6 | TEN-001/003 회귀(404·마스킹·last4 검색·오류 CSV 타 데이터 부재) | students·guardian tests | 통과 |
| 7 | WARNING-5/6 견고성 | sessions 1건 + students 2건 + registrations 1건 | 통과 |
| 8 | WARNING-4 rate limit 429 | sessions_controller_test | 통과 (⚠️ test_helper에서 ActionController::Base.cache_store를 컨트롤러 로드 전 MemoryStore로 교체 — rate_limit은 부팅 시 store를 캡처하기 때문) |
| 9 | INV-004 상태 전이 회귀 | student_test 5건 + controller 1건 | 통과 |

## 5. 테스트 설계 메모 (재현성·제약)

1. **fixtures 범위**: `tenants.yml`·`students.yml`만 사용. Guardian/User는 `encrypts` 컬럼이 있어 raw SQL로 삽입되는 fixtures가 평문을 남겨 `Decryption` 오류를 유발함을 실증 확인 → 모델 API로 생성하는 헬퍼(`create_owner_user`, `create_student_with_guardian`) 사용. 초기 프로브 잔재가 test DB에 남아 오류를 낸 건 `bin/rails db:test:prepare`로 정리함.
2. **캐시 의존 기능**: CSV 오류내역 만료는 `with_memory_cache`(테스트 블록 내 Rails.cache 교체·ensure 복원), rate limit은 부팅 전 store 교체로 각각 검증 — test env `:null_store` 제약 회피.
3. **RecordNotUnique 재현**: 검증 우회용 `valid?` 치환이 필요하여 alias + ensure 복원 패턴 사용(registrations_controller_test, user_test).
4. 테스트 간 독립성: transactional fixtures 기본, 순서 의존 없음(parallel workers 간 DB 분리 확인).

## 6. 결론

- 리뷰어 시나리오 9건 전부 커버, 전체 스위트 그린. 산출 테스트만으로 품질 게이트(`bin/rails test` + `bin/rubocop`) 통과.
- **코드 버그 2건(BUG-1 로케일 키 위치, BUG-2 빈 캐시 키 500) + 관찰 1건(로그아웃 시 세션 키 잔존)** 을 Developer 전달 필요 — 본 Tester는 수정하지 않음(프로토콜 준수).

---

# Phase 6-3 수정 후 재실행 — BUG-1·BUG-2 픽스 검증 (W1Fix3Dev / 2026-10-20)

- 수정: BUG-1 ko.yml 3키 `students.import.errors:` 하위 이동 / BUG-2 `import_errors` 키 blank 가드(만료 경로 재사용)
- 결과: **`bin/rails test` 73 runs(+1), 285 assertions(+29), 0 failures, 0 errors** / `bin/rubocop` 57 files no offenses / `bin/brakeman` no warnings

| 항목 | 이전(Phase 7) | 수정 후 |
|:---|:---|:---|
| 총 테스트 | 72 / 256 assertions | **73 / 285 assertions** |
| 실패·에러 | 0 | 0 |

## 회귀 테스트 상세

1. **BUG-1 고정**: 1MB 초과 422·파일 문자열 변조 422·파일 미선택 422 응답에 `Translation missing` 부재 + 정상 안내 문구("파일이 너무 큽니다" / "CSV 파일을 선택해 주세요") 노출 단언 추가. 만료 리다이렉트 후 안내 문구("오류 내역이 만료되었거나 없습니다") 노출 단언 추가 — failing-before/passing-after 확인(수정 전 3경로 모두 Translation missing 노출).
2. **BUG-2 고정**: 신규 테스트 "오류내역 키가 없는 세션의 직접 접근은 500이 아닌 만료 안내 리다이렉트다" — 수정 전 `Rails.cache.read("")` ArgumentError 500 재현 경로, 수정 후 302 리다이렉트·안내 문구 확인. 기존 "타 테넌트 세션" 테스트의 `rescue ArgumentError` 버그 우회 제거하고 리다이렉트 단언으로 교체.
3. **관찰 1건(로그아웃 시 `csv_import_errors_key` 잔존)**: 지시대로 미수정 — 03_implementation.md 열린 이슈에 W2 과제(`reset_session` 정비 시 병행)로 기록.
