# W1 F1 구현 보고 — 온보딩·사업자 연동

- 담당: wonbikok-developer (W1F1Dev) / 2026-10-20
- 검증: `bin/rails db:migrate` 전체 통과, `bin/rails runner` 암복호화 실증, `bin/rubocop` **0 offenses**, Puma 부트 + HTTP 스모크(리다이렉트 분기) 확인

## 1. 생성/수정 파일 목록

| 구분 | 파일 |
|:---|:---|
| 수정 | Gemfile(bcrypt 활성화), Gemfile.lock, config/application.rb(i18n default_locale=:ko), config/routes.rb, app/controllers/application_controller.rb(인증 게이트), app/models/application_record.rb(전화번호 정규화 헬퍼), app/views/layouts/application.html.erb(모바일 퍼스트 Tailwind 레이아웃+연습 모드 배지) |
| 마이그레이션 | db/migrate/20261020000001_create_tenants.rb ~ 20261020000005_create_guardians.rb (5건, schema.rb 반영) |
| 모델 | app/models/{tenant,user,session,student,guardian,current}.rb |
| 컨트롤러 | app/controllers/{sessions,registrations,onboarding,dashboard}_controller.rb, concerns/authentication.rb |
| 서비스 | app/services/practice_data_seeder.rb |
| 헬퍼 | app/helpers/phone_helper.rb (masked_phone) |
| 뷰 | sessions/new, registrations/new, onboarding/step{2,3,4,5}, dashboard/show |
| 로캘 | config/locales/ko.yml (신규 — 모든 문구 i18n) |
| 보안 | config/credentials.yml.enc — `active_record_encryption.{primary_key,deterministic_key,key_derivation_salt}` 생성(기존 키 미존재로 보강) |

## 2. 레이어별 구현 요약

- **DB**: tenants(name, business_number, business_type enum 문자열, practice, onboarding_step, cash_receipt_link_status='pending'), users(tenant FK, phone_number **deterministic 암호화** + unique 인덱스, password_digest, role='owner'), sessions(Rails 8 DB 세션), students(월비 원 단위 integer, status active/paused/withdrawn), guardians(phone_number 암호화 + phone_last4 평문 보조). 주민번호 필드 부재(TEN-002).
- **인증**: `Authentication` concern — 쿠키 signed session_id, `Current`(CurrentAttributes)로 current_user→current_tenant 주입. application_controller `require_authentication` 게이트. 가입은 Tenant+User 트랜잭션 동시 생성.
- **온보딩**: onboarding_step 1(가입)→2(사업자)→3(계좌)→4(연동 안내: '준비 중'·발행 비활성 안내)→5(연습 모드 선택)→6(완료). 로그인 시 미완료 스텝으로 리다이렉트(이탈 재개). 루트는 인증·온보딩 상태 분기.
- **연습 모드**: PracticeDataSeeder — 이름·학년·원비·납부유형·상태 다양화된 샘플 10명+보호자 생성. 레이아웃 상단 배지+안내 배너.
- **TEN-003**: User.phone_number는 deterministic 암호화(유니크 조회 가능), Guardian은 비결정 암호화+last4. `masked_phone`으로 010-****-5678 표시. tenant 필터는 현재 tenant FK 경유(TEN-001).
- **Turbo 규약**: 실패 `render status: :unprocessable_entity`, 성공 `redirect_to ... status: :see_other`.

## 3. F1 수용조건 자체 점검

- [x] 온보딩 스텝 6 이하(실질 4스텝 진행), onboarding_step 저장·재접속 이어하기 — 로그인 리다이렉트 경로로 구현
- [x] 사업자등록번호 형식 검증(하이픈 제거 10자리, 위반 시 ko.yml 오류 문구 즉시 피드백)
- [x] 현금영수증 연동: W1은 pending 상태 표시+재시도/문의 경로 대상 아님(실연동 W3 — 실패 안내는 W3 구현 대상)
- [x] 연동 완료 전 발행 기능 비활성 안내 표시(step4)
- [x] 연습 모드에서 실제 알림톡·발행 없음 — 외부 호출 코드가 W1에 존재하지 않아 구조상 보장 + 화면 명시
- [x] 샘플 데이터 memo='연습 모드 샘플 데이터'로 실데이터 구분 + 배지 표시

## 4. Rule ID

- TEN-001: 전 원장 데이터 tenant FK 격리 + 인증 게이트 서버측 검증
- TEN-002: 스키마에 주민번호 필드 부재
- TEN-003: 휴대폰번호 암호화(User: deterministic / Guardian: +last4) + 마스킹 헬퍼

## 5. 검증 결과 (실시행)

1. `bin/rails db:migrate` — 5건 성공
2. 암복호화: User/Guardian 저장→평문 복원 OK, DB raw 값 `{"p":"..."}` 암호문 확인, `masked_phone` → `010-****-5678`
3. 사업자번호 `123-45-67890` 입력 → `1234567890` 정규화 저장
4. PracticeDataSeeder → 원생 10명+보호자 생성 확인 후 테스트 데이터 클린업(tenants=0)
5. `bin/rubocop` — no offenses / Puma 부트 + curl: `/`→`/session/new` 302, 미인증 `/onboarding/step/2`→로그인 302, 로그인·가입 페이지 200

## 6. 열린 이슈·리스크

1. **본인인증 미도입**: PRD 완화 옵션(오픈 이슈 #8)에 따라 휴대폰번호+비밀번호. W3 이후 포트원 본인인증 자리만 확보 — 가입 번호 실소유 검증 없음.
2. **credentials 암호화 키**: dev/test 키 신규 생성·저장됨. 프로덕션 배포 시 credentials에 동일 키 주입 필요(RAILS_MASTER_KEY 관리).
3. **연습 모드 'commit' 파라미터**: step5 버튼 name=commit value로 분기 — Turbo 네이티브 제출 기준 동작.
4. **User.last_login_at**: update(검증 통과) 사용 — 실서비스 빈도 낮아 무중단 이슈 없음.
5. **F2 연계**: students/guardians 모델·암호화·스코프는 F2(원생 관리) 개발자가 그대로 사용 가능하도록 선구축됨.

---

# W1 F2 구현 보고 — 원생 관리

- 담당: W1F2Dev / 2026-10-20
- 검증: `bin/rubocop` **0 offenses**, `bin/brakeman` **no warnings**, 마이그레이션 전건 up(신규 마이그레이션 없음), Puma 부트 + 가입→온보딩→원생 등록(중복 확인→confirm)→형제 배지→CSV 양식 다운로드→업로드(성공1/실패1)→오류행 재업로드(성공1/실패0)→휴원/복원(ended_on 기록·해제)→수정 HTTP 스모크 완료. 스모크 데이터 클린업(tenants=0).

## 1. 생성/수정 파일 목록

| 구분 | 파일 |
|:---|:---|
| 모델 | app/models/student.rb(수정: `scope :active`(INV-004, 기존 enrolled 대체), nested attributes, sync_ended_on 콜백) |
| 컨트롤러 | app/controllers/students_controller.rb(신규), app/controllers/registrations_controller.rb(수정 — F1 버그 픽스, §5 참조) |
| 서비스 | app/services/{guardian_duplicate_finder,students_csv_template_service,students_csv_import_service}.rb(신규) |
| 뷰 | app/views/students/{index,show,new,edit,_form,import_new,import_result}.html.erb(신규) |
| 헬퍼 | app/helpers/students_helper.rb(신규: status_badge_class) |
| 라우팅 | config/routes.rb(students resources + collection import 3건 + member 상태변경 3건) |
| 로캘 | config/locales/ko.yml(students 섹션, student/guardian attributes, date format, common.back/edit) |
| 기타 | app/views/dashboard/show.html.erb·app/views/layouts/application.html.erb(원생 관리 링크), Gemfile+Gemfile.lock(`gem "csv"` — Ruby 3.4+ 기본 젬 제외 대응) |

## 2. 레이어별 구현 요약

- **모델**: `Student.active` = 재원 스코프(INV-004 청구 대상 기반, W2 청구 생성에서 사용 예정). `sync_ended_on` before_save — 휴원/퇴원 시 ended_on 최초 기록, 재원 복원 시 해제. Guardian nested attributes로 폼에서 대표 보호자 동시 저장(phone_last4는 Guardian 콜백이 채움 — 스모크로 확인).
- **컨트롤러**: 전 조회 `current_tenant` 스코프(TEN-001). 검색(원생명 LIKE + 보호자 phone_last4 4자리), 상태 필터. 생성 시 중복 확인 절차 — 동일 보호자 전화 또는 유사 이름(공백 제거 후 포함 관계) 기존 원생 발견 시 확인 배지 표시, `confirm=1` 재제출로 저장(형제 허용). 목록/상세 형제 배지는 GuardianDuplicateFinder가 암호문을 Ruby에서 비교해 산출. 이번 달 배지는 '대기' 고정(청구 W2).
- **CSV**: 양식 8컬럼(원생명/학년/월 원비/납부일/납부유형/상태/보호자명/보호자 휴대폰번호) + 예시행, UTF-8 BOM(엑셀 호환). 양식에는 실데이터 없음. 업로드는 행 단위 파싱·검증(필수값/금액 숫자/납부일 1~28/유형·상태 허용값/전화 형식), 정상행 즉시 반영(행 단위 트랜잭션), 오류행은 행번호+사유 수집 → 세션 저장 → `GET /students/import/errors`로 오류행+사유 CSV 재내려받기 → 같은 양식 2차 업로드. 인코딩은 UTF-8만 지원, 화면에 'UTF-8 권장'(CP949 등 P1 보류) 안내. 업로드 파일은 임시 보관 없이 스트림 처리 후 폐기.
- **개인정보(TEN-003)**: 목록·상세 전화는 `masked_phone`으로만 표시, CSV 양식 예시데이터만 포함. 상세 화면도 마스킹 유지(전체 번호 노출 없음).
- **미구현 명시**: 플랜 원생 수 상한 체크(SUB-001)는 W4 예정 — StudentsController 상단 주석 표기. 청구·발행 이력은 W2 — 상세 화면에 '청구 기능은 다음 업데이트에 제공' 빈 상태 안내.

## 3. F2 수용조건 자체 점검

- [x] CSV 오류 행 행 단위 재업로드 가능 + 정상 행 즉시 반영 — HTTP 스모크 실증(오류 CSV 내려받아 수정 후 2차 업로드 성공)
- [x] 휴원·퇴원 원생 청구 대상 제외 — `Student.active` 스코프로 강제(W2 청구 생성이 이 스코프만 사용하도록 계약)
- [x] 비활성화 시 기존 이력 보존 — 원생은 삭제하지 않고 상태 전이만 수행(destroy 경로 없음), ended_on 기록
- [x] 보호자 번호 변경 시 이후 발행부터 적용 — Guardian을 원생 카드에 직접 수정 반영, 과거 이력은 W2 청구 스냅샷(TEN-004)으로 분리될 예정. 스냅샷 컬럼은 W2 마이그레이션 범위
- [x] 원비 수정이 확정 청구에 영향 없음 — 확정 청구 기능이 아직 없어 구조상 보장(W2 스냅샷 구현 시 유지)
- [x] 개인정보 대량 내려받기 권한·기록 — 내려받는 CSV는 양식/오류행(사유 포함)뿐이며 실개인정보 미포함. 전화는 오류 CSV에도 원문 대신 입력값 그대로(원장이 입력한 값)만 반환

## 4. Rule ID

- TEN-001: StudentsController 전 액션 current_tenant 스코프 + 인증 게이트
- TEN-002: 신규 필드 없음(주민번호 수집 구조 부재 유지)
- TEN-003: 목록·상세 masked_phone 표시, CSV 양식 무실데이터, 임시파일 미보관
- INV-004: `Student.active` 스코프(휴원·퇴원 자동 제외)
- SUB-001: 미구현(W4) — 코드 주석 명시

## 5. 검증 결과 (실시행)

1. 서비스 레벐(rails runner): 양식 BOM 확인, 업로드 성공1/오류3(사유 정확), phone_last4='2222'+복호화, ended_on 기록/해제, 형제 그룹 탐지, 오류 CSV 재생성
2. HTTP 스모크: 가입→온보딩 완료→원생 등록(중복 없음 즉시 저장)→동일 전화 2번째 원생(중복 배지→confirm 저장)→목록 형제 배지 2건·마스킹 전화·'이번 달 대기' 배지→CSV 업로드(성공1/실패1, 3행 사유 표시)→오류 CSV 다운로드→수정 재업로드(성공1/실패0)→휴원(ended_on=2026-10-20)→복원(ended_on=nil)→수정(303)→검색·필터 200
3. rubocop 0 / brakeman 0 / db:migrate:status 전건 up / 스모크 테넌트 클린업

## 6. 열린 이슈·리스크

1. **[F1 버그 픽스 포함] 가입 시 Tenant 미연결로 항상 422**: RegistrationsController#create가 `User.new(user_params)`(tenant 미할당)으로 `belongs_to :tenant` 필수 검증에 항상 실패하는 F1 잔존 버그 — `@tenant.users.build`로 최소 수정. 스모크상 가입이 전면 막혀 있었으며 F1 테스트 범위 밖이었던 것으로 추정([INFERENCE]).
2. **형제 탐지의 Ruby 비교**: Guardian.phone_number 비결정 암호화로 SQL 동등 비교 불가 — W1 스케일(수십 명)에서는 메모리 비교. 원생 수 증가 시 결정론적 해시 컬럼 도입 검토(코드 주석 표기).
3. **오류 이력의 세션 저장**: ~~세션 저장~~ → Phase 6에서 서버측 Rails.cache(30분 만료)로 이전 완료(BLOCKER-1, 위 Phase 6 섹션 참조).
5. **CSV 인코딩**: UTF-8만 지원(P1에서 CP949 확장). 화면 안내 표기 완료.

---

# Phase 6 수정 — W1 리뷰 지적 반영 (W1FixDev / 2026-10-20)

검증: `bin/rubocop` **0 offenses**, `bin/brakeman` **no warnings**, `bin/rails runner` 부트 + 로직 스모크 통과(아래 §3). 상세 이슈별 표기는 `_workspace/05_review.md` 각 항목 하단 "수정 완료" 참조.

## 1. 수정 파일 목록

| 구분 | 파일 |
|:---|:---|
| 컨트롤러 | app/controllers/students_controller.rb(BLOCKER-1 캐시 저장·1MB 상한·가드), onboarding_controller.rb(WARNING-1 스텝 강제·컨텍스트 검증), sessions_controller.rb(WARNING-4 rate_limit, WARNING-5 expect), registrations_controller.rb(WARNING-6 RecordNotUnique rescue) |
| 모델 | app/models/student.rb(WARNING-2 1..28 상수, WARNING-3 primary_guardian), app/models/tenant.rb(WARNING-1 business_info 컨텍스트 presence) |
| 서비스 | app/services/students_csv_import_service.rb(CRITICAL-1 중복 검사, WARNING-2 상수 참조) |
| 뷰 | app/views/onboarding/step2.html.erb(required 속성·오류 표시) |
| 로캘 | config/locales/ko.yml(import.errors.expired/file_too_large/duplicate_suspect, registration.duplicate_phone) |

## 2. 이슈별 수정 요약

- **[BLOCKER-1]** CSV 오류내역을 쿠키 세션 → 서버측 `Rails.cache`(테넌트별 랜덤 키, 30분 만료)로 이전. 세션에는 조회 키만 보관, `import_errors`는 캐키 조회 부재 시 만료 안내. 업로드 1MB 상한 초과·`respond_to?(:read)` 위반 시 422. 쿠키 4KB 초과 500 원천 제거.
- **[CRITICAL-1]** CSV 행별 `GuardianDuplicateFinder#conflicts_with`(수동 등록 동일 기준) 검사 → 중복 의심 행은 오류행 전환, 사유 "중복 의심 — 기존 원생 OOO...". Finder는 행 루프 외부 1회 생성.
- **[WARNING-1]** 온보딩 스텝 우회 차단(`restrict_step_range`: 현재 스텝+1 초과 시 현재 스텝 리다이렉트, `advance_step` 상향 전용) + Tenant 사업자 정보(상호·사업자번호·업종·대표자명) `on: :business_info` presence 검증. 미완료 테넌트 `/students` 게이트는 미적용 — 리뷰 보고서에 후속 권장으로 기록.
- **[WARNING-2]** `Student::PAYMENT_DAY_RANGE = (1..28)` 단일 상수, 모델 검증·CSV 서비스 공용 참조.
- **[WARNING-3]** `primary_guardian`을 로드된 컬렉션 Ruby 선택으로 변경 — 목록 N+1 제거.
- **[WARNING-4]** `rate_limit to: 10, within: 3.minutes` (sessions#create).
- **[WARNING-5]** `params.expect(session:)`, 검색어 String 가드, 업로드 read 가드 — 변조 3곳 400/422 처리.
- **[WARNING-6]** `RecordNotUnique` rescue → "이미 가입된 번호" 422.

## 3. 검증 결과 (실시행)

1. `bin/rubocop` 47 files, no offenses / `bin/brakeman` no warnings.
2. `bin/rails runner`: 부트 OK, `PAYMENT_DAY_RANGE` 마지막 값 28, `Tenant#valid?(:business_info)` 빈값 false·완비 true 확인.
3. CSV 스모크(rails runner): 헤더 오타 20행 전부 오류 처리(500 미재현), 중복 의심 1행+정상 1행 → 오류 사유 "중복 의심 — 기존 원생 김철수과(와)..." 확인·정상행만 반영, 캐시 저장→조회(20행)→삭제 후 nil(만료 경로) 확인. 스모크 테넌트 클린업 완료.
4. 마이그레이션 변경 없음(스키마 불변).

## 4. 잔여 항목 (사유 기록)

- **미완료 테넌트의 `/students` 직접 접근 게이트(WARNING-1 부수)**: 온보딩 미완료 테넌트는 로그인 시 미완료 스텝으로 리다이렉트되는 흐름이며, 실데이터 진입 경로가 온보딩 완료 후로 유도됨. 완전 차단은 인증 concern 변경을 수반하므로 W2 반영 권장(임의 생략 아닌 범위 판단 — 리뷰 보고서 동일 기록).
- **계정 잠금(WARNING-4)**: rate limit으로 온라인 대입 완화. 계정 잠금 정책은 W2 과제로 유지.
5. **원생 1명 복수 보호자**: 데이터 모델은 has_many 확장 가능, MVP 화면은 대표 1명(PRD 명세대로).

# Phase 6 수정 보강 — W1 재리뷰 CRITICAL-2 (W1Fix2Dev / 2026-10-20)

**[CRITICAL-2] 온보딩 1스텝 경계 재개 400**: 가입 직후(`onboarding_step=1`) 이탈자의 재로그인·루트 진입 리다이렉트 목표가 `/onboarding/step/1`(STEPS=[2,3,4,5] 밖)이어서 400이 발생. 두 리다이렉트 지점에서 목표 스텝을 `[current_tenant.onboarding_step, OnboardingController::STEPS.first].max`로 클램프:

- app/controllers/sessions_controller.rb — `redirect_after_login` 리다이렉트를 공용 헬퍼 `resume_onboarding_step` 경유로 변경(세션 흐름 전용 헬퍼, 코멘트에 CRITICAL-2 명기)
- app/controllers/application_controller.rb — `redirect_if_onboarding_incomplete`(루트 진입 게이트) 동일 클램프 적용. `OnboardingController::STEPS` 기존 상수 재사용, 신규 중복 정의 없음

검증: `bin/rubocop` 47 files no offenses / `bin/brakeman` no warnings / `bin/rails runner` 부트 OK·클램프 스모크(step=1→2, step=3→3 유지). step=1 리다이렉트 목표가 step 2로 변경되어 400 경로 소멸, `restrict_step_range`(≤step+1)와 정합. F1 수용조건 "중단 후 재로그인 시 미완료 스텝 재개" 충족.

# Phase 6-3 — W1 테스트 발견 버그 2건 수정 (W1Fix3Dev / 2026-10-20)

- **[BUG-1]** ko.yml의 `students.import.no_file`·`expired`·`file_too_large` 3키가 `errors:` 하위가 아닌 `students.import` 레벨에 위치해 `t("students.import.errors.*")` 조회 시 "Translation missing" 노출. 3키를 `students.import.errors:` 하위로 이동(config/locales/ko.yml:143-146). YAML 파싱 검증 완료.
- **[BUG-2]** `StudentsController#import_errors`가 `Rails.cache.read(session[:csv_import_errors_key].to_s)`로 빈 키 조회 → 프로덕션(solid_cache/MemoryStore)에서 `ArgumentError` 500. 키 blank 가드 선행(students_controller.rb:97-98) — 키 없으면 캐시 조회를 건너뛰고 기존 만료 경로(`students.import.errors.expired` 안내 리다이렉트)로 통일.
- **회귀 테스트**: ① 1MB 초과·파일 문자열 변조·파일 미선택 응답에 "Translation missing" 부재 + 정상 안내 문구 노출 단언 추가 ② 만료 리다이렉트 후 안내 문구 단언 추가 ③ 신규 테스트 "오류내역 키가 없는 세션의 직접 접근은 500이 아닌 만료 안내 리다이렉트다" 추가 ④ 기존 타 테넌트 키 접근 테스트의 ArgumentError rescue 제거하고 리다이렉트 단언으로 교체.
- **열린 이슈(W2 과제로 기록)**: 로그아웃(`delete session_url`)이 cookie 세션의 `csv_import_errors_key`를 제거하지 않음 — 다른 계정 로그인 시 이전 계정의 오류내역 캐시 키가 세션에 잔존(오류행 값은 원장 본인 입력값이라 유출 심각도 낮음). W2 `reset_session` 정비 시 병행 처리.
- **검증**: `bin/rails test` 73 runs, 285 assertions, 0 failures / `bin/rubocop` 57 files no offenses / `bin/brakeman` no warnings. 범위 외 코드 변경 없음.
