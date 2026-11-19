# 01_plan.md — 영업 직원·오피서 추천 시스템 (sales/officer 이중 역할)

- 작성일: 2026-11-19
- 모드: 일반(`/wonbikok_orchestrator`) — wonbikok-developer/reviewer/tester
- 파이프라인: **Full 직렬** (0→1→✋→2→3→4→5→6?→7→8→9) — 가입 인증↔추천 코드↔첫 결제 할인↔수수료가
  하나의 가입·결제 체인으로 순차 결합하므로 병렬 분해 부적합(공유: registrations·PaymentService·ko.yml·routes)

## 1. 기획 검토 — 업계 표준 기준 설계 제안

### 1.1 수수료 구조 (업계 표준 조사 기반)

| 모델 | 업계 통례 | 채택 여부 |
|---|---|---|
| 1회성 레퍼럴 보너스 | 첫 결제액의 20~30% 1회 (Dropbox·몇몇 B2C) | ✗ — 요구사항이 "결제액 중 일정 비율 지속" |
| **Recurring 커미션** | 월 결제액의 10~20% · 12개월~평생 (B2B SaaS 제휴·리셀러 표준: PartnerStack 15~25%·국내 SaaS 제휴 10~20%) | ✅ **채택** |

**확정(2026-11-19 사용자 수정 요청 반영): 두 역할 체계 — 단일 `sales_reps` 테이블 + `role` 컬럼**

| | **sales 역할** (영업 직원) | **officer 역할** (지인·감투용) |
|---|---|---|
| 수수료 | **20%** | **15%** |
| 지급 기간 | **12개월 캡** (피판매 테넌트 가입일로부터 12개월 내 결제분만 집계) | **무기한** (구독 유지 중 계속) |
| 타이틀 | 표시용 자유 텍스트("영업 이사" 등 — 대시보드 노출) | 표시용 자유 텍스트("CRO" 등 — 대시보드 노출) |
| 계정·코드·대시보드 | 동일 체계 — 같은 sales_reps 테이블·같은 추천 코드 로테이션·같은 /sales 대시보드 | 〃 |

- `commission_rate`(역할 기본값 sales 0.20 / officer 0.15 — 관리자가 0.05~0.30 범위 조정 가능)·
  `commission_cap_months`(sales 12 / officer nil=무기한)
- **지급 주기: 월 단위 후불** — "이번달 수령액 = 저번달(전월) 확정 결제액 × 비율"
- 수수료 발생 기준: **실제 징수된 manual_payment 금액**(할인 후·취소 제외 — SUB-005 정합)
- 12개월 캡 판정: 피판매 테넌트의 `created_at`(가입일) 기준 — 결제 시점이 캡 내인 경우만 ledger 생성

### 1.2 첫 결제 20% 할인

- 적용점: 피추천 테넌트의 **첫 번째 유료 결제 1회 · 20% 할인**(2026-11-19 사용자 확정 — 할인 후 금액 징수·원가·할인액 기록) — 이후 정상가
- F8 v1.0(수동 결제) 구조에서 `PaymentService` 금액 산정에 적용 — P1 포트원 실결제 전환 시 동일 규칙 이관
- 멱등: 테넌트당 1회(`first_payment_discounted_at` 타임스탬프)

### 1.3 추천 코드 주간 재생성

- 형식: 직원별 `SecureRandom` 8자(대문자+숫자, 예측 불가)·유효기간 7일
- **주간 로테이션 잡**(월요일 09:00 — 발송 없는 배치): 기존 코드 만료 → 신규 발급(직원 화면에 항상 유효 코드 1개)
- 가입 매핑은 **가입 시점 코드 → 직원**(스냅샷 저장)이므로 이후 재생성 영향 없음
- 남용 방지 보조: 코드 유효성 검증(만료 코드 → 가입 거절)·휴대폰 인증(1.4) 이중 방어

### 1.4 휴대폰 인증 가입 (남용 방지)

- 절차: 가입 폼 휴대폰 입력 → **인증번호 6자리 알림톡 발송**(솔라피 — v1.0 SIMULATED·SMS 대체 체계 재사용,
  실제 카카오 인증 템플릿 심사는 운영 과제) → 5분 내 입력 일치 시에만 가입 진행(시도 5회 제한)
- **휴대폰 유일**: 기존 User 검증(deterministic 암호화 + 유니크) 그대로 — 중복 가입 차단은 이미 구축됨
- 인증 레코드: `signup_verifications`(전화·코드·만료·시도·검증완료) — 검증 완료 토큰을 가입 제출에 첨부

### 1.5 영업 직원 계정·대시보드

- `SalesStaff`(이메일+비밀번호·status) — 관리자(AdminUser)와 **별도 인증·별도 네임스페이스 `Sales::`**
  (관리자 권한 없음·OTP 없음 — 제한 계정. 데스크톱/모바일 겸용)
- 직원 스코프 격리: 본인 피판매 테넌트·본인 수수료만 조회(TEN-001 준용 — 타 직원 데이터 404)
- 대시보드: 헤더에 **직함(title) 노출** — ①피판매 사용자 목록(가입일·플랜·상태) ②월별 결제액(피판매 전체 집계) ③**이번달 수령 예상
  (전월 확정 집계 기준)** ④**연도별 누적 수수료**(연도 선택) ⑤현재 유효 추천 코드(복사)
- 관리자 A2 확장: 영업 직원 CRUD(**role·title·수수료율·캡 개월** 설정 포함·정지 사유 ADM-001)·
  직원별 수수료 요약(지급 확정[paid] 처리 포함)

## 2. 데이터 모델 (마이그레이션 1회 통합)

- `sales_reps`: name·email(유니크)·password_digest·role(sales/officer)·title(자유 텍스트 직함)·
  status(active/suspended)·commission_rate(decimal — role 기본 0.20/0.15)·commission_cap_months
  (sales 12 / officer nil)·suspended_reason·타임스탬프
- `referral_codes`: sales_staff_id·code(유니크)·expires_at·replaced_at(로테이션 이력 보존)
- `signup_verifications`: phone_number(정규화·인덱스)·code(해시 저장)·expires_at·attempts·verified_at·consumed_at
- `commission_ledgers`: sales_staff_id·tenant_id·month(YYYY-MM)·base_amount·rate·amount·status(pending/paid)·
  paid_at·source_payment_event_id — [sales_staff_id, month] 조회 인덱스
- `tenants` 추가: referred_by_sales_staff_id·referral_code_snapshot·first_payment_discounted_at

## 3. 구현 범위

### 모델/서비스/잡
- 모델 4종 + Tenant 확장(association·`referred?`)
- `Referral::CodeService`(발급·유효검증·주간 로테이션)·`Referral::DiscountService`(첫 결제 할인 계산·적용 1회)
- `Referral::CommissionService`(결제 시점 ledger 생성[징수액×비율·12개월 만료 확인]·월/연 집계·지급 확정)
- `Signup::PhoneVerificationService`(코드 생성·솔라피 발송[SIMULATED·MSG 규칙 준수]·검증·시도 제한)
- `ReferralCodeRotationJob`(주간)·recurring.yml 등록

### 컨트롤러/뷰
- `Admin::SalesStaffsController`(CRUD·정지 사유 ADM-001·수수료 요약) + admin 뷰(사이드바 항목 추가)
- `Sales::`(base[인증]·sessions·dashboards) + `layouts/sales` + 직원 대시보드 뷰(§1.5 5종)
- 가입 플로우 확장: registrations에 인증 단계(발송·검증 액션 — 검증 완료 시에만 create 허용) + 추천 코드 필드(선택)
- `PaymentService.record_manual!` 확장: 피추천 테넌트 첫 결제 할인 적용 + ledger 생성(원자적)

### 테스트 (외부 실호출 금지 — 솔라피 SIMULATED)
- REF(신규 Rule — Phase 2에서 PRD 22장 추가): 코드 유효성(만료 거절·주간 로테이션)·할인 20% 1회 멱등·
  수수료 정합(징수액 기준·12개월 만료·환불 차감[후속 또는 포함])·직원 스코프 격리·인증 완료 후 가입만·
  시도 5회 제한·휴대폰 유일 회귀
- 관리자 CRUD·정지 사유·가입 플로우 E2E(인증→코드→가입→첫 결제 할인→ledger)·기존 490건 회귀

## 4. Rule ID

**REF-001~007 신규**(Phase 2 PRD 22장 추가) + TEN-001(스코프 확장)·TEN-002/003(전화 정규화·암호화 기존)·
ADM-001(정지 사유)·SUB-005(할인·수수료 금액 정합)·MSG(인증 알림톡 SIMULATED·재시도 제한)

## 5. Phase 2 문서 현행화

- PRD v2.8: 7장 신규 F10(영업 직원·추천 시스템 — 첫 결제 20% 할인 명시) 절 신설·12장 A2 확장(직원 CRUD·수수료)·14장 데이터 모델 4종+
  tenants 컬럼·22장 REF-001~007 신규·11장(할인·커미션 정책 문구 보강)
- AGENTS.md: 도메인 표에 REF 추가·진행 표는 Phase 9

## 6. 위임 계획 (일반 모드)

| Phase | 프로필 | 산출물 |
|---|---|---|
| 3 | wonbikok-developer 1개(직렬 전 범위) | 소스 + `03_implementation.md` |
| 5 | wonbikok-reviewer | `05_review.md` |
| 6? | wonbikok-developer | 지적 최소 수정 |
| 7 | wonbikok-tester | `07_test_report.md` |

## 7. 리스크

1. 가입 플로우 변경으로 기존 회귀(490건) — 인증 단계는 신규 액션 분리로 기존 플로우 최소 변경
2. 할인·수수료의 금액 정합(SUB-005) — ledger에 원가·할인액·비율 스냅샷 저장·Reviewer 집중
3. 인증 알림톡 실심사 — v1.0 SIMULATED·운영 과제 명시(카카오 인증 템플릿 별도)
4. 역할별 수수료 정책(sales 20%/12개월 캡·officer 15%/무기한)은 사용자 확정 — 관리자 필드로 재조정 가능
