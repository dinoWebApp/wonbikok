# 리뷰 결과: 랜딩페이지 + 전체 퍼블리싱 리디자인 (Phase 5, 2026-11-04)

> Reviewer(wonbikok-reviewer) 산출 — 읽기 전용 프로필이라 오케스트레이터가 전문을 대신 기록함.

## 총평: **CRITICAL (수정 필요)** — `CHANGES_REQUESTED`

BLOCKER 0 / **CRITICAL 1** / WARNING 4 / INFO 5. CRITICAL 1건은 `config/initializers` 1라인 수정으로 해소되며, 해당 수정 확인 시 재리뷰 전 범위 통과 가능(나머지는 Phase 6에서 권고 수준 반영).

## 지적 사항

### 1. [CRITICAL] TEN-003/테넌시·개인정보 — `config/initializers/filter_parameter_logging.rb:8` — 베타 신청 연락처가 요청 로그에 평문 기록됨

- `filter_parameters`의 `:email`은 키명에 "email"을 포함할 때만 마스킹한다. 베타 폼 파라미터는 `beta_application[contact_value]`이므로 **이메일·휴대폰번호 평문이 production(info 레벨) 요청 로그에 그대로 남는다.** DB는 `encrypts deterministic`으로 암호화했으나(TEN-003) 로그라는 제2의 평문 저장소가 생기는 것으로, 폼 하단 "부가 정보는 따로 저장하지 않습니다"(ko.yml:687) 고지와도 모순. 리뷰 체크리스트 "로그·예외 메시지에 개인정보 원문 없음" 명백 위반.
- **수정**: 배열에 `:contact_value, :phone_number` 추가(기존 sessions/registrations의 `phone_number` 평문 로그 — 선결 문제도 동시 해소). 1라인 수정.

### 2. [WARNING] TEN-003 준용·멱등성 — `db/migrate/20261104000001_create_beta_applications.rb:23`, `app/controllers/beta_applications_controller.rb:42-44` — 중복 신청 감지에 경쟁 조건

- 중복 판정이 `exists?` 조회뿐이고 인덱스가 non-unique다. 동시 제출(더블클릭 등) 시 두 요청 모두 조회를 통과해 동일 연락처 레코드 2건 생성 가능.
- **수정 권고**: `[contact_type, contact_value]` **유니크** 인덱스(deterministic 암호화라 동일 평문=동일 암호문으로 유니크 동작) + `create`에서 `ActiveRecord::RecordNotUnique` rescue → 완료 화면 303으로 멱등 종결. 운영 데이터 아직 없으므로 마이그레이션 부담 없음.

### 3. [WARNING] 13.4 카피 원칙 — `config/locales/ko.yml:540, 583-584`, `app/views/landing/_pricing.html.erb:19,34` — 현금영수증 "준비 중" 병기가 features 섹션에만 있음

- `solution.step2_copy`("체크하면 현금영수증 발행과… 즉시 처리됩니다"), `demo.step3/step4`(발행·발행 완료 알림톡 도착), pricing "소득공제용 현금영수증: 지원" 행은 현재 제공 전 기능을 한정 없이 서술. PRD 13.4는 미제공 기능의 "명확히 제외 또는 '준비 중' 표기"를 요구.
- **수정 권고**: `step2_copy`에 "(현금영수증 연동 준비 중)" 병기, pricing 해당 행 값을 "지원 (연동 준비 중)"로. demo는 note 문구로 뒷받침되므로 선택.

### 4. [WARNING] 코딩 컨벤션(문구 ko.yml 관리) — `app/models/beta_application.rb:5-6`, `app/views/beta_applications/_form.html.erb:28,59` — 선택 옵션 라벨이 모델 상수 하드코딩

- `TITLE_OPTIONS`/`ACADEMY_TYPE_OPTIONS`의 한글 문자열이 그대로 UI 라벨로 렌더된다. 같은 폼의 `student_count_range`는 "키 저장 + ko.yml 라벨" 방식이라 같은 폼 안에서 두 방식이 혼재. AGENTS.md "문구는 ko.yml 관리" 규칙 위반 소지.
- **수정 권고**: 두 필드도 키 상수 + `enums.beta_application.*` 라벨 매핑으로 통일(데이터 없는 시점, 전환 비용 최소).

### 5. [INFO] 15.4/13.7 접근성 — `app/views/beta_applications/_form.html.erb:53-54` — 연락처 입력이 전화 선택 시에도 `autocomplete="email" inputmode="email"` 고정

- 전화 선택 시 숫자 키패드가 뜨지 않는다(40~60대 사용성). 라디오에 따라 두 입력 전환 또는 중립 속성(`inputmode="text"`)으로 완화 검토.

### 6. [INFO] 13.8/운영 — `config/locales/ko.yml:499` — `support@wonbikok.kr` 플레이스홀더

- 실제 수신함 존재 확인 전 공개 배포 시 문의 미달 위험. 배포 전 체크리스트에 1키 교체 항목 반영 필요.

### 7. [INFO] 아키텍처 — `app/views/invoices/index.html.erb:58` — 뷰에서 `current_tenant.invoices.for_month(@month).READY.find_each` 직접 쿼리

- 기존 코드 그대로 유지된 것(본 변경 범위 밖). W3 청구 확장 시 컨트롤러 이관 권고.

### 8. [INFO] 13.7 — `ApplicationController`의 `allow_browser versions: :modern`이 공개 랜딩·베타 폼에도 적용

- 타깃 연령(40~60대) 일부 구형 기기에서 랜딩 자체가 차단될 수 있다. Landing/BetaApplications 컨트롤러에서 완화 검토 권고(현장 데이터 확보 전까지 유지도 합리적 선택).

### 9. [INFO] 카피 유지보수 — `config/locales/ko.yml:555,593` — 목업 문구 "11월 원비" 고정 월 표기

- 시간 경과 시 부자연해진다. 실에셋 교체 시점에 함께 정리.

## 준수 확인 (긍정 검증)

- **라우팅·인증 게이트**: `/`=랜딩(비인증 렌더, 인증 303 `/dashboard`), 비인증 `/dashboard`→로그인 리다이렉트, 온보딩 미완료 분기 유지. Landing/BetaApplications 양 컨트롤러 인증 게이트 skip 정상 — 구멍 없음.
- **TEN-002**: 폼 필드 = 13.6 요구와 정확 일치(초과 수집 없음, 주민번호·IP·UA 없음).
- **TEN-003**: `encrypts :contact_value, deterministic: true` + with_contact 스코프 동등 조회, 완료 화면·목업에 실 연락처 노출 없음.
- **공개 라우트 노출 범위**: `beta_applications`는 new/create/done뿐 — 조회·타 테넌트 접근 경로 없음.
- **mass assignment**: `params.expect` 허용 목록 = 스키마와 정확 일치. **주입**: `html_safe`/`raw` 전 뷰 0건, 외부 링크 `rel="noopener"`.
- **Turbo 규약**: create 성공 303(PRG) / 검증 실패 422 랜딩 재렌더 — 준수. rate_limit 10회/1시간(IP) 동작.
- **리디자인 범위 순수성**: 컨트롤러 변경은 리다이렉트 경로 1라인씩(타당). invoices/reminders/students 뷰는 마크업 전용 변경 확인. 테스트 3파일 기계적 치환 확인.
- **PRD 정합**: 요금제 11.1 표 일치, 규제·FAQ 8문답·페인 카드 13.3 시안 그대로, 푸터 임의 법정 고지 없음(13.8), 외부 트래킹 0·data-event만(13.5), "설계 목표" 각주(13.4), 후기·인증마크 없음.
- **16장 디자인**: 배지 색+텍스트 병행, 금액 tabular-nums 우측 정렬, 44px/주 CTA 48px, 16.2 톤 매핑 준수, Pretendard CDN+폴백.
- **마이그레이션·schema.rb 동기화** 확인. I18n 목업 rows 심볼 키 구조 러너 실증.

## 검증 방법

전체 git 미커밋 변경 대상: 신규 파일 전수 열독(컨트롤러 2·모델·마이그레이션·랜딩 뷰 14·shared 파셜 8·레이아웃 2·tailwind 설정), 수정 파일 git diff 검토(routes/schema/controllers/tests/css + 대표 뷰 6종), grep 스캔(root_path 잔존/html_safe·raw/뷰 내 위험 패턴/filter_parameters), PRD 11·13·15.4·16·22.1 원문 대조, I18n 반환 구조 러너 확인. 테스트 실행 안 함(Phase 4 통과 전제).

## Phase 6·7 전달

- **Developer(Phase 6)**: CRITICAL-1 필수(1라인). WARNING 2·3·4 권고(반영 시 이슈 재검 불필요, 마이그레이션 변경분만 확인).
- **Tester(Phase 7)**: BetaApplication 신규 테스트(유효성·동의·암호화 저장·중복 303·rate limit) 착수. CRITICAL-1은 로그 마스킹이라 자동화 밖 — 수동 확인 1회 권고. 반응형 360px·헤더 CTA 실기기 확인 권고.
