# 05_review.md — W4 병렬 배치 코드 리뷰 (Phase 5, 1차)

- 실행일: 2026-11-18 · 프로필: wonbikok-reviewer · 판정: **CHANGES_REQUESTED (BLOCKER 0 · CRITICAL 2 · WARNING 8)**
- 게이트 실측: 480 runs 통과·RuboCop 0·Brakeman 0. 도메인 설계(상태 전이 서비스 경유·SIMULATED 이중 게이트·
  ADM-001 2차 방어·마스킹 단일 경유) 견고.

## CRITICAL

[C-1] SUB-001 — CSV 일괄 등록 경로 상한 가드 부재 — app/services/students_csv_import_service.rb·students_controller.rb:80-98
- create에는 가드 있으나 CSV import에 없음 — 라이트(30명) 테넌트가 상한 초과 원생을 CSV로 무제한 등록 가능(플랜 상한 완전 우회).
- 수정: 서비스에 잔여 슬롯 전달 → 초과 행 오류행 처리("잔여 N명 초과" 사유) 또는 import 액션 잔여 0 시 422 차단 + 테스트 보강.

[C-2] i18n 누락 — subscriptions.events.trial_extended 키 부재 — config/locales/ko.yml·subscriptions/show.html.erb:121
- integ가 enum에 trial_extended를 추가했으나 ko.yml 미병합 → 관리자 체험 연장 시 원장 구독 화면에 "Translation missing" 렌더(실측 확인).
- 수정: 키 1줄 추가 + 동적 키 후보(enum 전수) 대조 재발 방지 권장.

## WARNING

- W-1 세션 고정: admin sessions create_otp 성공 시 reset_session 후 키 설정 권장(원장 앱 Session 재생성 구조와 대비).
- W-2 OTP 개발 폴백 시드가 운영에서도 유효 — development/test 한정 또는 production 미설정 시 로그인 거부 권장.
- W-3 OTP 5회째 잠금 account_locked 감사 이중 기록 — 반환값 일원화.
- W-4 past_due/suspended 대상 체험 연장이 기능 무효(trial_ends_at만 갱신) — 연장 시 trial 복귀 또는 대상 trial 한정.
- W-5 청구액 라벨-산식 불일치 — billed_amount는 DRAFT 포함 설계인데 라벨 "확정 청구 합계" — "당월 청구 합계(취소 제외·초안 포함)"로 정정.
- W-6 A1 지표 3종 드릴다운 미제공 — 후속 목록 명시 추가.
- W-7 A3 결제 이력 N+1 — includes(subscription: :tenant) 적용 권장.
- W-8 정지 실차단·suspended 게이팅 부재가 PRD W4 확정 블록 후속 목록에 미기록 — 02_prd_update 추가.

기록(수용·조치 불요): AuditLog created_at 옵션(운영 경로 사용 금지 주석 유지)·TimelineService 전체 로드(소규모)·
month_end_near? 과거 월 참(화면 영향 미미)·active 구독 체험 잔여일 음수 표시(표시 가드 경미).

## 체크리스트 (14항 — 상세 근거는 리뷰 본문)

1 ADM-001 통과(2차 방어·삭제 경로 부재, W-3 이중 기록) / 2 ADM-002·TEN 통과 / 3 인증 격리 통과(W-1) /
4 OTP 통과(RFC 6238 벡터·secure_compare, W-2) / 5 SUB-001 create 통과·**CSV 우회(C-1)** / 6 SUB-002/003 통과 /
7 체험·D-7 통과(캐시 마커 멱등) / 8 Portone SIMULATED 통과(네트워크 0) / 9 F7 지표 통과(기준 일치, W-5) /
10 F7 뷰 통과 / 11 A2 통과(LIKE 이스케이프) / 12 A3 통과(환불 3분기·음수 방어) / 13 아키텍처·회귀 통과(**C-2 제외**,
integ 조정 18건 전수 — 전부 교정·약화 아님) / 14 integ 요청 6건 응답 완료.

## Tester 전달 (중점)

- SUB-001(수정 후): CSV 상한 차단 경계(잔여 1에 2행 → 1성공/1오류행)·create 가드 회귀
- SUB-002/003: 재시도 이벤트·past_due·suspend!/재개·D+30 카운트다운
- ADM-001/002: 사유 없는 4조치 422·마스킹 원문 미노출·OTP 5회 잠금(합산)
- C-2(수정 후): trial_extended 라벨 정상 렌더
- F7: 미확인 입금 수 일치·취소 제외·PAID×미발행

재검증 범위: C-1·C-2 수정 파일 + 전체 게이트 1회.

## 2차 리뷰 (Phase 6 수정 후 — 2026-11-18, 루프 1회차)

상태: **APPROVED** (BLOCKER 0 / CRITICAL 0 / WARNING 0 — 1차 WARNING 전부 해소·문서화)

### 수정 검증 (파일·라인 근거)

| 항목 | 검증 결과 |
|---|---|
| C-1 SUB-001 CSV 우회 | 해소 — students_csv_import_service.rb:13-18(잔여 슬롯 주입·nil=레거시)·37(재원 행만 소진)·67-72(초과 재원 행 오류행 — plan_limit_exceeded 사유)·114-117(active_row? 상태 매핑) / students_controller.rb:91-106(잔여 0 업로드 422 이중 방어)·158-172(remaining_active_slots 헬퍼 일원화). 경계(잔여 1×2행→1성공/1오류)·휴원 무소진(INV-004)·레거시 통과 테스트 신규·회귀 확인 |
| C-2 i18n 누락 | 해소 — ko.yml:290 trial_extended 추가(런타임 렌더 확인) + subscription_test.rb:170-176 enum 전수×키 존재 단정(재발 방지) |
| W-1 세션 고정 | 해소 — admin/sessions_controller.rb:50-51 reset_session 후 최종 키 재설정 |
| W-2 OTP 폴백 | 해소 — otp_service.rb:83-84 폴백 Rails.env.local? 한정·운영 미설정 시 fail-closed. otp_seed 설정 시 조기 반환 — 정상 운영 무영향 |
| W-3 감아 이중 기록 | 해소 — register_login_failure! 단일 경유·locked_now 반환 |
| W-5 F7 기준 라벨 | 해소 — ko.yml:139 산식과 일치 |
| W-7 A3 N+1 | 해소 — includes(subscription: :tenant) |
| 경미(잔여일 음수) | 해소 — admin/tenants/show.html.erb:71-76 trial 한정 표시 |
| W-4·W-6·W-8 | 문서화 종결 — 02_prd_update.md "후속 과제 보강" 섹션 |

### 게이트 (재실측)

- bin/rails test: 485 runs, 2154 assertions, 0 failures, 0 errors, 0 skips (+5)
- bin/rubocop: 170 files 0 / bin/brakeman: No warnings

### 새 결함·회귀 여부

없음 — create 가드·OTP·잠금·마스킹 기존 방어 무변경. 관찰(조치 불요): 잔여 0 이중 방어 오류행 line 0 표시는
기존 인코딩 오류 규약 준수.

### 최종 판정

**APPROVED** — 수정 국소적이므로 도메인 재검증 불필요. Tester 제안: CSV 잔여 슬롯 경계·레거시 통과·
trial_extended 렌더 유지를 회귀 스위트로 고정.
