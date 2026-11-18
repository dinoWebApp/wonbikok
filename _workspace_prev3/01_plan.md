# 01_plan.md — F5 현금영수증 발행 (바로빌 연동)

- 작성일: 2026-11-16
- 모드: 절약 (`/wonbikok_orchestrator_lite` 경유 — 현재 세션 메인 GLM-5.3-Flash, lite 프로필 위임)
- 파이프라인: Full (0→1→✋→2→3→4→5→6?→7→8→9), 직렬 단일 Developer 위임
- 사전 확정 결정: 발급대행 = **바로빌**(계약 체결 완료, 건당 10원, 취소·재시도 과금 가정),
  어댑터 인증키는 credentials `barobill.test_auth_key`(테스트) / `release_auth_key`(운영) 사용

## 1. 요구사항

PRD 7장 F5(현금영수증 발행) 전체. 원장이 입금 확인 시(또는 수동으로) 홈택스 접속·공동인증서 없이
현금영수증이 발행되고 학부모에게 안내가 전송되는 것이 핵심 가치.

- **바로빌 연동 전환**: 기존 설계의 포트원 경로(10.1)를 바로빌 발급대행 API로 교체
  (memory `cash-receipt-provider-decision` — 계약 체결·건당 10원 확정)
- **F4 의존성 처리**: 자동발행 트리거인 "입금 확인"(F4/Payment)은 미구현. 이번 F5는
  (a) Payment 확인 시점 호출용 **트리거 인터페이스**(훅 메서드)만 정의하고,
  (b) **원장 수동 발행** 진입(청구 목록/상세의 발행·재발행 버튼)으로 즉시 사용 가능하게 함.
  F4 본체(매칭 힌트·부분납부·오체크 취소 절차)는 후속 태스크.
- 인증키 운영 보유 상태: credentials에 실제 운영키 등록 완료. dev/test 기본은 SIMULATED,
  실호출(스파이크)은 테스트키+testws로 1회 한정.

## 2. 바로빌 API 매핑 (공식 문서 분석 확정분)

| 기능 | API | 핵심 파라미터/반환 |
|---|---|---|
| 회원사 자동 가입 | `CheckCorpIsMember` → `RegistCorp` (예외 -32000: AddUserToCorp) | CERTKEY+회사정보(업태·전화·이메일 필수)+계정(ID/PWD 6~20자 자동 생성) |
| 발행 | `RegistAndIssueCashBill` | CERTKEY·CorpNum·UserID·CashBillEx·SMSSendYN |
| 상태 동기화 | `GetCashBillState` / `GetCashBillStates` | BarobillState: 1000임시/2000발급완료/2500전송중/**3000전송완료**/4000전송실패/7000취소 |
| 전건 취소 | `CancelCashBillEx` | 원본 MgtKey + CancelMgtKey(새 취소거래 건, 별도 과금 가정) |
| 부분 취소 | `CancelCashBillPartialEx` | + CancelAmount/Tax/ServiceCharge |
| 학부모 조회 | `GetCashBillMailURL`(NK) | 60초 유효 URL |

- CashBillEx 필수: MgtKey(24자 멱등키)·FranchiseCorpNum/MemberID/CorpName/CEOName/Addr/**Tel**·
  IdentityNum·TradeType(N/D)·TradeUsage(1소득공제/2지출증빙)·TradeMethod(5=휴대폰)·Amount·Tax·
  ServiceCharge. 선택: ItemName·HP·Email. 주민번호 미사용(TEN-002).
- **TradeDate는 D-1까지만** — 전월 소급 불가. 발행은 입금확인/수동 트리거 시점 일시 사용.
- 통신: SOAP XML. 우선 바로빌 "직접 HTTP 통신 규격"(Net::HTTP) 구현 — savon 젬은 Ruby 4
  호환 미확인이므로 미채택(기본). 엔드포인트: 테스트 `testws.baroservice.com` / 운영
  `ws.baroservice.com`, 키는 credentials barobill 키와 쌍으로 선택.
- 인증: CERTKEY(연동인증키) = 파트너 키. CorpNum/UserID는 회원사(원장)별 값 → tenants 저장.

## 3. 구현 범위

### 마이그레이션 (1회, 통합 생성)
1. `cash_receipts`: tenant_id·invoice_id·mgt_key(유니크 인덱스)·cancel_mgt_key·
   issue_type(income_deduction/expense_evidence)·state(9.2 상태 enum: needs_info/pending/
   processing/issued/failed/cancel_pending/cancelled)·barobill_state(int)·nts_confirm_num(암호화 아님,
   승인번호)·nts_confirm_message·identity_num(**암호화** — 휴대폰 or 사업자번호, 주민번호 금지)·
   trade_date·amount·tax·service_charge·item_name·issued_at·cancelled_at·retry_count(기본 0)·
   last_error·issued_by(처리자) — CR-001 멱등은 mgt_key 유니크로 보장
2. `tenants` 추가 컬럼: `biz_tel`(사업장 전화)·`biz_type`(업태)·`email`(대표자 이메일)·
   `barobill_corp_num`(사업자번호 — 기존 business_number 재사용 권장, 신규 불필요)·
   `barobill_member_id`(바로빌 ID, 최초 가입 후 불변)·`barobill_joined_at`
3. `guardians`: `business_number`(**암호화** — 지급증명용, TEN-003)
4. `students`: `cash_receipt_issue_type`(기본 income_deduction — 원생별 선택)

### Service / Job
- `Barobill::BaseService` — CERTKEY·엔드포인트 환경 분기(production=운영키+ws, 그 외=test키+
  testws), cert_key 공백 시 **SIMULATED 모드**(외부 호출 없이 결과 시뮬레이션 — 솔라피 패턴 준용)
- `Barobill::CashReceiptService` — issue/lookup/cancel/partial_cancel
- `Barobill::MemberService` — check_member/regist_corp (원장 자동 가입, -32000 처리)
- `CashReceipt::IssueJob` — 트리거 시점 호출: NEEDS_INFO 검사 → PROCESSING → 발행 → 상태 반영.
  실패 시 CR-004(재시도 전 상태 재조회로 중복 배제) + CR-006(자동 재시도 1회 후 원장 이중 알림)
- `CashReceipt::SyncJob` — PROCESSING 건 BarobillState 폴링 → 3000만 ISSUED(승인번호 저장),
  4000 FAILED(사유 저장), 7000 CANCELLED (CR-003: 응답 확인 전 성공 표시 금지)
- `Payment → 발행 훅`: `Payments::ConfirmService`(F4 본체는 후속)가 아니라
  `CashReceipt::Triggerable` 관심사(모듈)로 `trigger_issue_for(payment/invoice)` 인터페이스 정의 —
  F4 착수 시 호출부만 추가. 이번 실행에서는 수동 발행 경로와 테스트로 검증.

### 모델/컨트롤러/뷰 (원장 영역)
- `CashReceipt` 모델: 상태 전이 검증(취소는 원본 연결 CR-005), 마스킹 표시(TEN-003),
  mgt_key 생성 규칙(원생×당월×발급유형, 24자 이내)
- 라우트: `resources :cash_receipts, only: %i[index show]` + 멤버 액션
  `issue`(수동 발행)·`retry`(수동 재발행)·`cancel`(취소 — 사유 필수)
- 뷰: 발행 이력 화면(월별·원생별·상태별 필터, CR 상태 배지 — 16.2 체계), 상세(승인번호·이력),
  수동 발행/재발행 버튼, 취소 폼. `shared/` 파셜·웜 오렌지 토큰 체계 준수
- 온보딩(step3 사업자 정보)에 사업장 전화·업태·이메일 필드 추가 + 가입 시 RegistCorp 시도
  (실패해도 온보딩은 계속 — 재시도는 설정 화면 or 수동) — 최소 변경 원칙
- 학부모 발행 안내: 솔라피 알림톡 템플릿 `cash_receipt_issued`(승인번호·금액) — ko.yml 문구 +
  MessageLog 연동, 테스트는 SIMULATED. 알림톡 실심사 등록은 운영 과제로 병행 표기

### 테스트 (외부 API 실호출 금지 — 바로빌 어댑터는 스텁/시뮬레이션)
- CR-001 mgt_key 유일성(모델 검증+DB 유니크), CR-002 트리거 인터페이스(수납 미확인 건 발행 차단),
  CR-003 3000 이전 ISSUED 금지, CR-004 재시도 전 상태 재조회, CR-005 취소 원본 연결,
  CR-006 실패 재시도 1회+알림, CR-007 대기열 순차 처리(SIMULATED에서 큐 동작)
- TEN-002 주민번호 거부, TEN-003 identity_num 암호문 저장·마스킹 표시, TEN-004 스냅샷 불변,
  TEN-001 타 테넌트 이력 404
- 어댑터: 스텁 응답 파싱(성공/오류코드 -32000/-10001 등), SIMULATED 분기, 환경별 엔드포인트
- 상한/경계: TradeDate D-1 검증(전월 발행 시도 → 거절 안내), 부분취소 금액 검증

## 4. Rule ID

CR-001~007 (핵심), TEN-001/002/003/004, MSG-001/002(학부모 안내 알림톡은 MSG 스택 재사용),
PAY 연계는 훅 인터페이스만. PRD 22장 원문 기준.

## 5. Phase 2 문서 현행화 (Full 필수)

- PRD 10.1: 현금영수증 경로를 포트원 → **바로빌 발급대행**(SOAP, CERTKEY+회원사)으로 교체·보강
  (10.x 신설 권장: 10.3 공통 요구사항 유지). 7장 F5 명세의 "포트원 현금영수증 API" 문구 → 바로빌.
  14장 CashReceipt 데이터 모델·tenants/guardians/students 추가 컬럼 반영. 22장 CR 규칙 유지 확인.
- AGENTS.md: 시스템 구성·외부 연동 표에 바로빌 추가(진행 표는 Phase 9)
- `_workspace/02_prd_update.md` 기록

## 6. 위임 계획 (절약 모드)

| Phase | 프로필 | 작업 |
|---|---|---|
| 3 | wonbikok-developer-lite 1개 | §3 전 범위 단일 위임 (마이그레이션 1회 통합 생성 포함). 산출물 `03_implementation.md` |
| 4 | 오케스트레이터 직접 | rubocop·brakeman·rails test |
| 5 | wonbikok-reviewer-lite 1개 | CR 규칙·TEN 격리·멱등·SOAP 어댑터 검증. `05_review.md` |
| 6 | wonbikok-developer-lite 1개 | 지적 시 최소 수정 |
| 7 | wonbikok-tester-lite 1개 | CR/TEN 시나리오 회귀 + 스텁 기반 신규 테스트. `07_test_report.md` |
| 8 | 오케스트레이터 직접 | 부트 검증 + **스파이크(별도)**: rails runner 1회 — 테스트키+testws로 RegistCorp(원비콕 자체 사업자정보 필요 — 승인 시 제공) + 발행 1건 → GetCashBillState 3000 확인. 사업자정보 미제공 시 스파이크는 보류·보고 |

각 스폰 직후 effort 실측 → `00_delegation_log.md`.

## 7. 리스크

1. **SOAP 직접 구현 난이도** — savon 미채택( Ruby 4 호환 미확인)으로 Net::HTTP+XML 직접 구성.
   응답 파싱 오류 가능성 → 어댑터 단위 테스트로 스텁 XML 고정
2. **F4 미구현으로 자동발행 트리거 부재** — 훅 인터페이스+수동 발행으로 대체. F4 착수 시 연결
3. **운영키 노출 환경** — dev/test 기본 SIMULATED·testws 분기 필수(어댑터 테스트로 검증)
4. **알림톡 템플릿 미심사** — cash_receipt_issued 템플릿은 카카오 심사 필요(운영 과제), 구현은
   SIMULATED
5. **범위 과대(F5 단일 위임)** — 마이그레이션 통합 1회·직렬 단일 위임·Phase 4/5 게이트로 통제
