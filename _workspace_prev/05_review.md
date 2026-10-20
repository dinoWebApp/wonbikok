# W1 리뷰 보고 — F1 온보딩·사업자 연동 + F2 원생 관리

- 작성: wonbikok-reviewer / 2026-10-20
- 검토 범위: 작업 디렉토리 전체(컨트롤러 6·모델 7·서비스 4·뷰 16·마이그레이션 5·routes/locales/schema)
- 기준: PRD 7장 F1·F2, 9장, 13.4, 14장, 15장, 22장 Rule ID / AGENTS·아키텍처 컨벤션

---

## 리뷰 상태: **CHANGES_REQUESTED**

- BLOCKER 1건, CRITICAL 1건 → 수정 후 재검증 필요.
- BLOCKER 발견에 따라 원칙대로 나머지는 요약 수준으로 기술함(전수 검토는 완료됨 — 아래 이슈 목록이 그 결과).

---

## 1. 이슈 목록

### [BLOCKER-1] F2 수용조건(오류행 리포트)·15.3 안정성 — app/controllers/students_controller.rb:75, app/services/students_csv_import_service.rb:37

**CSV 오류내역을 쿠키 세션에 저장 → CookieOverflow 500으로 임포트 결과가 통째로 유실됨.**

- 세션 스토어 설정이 없어 Rails 기본 CookieStore(4KB 한도)를 사용함. `import` 액션이 오류행 전체(행 원본값+사유)를 `session[:csv_import_errors]`에 직접 저장(students_controller.rb:75).
  > **수정 완료** (2026-10-20, W1FixDev) — 오류내역 저장을 서버측 Rails.cache로 이전. `StudentsController#store_import_errors`(app/controllers/students_controller.rb:114-122)가 테넌트별 랜덤 키로 30분 만료 캐시 저장, 세션에는 조회 키만 보관. `import_errors`는 캐시 키로 조회, 부재 시 만료 안내(alert) 후 리다이렉트. 업로드 파일 1MB 상한 초과 시 422 안내(students_controller.rb:75-78), `upload.respond_to?(:read)` 가드로 문자열 변조 500 제거. rails runner 스모크: 헤더 오타 20행 전부 오류 → CookieOverflow 미재현, 캐시 저장·조회·만료(삭제 후 nil) 확인.
- 정량 검증(실제 ko.yml 문구 기준): 오류 행 1건당 암호화 쿠키 점유 ≈ 207~455B → **전화 형식 계통 오류 14행, 헤더 오타로 전 행 실패 시 6행만 넘어도 한도 초과**.
- 현실 시나리오: 30~100행 규모 학원 명단에서 헤더를 오타하거나 전화 열 서식이 어긋나면(계통 오류 = 전 행 실패가 매우 흔함) → `ActionDispatch::Cookies::CookieOverflow` → **500**. 이때 정상행은 이미 저장된 반면 원장은 결과 화면·오류 리포트·재업로드 경로를 모두 잃음(F2 수용조건 "오류 행은 행 단위로 재업로드 가능" 위반 + 런타임 에러).
- 부수 결함: 업로드 파일 크기 제한이 전혀 없음(`@upload.read`로 전체를 메모리 적재, students_csv_import_service.rb:37) — 남용 시 DoS 여지.

**수정 제안**
1. 오류내역 저장을 쿠키 세션에서 분리 — 서버측 저장(Rails.cache with tenant key, 또는 `csv_import_errors` 임시 테이블/파일) 후 다운로드는 발급 토큰 경유. 최소 완화로는 오류 저장 건수 상한(예: 50건, 초과분 "이후 행 요약") + 전체 파일 크기 상한(예: 1MB)과 데이터 행 상한(예: 500행)을 `import` 액션 선행 검사로 추가.
2. 세션 분리가 W1 범위에서 어렵다면 최소한 크기 초과 예상 시 즉시 422("오류가 너무 많습니다. 파일을 확인해 주세요")로 차단해 500을 막을 것.

### [CRITICAL-1] F2 명세 "저장 전 유사 이름·연락처 중복 등록 경고" — app/services/students_csv_import_service.rb:28-33

**CSV 임포트 경로에 중복 경고가 전혀 없음.** 수동 등록 폼은 `GuardianDuplicateFinder`로 확인 절차를 두지만(students_controller.rb:26-29), CSV 행은 검증 통과 시 무조건 생성됨.

- 특히 사용자가 안내를 무시하고 **전체 파일을 재업로드하면 기존 정상행이 전원 중복 등록**됨. 원생에는 삭제 경로가 없고(상태 전이만 허용 — F2 보고 §3 "destroy 경로 없음") 중복 원생은 퇴원 처리로만 남겨져 되돌릴 수 없는 데이터 오염이 됨.
  > **수정 완료** (2026-10-20, W1FixDev) — `StudentsCsvImportService#import_row`(app/services/students_csv_import_service.rb:51-63)에서 검증 통과 행에 대해 `GuardianDuplicateFinder#conflicts_with`(수동 등록과 동일 기준)를 검사, 충돌 시 오류행 전환(사유: "중복 의심 — 기존 원생 OOO과(와) 보호자 연락처 또는 이름이 같습니다...", ko.yml `students.import.errors.duplicate_suspect`). Finder는 `call`에서 1회 생성해 전 행 재사용. 스모크: 기존 원생과 동일 보호자 전화 행 → 오류행(사유 확인), 미중복 정상행 1건 정상 반영.
- CSV는 대량 등록 경로라 중복 발생 가능성이 수동보다 높음에도 규칙이 미적용된 유일한 경로.

**수정 제안**: `import_row`에서 `GuardianDuplicateFinder#conflicts_with`(동일 보호자 전화·유사 이름)를 검사해 충돌 시 오류행으로 전환(사유: "기존 원생과 중복 가능 — 확인 후 '중복확인' 표시하여 재업로드"). 양식에 `중복확인` 컬럼(confirm) 추가로 형제 등록 의사를 명시 받는 방식이 행 단위 재업로드 흐름과 정합.

### [WARNING-1] F1 온보딩 무결성 — app/controllers/onboarding_controller.rb:12-24, app/models/tenant.rb:19-20

- `update`는 현재 진행 스텝과 무관하게 2~5 임의 스텝 PATCH를 수용함 → 2스텝(사업자 정보)을 건너뛰고 바로 5스텝으로 온보딩 완료 가능.
- `Tenant` 검증이 `business_number` 형식만(allow_nil)이고 상호 외 사업자 정보(업종·대표자명·주소·계좌)에 presence가 없어, 정상 경로로도 빈 채 완료 가능(폼은 HTML required 없음 — step2/3 뷰에 required 속성 부재).
- 부수: 온보딩 미완료 테넌트도 `/students`에 접근 가능(`redirect_if_onboarding_incomplete`는 dashboard#show에만 적용).
  > **수정 완료** (2026-10-20, W1FixDev) — ① 스텝 우회 방지: `OnboardingController#restrict_step_range`(app/controllers/onboarding_controller.rb:32-40)가 show/update 공통으로 현재 `onboarding_step`+1 초과 스텝을 현재 스텝으로 리다이렉트, `advance_step`은 상향만 허용해 재제출에 의한 스텝 후퇴 차단(76-80). ② 사업자 정보 presence: `Tenant` 컨텍스트 검증 `validates name/business_number/business_type/owner_name, presence: true, on: :business_info`(app/models/tenant.rb:22-23) + `save_business_info`에서 `valid?(:business_info)` 선행(app/controllers/onboarding_controller.rb:42-55), step2 뷰 required 속성·오류 표시 추가. /students 온보딩 게이트는 미적용(W1 임의 생략 아님 — 미완료 테넌트는 로그인 리다이렉트로 온보딩 화면에 머무는 흐름이며, 원생 데이터는 연습/실 모두 온보딩 완료 후 진입하도록 UI가 유도됨. 리스크는 낮으나 완전 차단은 후속 이슈로 권장).
- W1 런타임에는 치명적이지 않으나 사업자 정보는 F1 핵심 수집 항목이며 W3 현금영수증 연동(NEEDS_INFO 상태)·안내 문구의 기반 데이터. 서버측 완결성 보장 필요.

**수정 제안**: ① `update`에서 `@step`이 허용 스텝(현재 `onboarding_step` 이하 1 단계)인지 검증해 위반 시 리다이렉트. ② 스텝 2 저장 시 `business_number/business_type/owner_name` presence(컨텍스트 검증), 스텝 3 저장 시 계좌 3필드 presence. ③ StudentsController 등에도 `redirect_if_onboarding_incomplete` 적용 검토.

### [WARNING-2] 납부일 규칙 불일치(1~31 vs 1~28) — app/models/student.rb:13 vs app/services/students_csv_import_service.rb:11

모델은 `inclusion: 1..31`, CSV·폼 UI는 1~28을 강제함. `payment_day=30` 등은 폼 POST(JSON/직접 요청)로 저장 가능해 경로별 규치이 어긋남. 납부일은 리마인더 스케줄(F6 D+3/D+7)의 기준값이므로 단일 규칙으로 수렴 권장 — **모델을 1..28로 일원화**(UI·CSV 안내 문구가 이미 1~28).
> **수정 완료** (2026-10-20, W1FixDev) — `Student::PAYMENT_DAY_RANGE = (1..28)` 상수 정의(app/models/student.rb:8-9), 모델 검증이 상수 사용(13). CSV 서비스는 `PAYMENT_DAY_RANGE = Student::PAYMENT_DAY_RANGE`로 동일 상수 참조(app/services/students_csv_import_service.rb:11) — 모델·CSV 단일 기준.

### [WARNING-3] N+1 쿼리 — app/views/students/index.html.erb:46, app/models/student.rb:20

목록이 `includes(:guardians)`로 로드한 뒤 `student.primary_guardian`(`guardians.where(...)` 재질의)를 행마다 호출 → 원생 수만큼 추가 쿼리. `primary_guardian`을 로드된 컬렉션 기반으로 변경(`guardians.load_target` 이후 Ruby 선택, 또는 `guardians.to_a.find { |g| g.is_primary? }`)하면 `includes` 캐시를 재사용함. `sibling_student_ids`(전 테넌트 재조회+복호화)도 목록 요청마다 실행되므로 W2 원생 수 증가 시 캐시/컬럼화 재검토(개발자가 표기한 열린 이슈와 동일 방향).
> **수정 완료** (2026-10-20, W1FixDev) — `Student#primary_guardian`을 `guardians.to_a` 기반 Ruby 선택으로 변경(app/models/student.rb:23-27) — `includes` 캐시 재사용, 행마다 추가 쿼리 없음. `sibling_student_ids` 전 테넌트 재조회는 기존 열린 이슈(결정론적 해시 컬럼)대로 W2 재검토 대상 유지.

### [WARNING-4] 인증 경화 최소치 — app/controllers/sessions_controller.rb:8-16

bcrypt+최소 8자 정책은 W1 최소 요건 충족. 다만 로그인 실패 횟수 제한·계정 잠금이 없어 온라인 대입이 무제한 허용됨(본인인증 완화 상태로 번호=계정명인 점이 가중). W2 이내 Rack::Attack 등 속도 제한 도입 권장. 오류 메시지 단일화(열거 방지)와 세션 재발급(고정 방지)은 양호.
> **수정 완료** (2026-10-20, W1FixDev) — Rails 8 내장 `rate_limit to: 10, within: 3.minutes, only: :create`를 SessionsController에 적용(app/controllers/sessions_controller.rb:5). 계정 잠금은 W2 과제로 유지.

### [WARNING-5] params 견고성 — 런타임 500 3곳

- sessions_controller.rb:9,11 — `params[:session][:phone_number]`: `session` 파라미터 누락 요청 시 NoMethodError 500.
- students_controller.rb:113 — `params[:q].strip`: `?q[]=a` 배열 주입 시 NoMethodError 500.
- students_controller.rb:68 + import — `params[:file]`이 문자열이면 `upload.read`에서 500.

모두 정상 폼 흐름 외 변조 요청이지만 500 대신 400 처리가 적절. `params.expect(session: [:phone_number, :password])`, `params[:q].to_s.strip`, `upload.respond_to?(:read)` 가드 제안.
> **수정 완료** (2026-10-20, W1FixDev) — ① sessions#create가 `params.expect(session: [:phone_number, :password])` 사용(app/controllers/sessions_controller.rb:12) → `session` 파라미터 누락 시 400. ② 검색어는 `params[:q]`가 String인 경우에만 strip 적용(app/controllers/students_controller.rb:130-132) → 배열 주입 무시. ③ `upload.respond_to?(:read)` 가드(students_controller.rb:71-74) → 파일 필드 문자열 변조 시 422.

### [WARNING-6] 가입 유니크 레이스 — app/controllers/registrations_controller.rb:26

동일 휴대폰번호 동시 가입 시 검증은 통과하나 DB 유니크 인덱스에서 `RecordNotUnique` 발생 → `rescue ActiveRecord::RecordInvalid`에 걸리지 않아 500. `rescue ActiveRecord::RecordNotUnique => 422` 병기 제안.
> **수정 완료** (2026-10-20, W1FixDev) — `rescue ActiveRecord::RecordNotUnique` 별도 절 추가 → "이미 가입된 휴대폰번호입니다. 로그인해 주세요."(ko.yml `registration.duplicate_phone`) 422 렌더(app/controllers/registrations_controller.rb:29-32).

---

## 2. Rule ID 적합성 요약 (전수 확인 결과)

|Rule|판정|근거|
|:---|:---|:---|
|TEN-001|**적합**|전 컨트롤러 `current_tenant` 스코프. `set_student`는 `current_tenant.students.find(params[:id])`(students_controller.rb:110) → 타 테넌트 id 접근 404. nested guardians의 `id` 위조도 소속 원생 스코프라 타 테넌트 참조 불가. CSV 생성도 `@tenant.students.build`.|
|TEN-002|**적합**|주민번호·과도 개인정보 필드 전무(schema·폼·CSV 양식 8컬럼 확인).|
|TEN-003|**적합**|User deterministic 암호화+유니크 인덱스(users), Guardian 비결정+last4(PRD 14장 확정사항과 일치). 목록·상세·형제 배지 전 구간 `masked_phone`만 표시 — 평문 노출 뷰 없음. CSV 양식은 예시데이터만, 오류 CSV는 원장 본인 입력값 반환(타인 데이터 유출 없음). 로그 필터(:passw) 확인.|
|TEN-004|**해당 없음(W2)**|청구 스냅샷은 W2 마이그레이션 범위 — F2 보고대로 상세 화면 안내로 분리 명확.|
|INV-004|**적합(기반)**|`Student.active = where(status: :active)`, 상태 enum 재원/휴원/퇴원. `sync_ended_on` before_save로 ended_on 기록·해제 정합. W2 청구 생성이 이 스코프만 사용한다는 계약은 코드 주석으로 명시됨.|
|SUB-001|**계획대로 미구현**|W4 예정 — 컨트롤러 상단 주석 명시.|
|F1 수용조건|대체로 적합|스텝 4개(6 이하)·이탈 재개 리다이렉트·사업자번호 형식 검증·연동 전 발행 비활성 안내(step4)·연습 모드 무외부호출(외부 호출 코드 자체가 부재)·샘플 데이터 memo 구분. 단 WARNING-1(완결성 강제) 미충족.|
|F2 수용조건|**부분 미충족**|오류행 재업로드 흐름 자체는 동작하나 BLOCKER-1로 대량 오류 시 파괴됨. 중복 경고는 CRITICAL-1. 나머지(비활성 이력 보존·원비 스냅샷 분리·CSV 무실데이터) 적합.|
|13.4 정직성|**적합**|"이번 달 대기" 배지는 F2 명세 배지 어휘의 초기값이고, 상세 화면에 "청구 기능은 다음 업데이트에 제공됩니다" 명시 — 미구현 기능을 구현된 것처럼 표시하지 않음. 연습 모드 안내문·CP949 보류 안내도 정직함.|
|Turbo 규약|**적합**|실패 전면 422, 성공 `redirect_to status: :see_other`(303). 뷰에서 DB 직접 쿼리 없음(모델 메서드·할당변수만).|
|상태 전이|**적합**|PRD 9장은 원생 상태 머신을 별도 정의하지 않음(9장은 청구·영수증·메시지). 휴원/퇴원→복원 전이 + ended_on 동기화는 F2 명세와 정합.|

### F2 개발자의 F1 버그 픽스 검증 — **정합**

`@tenant.users.build(user_params)`(registrations_controller.rb:17): tenant 필수 검증을 통과시키는 올바른 최소 수정. Tenant+User가 단일 트랜잭션으로 저장되고, 선행 `invalid?` 검사 + `RecordInvalid` rescue로 실패 시 422 렌더(데이터 반쪽 저장 없음). 부작용 없음 — 잔여 리스크는 WARNING-6(레이스 500)뿐.

---

## 3. 테스트 제안 (Rule ID) — Tester 전달

1. **[BLOCKER-1] CSV 대량 오류**: 헤더를 오타한 20행 CSV 업로드 → 500(CookieOverflow) 재현 → 수정 후 오류 상한/서버 저장 동작 검증. 정상행 부분 반영 결과도 함께 확인.
2. **[CRITICAL-1] CSV 중복**: 동일 파일 2회 업로드 → 중복 원생 생성 차단/경고 검증. 수정 후 오류행 사유에 중복 안내 포함 확인.
3. **TEN-001**: 테넌트 A 세션으로 B의 `/students/:id`, `/students/:id/pause`, 타 테넌트 guardian id를 nested attributes로 주입 → 전부 404/무관함 확인.
4. **TEN-003**: guardians·users raw 암호문 저장, 목록/상세/오류 CSV에 전화 평문 부재, `phone_last4` 4자리 검색 동작.
5. **INV-004**: 휴원·퇴원 원생이 `Student.active` 제외되는지(서비스 레벨), 복원 시 ended_on=nil, 재휴원 시 최초 휴원일 보존(`||=`) 확인.
6. **F1 온보딩**: 중단 후 재로그인 시 미완료 스텝 재개, 각 스텝 유효성 실패 422+오류 문구, (수정 후) 스텝 건너뛰기 차단·사업자 정보 빈값 거부.
7. **인증/세션**: 로그인 성공 시 session_id 재발급(고정 방지), 미인증 전 경로 302→로그인, 로그인 실패 메시지 단일화, 비밀번호 7자 거부/8자 승인.
8. **파라미터 견고성**(수정 후): `POST /session` 본문 없음→400, `?q[]=`→정상 처리, 파일 필드 문자열→422.
9. **상태 변경 경로**: pause/withdraw/restore PATCH 각각 ended_on·배지·로케일 문구 확인, 존재하지 않는 상태 전이 PATCH → 404(enum ArgumentError 아닌 정상 거부).

---

## 4. 재검증 범위 (수정 후)

- BLOCKER-1: students_controller#import + 세션/저장소 분리(또는 상한 가드) + 파일 크기·행 수 제한.
- CRITICAL-1: students_csv_import_service#import_row 중복 검사 + (채택 시) 양식 confirm 컬럼.
- WARNING-1~6은 재검증 대상이나 APPROVED 판정에는 영향 없음(기록·후속 개선).

---

# W1 재리뷰 보고 — Phase 6 수정분 (리뷰 루프 2/2)

- 작성: wonbikok-reviewer(W1Rereview) / 2026-10-20
- 검증 방법: 수정 지점 전수 코드 확인 + `bin/rails runner` 통합 스모크(온보딩 재로그인 흐름 — HTTP 상태 코드 실측, 스모크 데이터 완전 클린업: tenants=0/users=0/sessions=0)

## 리뷰 상태: **CHANGES_REQUESTED**

- 1차 지적 BLOCKER-1·CRITICAL-1 및 WARNING 6건 모두 **해소 확인**. 그러나 회귀 조사(수정 파일 주변)에서 **신규 CRITICAL 1건** 발견 — 루프 2/2 최종 판정이므로 아래에 기록·범위 확정함.
- 신규 CRITICAL은 F1 시절부터 존재한 결함으로 Phase 6 수정으로 인한 회귀가 아님. 수정은 2개 리다이렉트 지점의 클램프 2줄이 전부.

## 1. 이슈별 검증 결과 (1:1)

|1차 이슈|판정|근거|
|:---|:---|:---|
|**BLOCKER-1** CSV 오류내역 세션 저장|**해소**|① 세션은 키만 보관: `session[:csv_import_errors_key] = key`(students_controller.rb:121). ② 테넌트별 키 분리: `csv_import_errors:{tenant_id}:{urlsafe_base64(16)}` — 128비트 랜덤 + signed 쿠키 세션으로 타 테넌트 키 위조·추측 불가 → TEN-001 충족(students_controller.rb:117). ③ 만료·부재 경로: 캐시 조회 실패 시 `expired` 안내 후 리다이렉트(98-101), 키 없는 직접 접근도 `nil.to_s`로 동일 분기 — 500 없음. ④ 1MB 상한: 초과 시 `file_too_large` 422(74-77), `respond_to?(:read)` 가드 422(70-73). ⑤ 프로덕션 캐시 스토어 = `solid_cache_store`(config/environments/production.rb:50) — 재시작에도 30분 내내역 유지. **단, test 환경은 `:null_store`(config/environments/test.rb:23)라 통합 테스트로는 만료 분기만 검증 가능 — Tester 시나리오에 주의 표기(§4).**|
|**CRITICAL-1** CSV 중복 검사 부재|**해소**|① 수동 등록과 동일 기준: `import_row`가 `GuardianDuplicateFinder#conflicts_with` 호출(students_csv_import_service.rb:47-48) — 컨트롤러 수동 경로와 동일 메서드·동일 정규화(전화 숫자 정규화·공백 제거 이름 포함 비교). ② 중복 의심 행은 오류행 전환(49-54), `build_student` 미호출 → 데이터 오염 없음. ③ 동일 파일 내 중복도 포착 — 행 단위 즉시 반영 + `@tenant.students.build`가 메모리 타깃에 추가되어 후속 행의 재조회에 반영. 스모크(개발자)도 "중복 의심 — 기존 원생 김철수과(와)..." 사유 확인. ④ Finder 1회 생성: 로직 인스턴스는 1회이나 **쿼리는 행마다 발생**(§2 성능 잔여 참조).|
|**WARNING-1** 온보딩 스텝 우회·presence|**부분 해소**|다중 스텝 우회 차단 ✅: `restrict_step_range`(onboarding_controller.rb:34-40)가 show/update 공통 적용, 2스텝에서 5스텝 직행 차단. 사업자 presence ✅: `on: :business_info` 4필드(tenant.rb:22-23) + `valid?(:business_info)` 선행(onboarding_controller.rb:44-47) + step2 뷰 required·오류 표시(단, `name` 필드만 required 속성 누락 — 서버 검증은 존재). 잔여 2건 §2 참조.|
|**WARNING-2** 납부일 1..31/1..28 불일치|**해소**|`Student::PAYMENT_DAY_RANGE = (1..28)` 상수(student.rb:8-9), 모델 검증이 상수 사용(16), CSV 서비스가 동일 상수 참조(students_csv_import_service.rb:8), 폼 `min:1 max:28`(_form.html.erb:34) — 4개 경로 단일 기준.|
|**WARNING-3** 목록 N+1|**해소**|`primary_guardian`이 `guardians.to_a` 기반 Ruby 선택(student.rb:23-27) — `includes` 캐시 재사용, 행당 추가 쿼리 제거. `sibling_student_ids` 전 테넌트 재조회는 기존 열린 이슈(W2 결정론적 해시 컬럼)대로 유지.|
|**WARNING-4** 로그인 rate limit|**해소**|`rate_limit to: 10, within: 3.minutes, only: :create`(sessions_controller.rb:5) — Rails 8 내장, 캐시 스토어 dev memory/prod solid_cache로 동작. 계정 잠금은 §4대로 W2 과제.|
|**WARNING-5** params 변조 500 3곳|**해소**|① `params.expect(session: [...])` → 누락 시 400(sessions_controller.rb:12). ② 검색어 `is_a?(String)` 가드 → 배열 주입 무시(students_controller.rb:132-134). ③ `respond_to?(:read)` 가드 → 문자열 변조 422(70-73).|
|**WARNING-6** 가입 유니크 레이스 500|**해소**|`rescue ActiveRecord::RecordNotUnique` → `registration.duplicate_phone` 422(registrations_controller.rb:29-32, ko.yml:33 문구 확인).|

## 2. 신규 발견 이슈

### [CRITICAL-2] F1 수용조건 "중단 후 재로그인 시 미완료 스텝 재개" — 온보딩 1스텝 경계에서 자동 재개가 400으로 실패

**현상(스모크 실측)**: 가입 직후(=온보딩 2스텝 제출 전, `onboarding_step=1`) 로그아웃·세션 만료로 이탈한 원장이 재로그인하면:

```
login: 303 → Location: /onboarding/step/1     (sessions_controller.rb:36-40, 무보정 리다이렉트)
GET /onboarding/step/1 → 400                  (onboarding_controller.rb:25-27, step_param이 STEPS=[2,3,4,5] 밖 → BadRequest)
같은 세션에서 GET /students → 200, /onboarding/step/2 → 200  (인증 정상, step=1만 실패)
루트(/) 진입 시도: 302 → /onboarding/step/1   (application_controller.rb:20-23, 동일 무보정 리다이렉트) → 400
```

- **영향**: 가입 직후 이탈자(가장 흔한 이탈 지점)의 자동 이탈 재개·루트 진입이 전부 400 오류 화면. F1 수용조건 "중단 후 재로그인 시 미완료 스텝 재개" 위반. 수동으로 `/onboarding/step/2` 입력 시 복구되나 사용자에게 원인이 노출되지 않음.
- **이력**: F1 코드의 결함(`redirect_after_login`·`step_param` 모두 F1 산출물) — Phase 6 회귀 아님. 1차 리뷰가 2~5스텝 PATCH 우회만 검증한 경계 사각지대.
- **Rule/기준**: F1 수용조건(이탈 재개) — 비즈니스 흐름 오류.
- **수정 제안(2줄)**: 두 리다이렉트 지점에서 대상 클램프 — `[current_tenant.onboarding_step, OnboardingController::STEPS.first].max` (sessions_controller.rb:39, application_controller.rb:23). 또는 `step_param`에서 step 1을 2로 치환.

> **수정 완료** (W1Fix2Dev, 2026-10-20): 제안 방법대로 두 리다이렉트 지점 클램프 적용.
> - app/controllers/sessions_controller.rb:40 — `redirect_after_login`이 공용 헬퍼 `resume_onboarding_step`(sessions_controller.rb:47, `[current_tenant.onboarding_step, OnboardingController::STEPS.first].max`) 사용
> - app/controllers/application_controller.rb:23-25 — `redirect_if_onboarding_incomplete`도 동일 클램프 인라인 적용(STEPS 상수는 OnboardingController 기존 정의 재사용)
> - 검증: `bin/rubocop` 47 files no offenses, `bin/brakeman` no warnings, `bin/rails runner` 부트 OK. 클램프 스모크: step=1 → 2, step=3 → 3(진행자 현재 스텝 유지). step=1 재로그인 시 `/onboarding/step/2` 리다이렉트 → restrict_step_range 허용 범위(≤step+1) 내 200, 400 소멸.

### [WARNING-7] 온보딩 스텝 1단계 선행 제출 허용(잔여)

`allowed_max = current_step + 1`(onboarding_controller.rb:36)라 현재 스텝 제출 없이 **다음 스텝 PATCH가 가능** — 예: 2스텝 미제출 상태에서 3스텝(계좌) 직접 제출 시 `onboarding_step=4`로 진행되어 사업자 정보 검증을 건너뜀. 다중 스텝 우회는 차단되어 원 지적(WARNING-1)의 실질 해소이나, 위조 요청 시 사업자 정보 빈값 온보딩 완료 경로가 남는다. 추가로 스텝 3 계좌 3필드(bank_name/bank_account/account_holder) presence도 미적용(원 제안 항목 중 미반영). W2에서 update 전용 한도(`@step <= onboarding_step`)·계좌 presence와 함께 일괄 검토 권장.

### [WARNING-8] CSV 경로 형제·재업로드 행의 영구 차단(잔여)

CRITICAL-1 수정으로 CSV의 모든 중복 의심 행이 오류행 전환되지만, CSV엔 수동 경로의 `confirm=1`에 해당하는 절차가 없어 **동일 보호자 전화를 공유하는 형제 원생·이미 등록된 행은 재업로드로도 영구히 등록 불가**(오류 사유 안내 후 수동 등록만 가능). F2 "형제 등록 허용"은 수동 경로로 충족되므로 수용조건 위반은 아니나, 1차 리뷰가 제안한 양식 `중복확인` 컬럼은 미채택. W2 CSV 개선 시 confirm 컬럼 또는 안내 문구 보강 권장.

### [WARNING-9] CSV 중복 검사의 행별 전체 재조회(성능, 기록)

`conflicts_with`는 호출마다 `@tenant.students.includes(:guardians)` 전수 조회를 수행 — 행 수 × 테넌트 원생 수. 1MB 상한으로 최대 수백~천 행까지 가능해져 대규모 임포트에서 느려질 수 있음. W1 스케일(수십 명) 허용 범위, W2 원생 수 증가 시 임포트용 캐시 로드(1회 로드 후 행별 메모리 비교) 재검토.

## 3. 회귀·수용조건 검토 (수정 파일 주변)

- **원생 등록**: create 흐름(중복 확인→confirm 저장) 불변, `params.expect(student:)` 전환도 nested `guardians_attributes` 포함 유효 — 기존 동작 유지.
- **검색·필터**: `q` String 가드는 정상 검색(문자열)에 영향 없음, `phone_last4` 4자리 검증·status 화이트리스트 유지.
- **마스킹(TEN-003)**: index/show 전화 `masked_phone` 그대로, 오류 CSV도 원장 입력값 반환 — 평문 노출 증가 없음.
- **테넌트 스코프(TEN-001)**: `set_student`·`filtered_students`·CSV 생성 모두 `current_tenant` 경유 유지, 오류내역 키도 테넌트+128비트 랜덤 — 회귀 없음.
- **F1 수용조건**: 스텝 2~5 재개·우회 차단·사업자 검증은 충족. 단 CRITICAL-2로 1스텝 경계 재개만 깨짐(위).
- **F2 수용조건**: 오류 행 단위 재업로드 흐름은 캐시 이전으로 오히려 강화(대량 오류 시에도 성공). CSV 형제 등록만 WARNING-8 잔여(수동 경로로 대체 가능).
- **Turbo 규약**: import 실패 422 렌더/성공 303·200, 온보딩 실패 422/성공 303 — 유지.

## 4. 기록 예외 2건 사유 검토

- **미완료 테넌트 `/students` 게이트(W1 부수)**: 사유(UI가 온보딩 완료 후 진입 유도, 인증 concern 변경 수반) 타당 — **W2 과제로 유지 무방**. 단 CRITICAL-2 수정이 `redirect_if_onboarding_incomplete`(application_controller)를 건드리므로, W2에서 게이트 적용과 함께 일괄 처리 권장.
- **계정 잠금(WARNING-4)**: rate_limit(10회/3분)으로 온라인 대입 완화 확인 — 잠금 정책 W2 유지 무방.

## 5. 테스트 제안(Rule ID) — Tester 전달 최종본

1. **[CRITICAL-2] 온보딩 1스텝 경계 재개**: 가입 직후(step=1) 로그아웃 → 재로그인 → **400 아님**, `/onboarding/step/2`로 안내. 로그인 후 루트(`/`) 접근도 동일 확인. (수정 전 재현: 재로그인·루트 진입 → 400)
2. **[BLOCKER-1] CSV 대량 오류 + 캐시**: 헤더 오타 20행 업로드 → 500 없음, 오류내역 CSV 재다운로드 20행 일치 → 30분 경과(또는 캐시 삭제) 후 재다운로드 → "만료" 안내·재업로드 유도. 타 테넌트 세션으로 오류내역 키 접근 불가 확인(TEN-001). ⚠️ **test 환경 캐시가 `:null_store`이므로 이 시나리오는 dev runner 스모크 또는 cache_store 지정 통합 테스트로 검증할 것.**
3. **[CRITICAL-1/WARNING-8] CSV 중복**: 동일 파일 2회 업로드 → 2회차 전 행 "중복 의심" 오류·생성 0건. 형제(동일 보호자 전화) 행 → 오류행 전환 확인 + 수동 등록 경로로 형제 등록 가능함을 병행 검증.
4. **[WARNING-1/7] 온보딩 스텝 강제**: 2스텝에서 4·5스텝 GET/PATCH → 현재 스텝 리다이렉트. 사업자 정보 빈값 제출 → 422+필드별 오류. (수정 전 재현: 2스텝 상태에서 step/5 PATCH → 온보딩 완료되던 것 차단)
5. **[WARNING-2] 납부일 일원화**: 폼·CSV·직접 POST로 payment_day=29,31 저장 시도 → 모두 거부, 28 저장 성공.
6. **[TEN-001/003] 회귀**: 테넌트 A로 B의 `/students/:id` 404, 목록·상세 마스킹 전화, `phone_last4` 검색, 오류 CSV에 타 테넌트 데이터 부재.
7. **[WARNING-5/6] 견고성**: `POST /session` 본문 누락 400, `?q[]=` 정상 목록, 파일 필드 문자열 422, 동시 중복 가입 422("이미 가입된 휴대폰번호").
8. **[WARNING-4] rate limit**: 3분 내 11회 로그인 실패 → 429, 정상 계정 로그인은 영향 없음. (test 환경 null store 시 미동작 — dev로 검증)
9. **[INV-004 기반] 상태**: 휴원→복원 ended_on 기록·해제, `Student.active` 제외 — 기존 시나리오 재확인(수정 파일 인접 회귀 방어).

## 판정 요약

- 1차 이슈 8건(BLOCKER 1·CRITICAL 1·WARNING 6): **전부 해소**(WARNING-1은 실질 해소 + 잔여 WARNING-7).
- 신규: **CRITICAL-2 1건**(수정 2줄), WARNING-7·8·9 기록.
- 최종 판정(루프 2/2): **CHANGES_REQUESTED** — CRITICAL-2 수정 후 본 보고서 §5-1 시나리오로 1회 검증만 남음.

---

# W1 최종 검증 — CRITICAL-2 해소 확인 (리뷰 루프 종료)

- 작성: wonbikok-reviewer(W1FinalCheck) / 2026-10-20
- 검증 방법: 수정 2파일 + 인접 경로 전수 코드 트레이스(sessions/application/onboarding/registrations/dashboard 컨트롤러, tenant 모델, routes, db/schema.rb) + grep으로 `onboarding_step_path`·`STEPS` 참조 전수 확인. 판정 기준은 CRITICAL-2 해소 여부 단일.

## 리뷰 상태: **APPROVED**

- **CRITICAL-2 해소 확인**. BLOCKER 0 + CRITICAL 0 → 리뷰 종료. WARNING-7·8·9 및 W2 이관 항목(/students 게이트, 계정 잠금)은 기록 유지로 판정에 영향 없음.

## 1. 검증 항목별 근거

|항목|판정|근거|
|:---|:---|:---|
|① 두 경로 클램프 + STEPS 재사용|**적합**|`sessions_controller.rb:40,47` — `redirect_after_login`이 `resume_onboarding_step`(`[current_tenant.onboarding_step, OnboardingController::STEPS.first].max`) 경유로 리다이렉트. `application_controller.rb:23-25` — `redirect_if_onboarding_incomplete`도 동일 클램프 인라인 적용. `STEPS` 정의는 `onboarding_controller.rb:2` 단 1곳이고 양 지점 모두 `OnboardingController::STEPS` 상수 참조 — 중복 정의 없음(grep 전수 확인). `onboarding_step`은 `default: 1, null: false`(db/schema.rb:62)라 nil 비교 ArgumentError 위험 없음.|
|② 경계 3케이스|**적합**|**step=1 신규 이탈자**: 재로그인 → 303 `/onboarding/step/2`(`[1,2].max=2`) → `skip_if_onboarding_complete` 통과(1<6)·`step_param`(2∈STEPS)·`restrict_step_range`(allowed_max=[1+1,5].min=2, 2≤2) → **step2 렌더 200, 400 없음** — 스텝 1은 가입 자체이므로 실제 미완료 폼인 스텝 2 재개가 정의상 올바른 재개. 루트 `/` → dashboard#show → `redirect_if_onboarding_incomplete` → 302 step/2 → 200. **step=2~5 진행자**: 클램프 무연산(`[3,2].max=3`) → 현재 스텝 유지, 목표 ≤ onboarding_step ≤ allowed_max라 즉시 렌더(리다이렉트 루프 없음). **온보딩 완료자(step≥6)**: 로그인 → `onboarding_complete?` 분기로 root_path, `redirect_if_onboarding_incomplete`는 `return false`(리다이렉트 미적용), 온보딩 직접 접근도 `skip_if_onboarding_complete` → 루트. 부수: 직접 `GET /onboarding/step/1`은 여전히 400이나(step_param 가드, 의도적 범위 외 거부) 앱 흐름이 그 목표를 생성하는 경로는 전부 제거됨.|
|③ 회귀 상호작용|**부작용 없음**|`restrict_step_range`(onboarding_controller.rb:34-40) 미변경 — 클램프 생성 목표는 항상 `≤ onboarding_step+1`(step=1→2=1+1, step≥2→목표=현재 스텝)이라 전부 허용 범위 내. `rate_limit to: 10, within: 3.minutes, only: :create`(sessions_controller.rb:5)는 인증 성공 후 리다이렉트와 무관 — 리다이렉트 대상 GET은 rate limit 대상 아님. WARNING-5 `params.expect`(sessions_controller.rb:12) 선행 로직 불변. WARNING-1 `advance_step` 상향 전용(78) 불변. 가입 직후 리다이렉트도 명시적 step 2(registrations_controller.rb:25)로 클램프 결과와 일치. 뷰의 고정 `onboarding_step_path(2..5)` 폼 제출은 허용 스텝 렌더 후에만 노출 — 회귀 없음.|
|④ W1Fix2Dev 스모크·코드 일치|**일치**|보고된 클램프 결과(step=1→2, step=3→3 유지), step=1 테넌트의 `/onboarding/step/2` 200·400 소멸은 코드 트레이스 결과와 정확히 동일. 보고된 `restrict_step_range` 정합성 주장도 ②·③ 실측과 부합.|

## 2. Tester 전달 시나리오 최종본 (기존 §5 + CRITICAL-2 반영, 리뷰 종료판)

1. **[CRITICAL-2, 검증 완료·재확인용] 온보딩 1스텝 경계 재개**: 가입 직후(step=1) 로그아웃 → 재로그인 → 400 아님, `/onboarding/step/2` 303→200으로 스텝 2 재개. 재로그인 후 루트(`/`) 접근도 동일(302 step/2). step=3 진행자 재로그인 → step 3 유지. 온보딩 완료자 재로그인 → 대시보드(온보딩 리다이렉트 없음). (수정 전 재현: 재로그인·루트 → 400)
2. **[BLOCKER-1] CSV 대량 오류 + 캐시**: 헤더 오타 20행 업로드 → 500 없음, 오류내역 CSV 재다운로드 20행 일치 → 30분 경과(또는 캐시 삭제) 후 재다운로드 → "만료" 안내·재업로드 유도. 타 테넌트 세션으로 오류내역 키 접근 불가(TEN-001). ⚠️ test 환경 캐시 `:null_store` — dev runner 스모크 또는 cache_store 지정 통합 테스트로 검증.
3. **[CRITICAL-1/WARNING-8] CSV 중복**: 동일 파일 2회 업로드 → 2회차 전 행 "중복 의심" 오류·생성 0건. 형제(동일 보호자 전화) 행 → 오류행 전환 + 수동 경로로 형제 등록 가능 병행 검증.
4. **[WARNING-1/7] 온보딩 스텝 강제**: 2스텝에서 4·5스텝 GET/PATCH → 현재 스텝 리다이렉트. 사업자 정보 빈값 제출 → 422+필드별 오류.
5. **[WARNING-2] 납부일 일원화**: 폼·CSV·직접 POST로 payment_day=29,31 저장 시도 → 모두 거부, 28 저장 성공.
6. **[TEN-001/003] 회귀**: 테넌트 A로 B의 `/students/:id` 404, 목록·상세 마스킹 전화, `phone_last4` 검색, 오류 CSV에 타 테넌트 데이터 부재.
7. **[WARNING-5/6] 견고성**: `POST /session` 본문 누락 400, `?q[]=` 정상 목록, 파일 필드 문자열 422, 동시 중복 가입 422("이미 가입된 휴대폰번호").
8. **[WARNING-4] rate limit**: 3분 내 11회 로그인 실패 → 429, 정상 계정 로그인 영향 없음. (test 환경 null store 시 미동작 — dev로 검증)
9. **[INV-004 기반] 상태**: 휴원→복원 ended_on 기록·해제, `Student.active` 제외 재확인.

## 3. 판정 요약

- CRITICAL-2: **해소** — 2파일 클램프 적용·STEPS 단일 상수 재사용·경계 3케이스·회귀 무·스모크 일치, 4개 항목 전부 적합.
- 최종: **APPROVED** — W1 리뷰 종료. WARNING 3건(7·8·9)과 W2 이관 2건(/students 온보딩 게이트, 계정 잠금)은 기록으로 존속하며 후속 웨이브 처리 대상.
