# W1 플랜 — 온보딩·사업자 연동(F1) + 원생 관리(F2)

- 작성: 오케스트레이터 / 2026-10-20
- pipelineType: **full** (신규 엔티티 4종, 마이그레이션 5건, 30파일 내외 → Full Pipeline)
- PRD 근거: 7장 F1·F2, 9장 상태 모델, 14장 데이터 모델, 15장 NFR, 18.1 W1, 22장 Rule ID

## 0. 컨텍스트 확인 결과

- `.omp/progress.json`: `currentPhase: null` → 신규 작업
- git status: clean (최종 푸시 da3c9bc 이후 변경 없음)
- `_workspace/`: `.gitkeep`만 존재 → `_workspace_prev/` 이동 불필요 (실질 빈 상태)
- 인증 관련 기존 코드 없음, bcrypt 미포함(Gemfile 주석 상태) → 추가 필요

## 1. 작업 범위

### F1. 온보딩 & 사업자 연동 (PRD 7장 F1)

- **회원가입·로그인**: 휴대폰번호 + 비밀번호 세션 인증(원장 = 계정 소유자).
  - 결정(오픈 이슈 #8 완화 옵션): 포트원 본인인증은 W3 이후 별도 도입. W1은 휴대폰번호 기반 가입+후행 인증 자리만 확보. bcrypt(has_secure_password) 사용.
- **사업자 정보 등록**: Tenant — 상호, 사업자등록번호(형식 검증), 업종(교습소/공부방/예술·체육), 대표자명, 사업장 주소.
- **납부 계좌 등록**: Tenant — 은행, 계좌번호, 예금주.
- **현금영수증 연동**: W1은 연동 상태 필드(`cash_receipt_link_status: pending`)와 비활성 안내 UI만. 실연동은 W3(F5).
- **온보딩 마법사**: 5스텝(가입 → 사업자 정보 → 납부 계좌 → 안내·연동 상태 → 연습 모드 시작), `onboarding_step` 저장으로 이탈 재개(수용조건: 6스텝 이하·재개).
- **연습 모드**: `Tenant.practice` 플래그 + 샘플 원생 10명 자동 생성(이름·금액·상태 다양화). 연습 모드에서 외부 발송·발행 0건(F1 수용조건 — 외부 연동 자체가 W1 범위 밖이므로 구조상 보장).

### F2. 원생 관리 (PRD 7장 F2)

- **Student CRUD**: 원생명, 학년/학교(선택), 월 기본 원비(원 단위 integer), 납부일, 납부 유형(계좌이체/현금), 메모, 상태(재원/휴원/퇴원 — PRD 9장), 시작일·종료일(선택).
- **Guardian**: 대표 보호자 1명 폼 처리(MVP), 모델은 `has_many` 확장 가능 설계. 이름 + 휴대폰번호.
- **개인정보 보호(TEN-003)**: 보호자 휴대폰번호 Active Record Encryption 저장, 목록은 마스킹 표시(`010-****-5678`).
- **목록**: 검색(이름·전화번호 뒷자리), 상태 필터, 이번 달 상태 배지(대기 — 청구는 W2), 카드형 리스트.
- **CSV 일괄 등록**: 양식 다운로드 + 업로드 + 행별 오류 리포트 + 오류행만 재업로드(수용조건). Service 객체로 분리.
- **형제 중복**: 동일 보호자 번호로 복수 원생 등록 허용 + 안내 배지.
- **중복 경고**: 저장 전 유사 이름·연락처 경고.

## 2. 대상 파일 (신규 중심, ~30건)

| 레이어 | 파일 |
|:---|:---|
| Gemfile | bcrypt 추가 |
| 마이그레이션 5 | create_tenants(name, business_number, business_type, owner_name, address, bank_name, bank_account, account_holder, practice, onboarding_step, cash_receipt_link_status) / create_users(tenant_ref, phone_number[암호화], password_digest, role) / create_sessions / create_students(tenant_ref, name, grade, monthly_fee, payment_day, payment_type, memo, status, started_on, ended_on) / create_guardians(student_ref, name, phone_number[암호화], is_primary) |
| 모델 | tenant, user, session, current, student, guardian (+ tenant 스코프 concern 검토) |
| 서비스 | students_csv_import_service(파싱·행별 오류), students_csv_template(양식 생성), practice_data_seeder(샘플 10명) |
| 컨트롤러 | sessions, registrations, tenants/onboarding(스텝 라우팅), students, csv_imports + application_controller(인증 게이트·Current.tenant 주입) |
| 뷰 | sessions/new, registrations/new, onboarding(스텝 폼), students/{index,new,edit,show,_form}, csv_imports/new(결과 리포트), shared/_phone(마스킹 헬퍼) |
| 설정 | config/routes.rb, config/locales/ko.yml(문구 i18n) |
| 테스트 | Phase 7에서 Tester가 작성 |

## 3. Rule ID 목록 (22장)

- **TEN-001**: 전 원장 데이터 Tenant 격리 + 서버측 검증 — 모든 컨트롤러/스코프 적용
- **TEN-002**: 주민번호 수집 금지 — 스키마에 해당 필드 부재 확인
- **TEN-003**: 휴대폰번호 저장 암호화 + 목록 마스킹
- **INV-004**: 휴원·퇴원 원생 제외 — `Student.active` 스코프로 청구 대상 기반 마련(W2 사용)
- **SUB-001**: 원생 수 상한 — 플랜 도입(W4) 전이므로 W1 스킵(계획 명시)
- F1/F2 수용조건 전체(온보딩 스텝·재개, CSV 행별 재업로드, 휴원 제외, 이력 보존 원칙 등)
- 신규 Rule ID 추가 불필요 — 기존 45건으로 커버. 다만 Phase 2에서 구현 확정 사항을 PRD 14장에 반영.

## 4. PRD/AGENTS.md 수정 필요 항목 (Phase 2)

- **PRD.md**: 14장 데이터 모델 — W1 확정 사항 기입(User=휴대폰번호 인증·bcrypt, Guardian 1:N 설계+MVP 대표 1명, onboarding_step/practice 필드, Active Record Encryption 채택), 문서 버전·최종 수정일 갱신
- **AGENTS.md**: 기술 스택에 bcrypt 명시, 구현 진행 상황 표 W1 → 🔄 진행 중

## 5. 에이전트 스폰 계획

| Phase | 에이전트 | 지시 요약 |
|:---|:---|:---|
| 3-1 | wonbikok-developer (신규) | F1: bcrypt 추가, 마이그레이션 5건, 인증(가입/로그인/로그아웃), Tenant+온보딩 마법사, 연습 모드 시더 |
| 3-2 | wonbikok-developer (신규, 3-1 완료 후) | F2: Student/Guardian CRUD+필터, 암호화·마스킹, CSV 양식/업로드/오류 리포트 |
| 4 | 오케스트레이터 | rubocop/brakeman/rails test |
| 5 | wonbikok-reviewer (신규) | F1+F2 전체 리뷰 — 중점: TEN-001/002/003, CSV 오류 처리, 인증 보안 |
| 6 | wonbikok-developer (신규, 필요 시) | 지적 사항 최소 수정 |
| 7 | wonbikok-tester (신규) | TEN-001/003, CSV 행별 오류, 온보딩 재개 시나리오 |
| 8 | 오케스트레이터 | bin/dev 부트 검증 |

## 6. 리스크·모호점

1. **본인인증 미도입**(오픈 이슈 #8): W1은 휴대폰번호+비밀번호. PRD 완화 옵션에 명시된 경로라 스펙 충돌 없음.
2. **Active Record Encryption 키**: Rails 7.1+은 credentials 미설정 시 secret_key_base에서 파생 — Developer가 dev/test 암복호화 동작 검증 필수. 실패 시 credentials 키 추가.
3. **이번 달 상태 배지**: 청구 도메인(W2) 선행 필요 — W1은 '대기' 고정 표시로 UI 자리만 확보.
4. ** 납부일 기본값**: PRD에 예시(25일)만 존재 — 기본값 25일로 구현, 원생별 수정 가능.

## 7. 완료 기준 (PRD 18.1 W1)

- [ ] 샘플 데이터로 원생 10명 등록 동작(연습 모드 시더)
- [ ] CSV 양식 다운로드 → 업로드 → 정상행 반영 + 오류행 리포트 → 오류행 재업로드
- [ ] 온보딩 5스텝 완주 + 중단 후 재접속 시 이어하기
- [ ] 보호자 번호 암호화 저장 + 목록 마스킹
- [ ] 품질 게이트(rubocop 0/brakeman 0/test 통과) + 리뷰 APPROVED
