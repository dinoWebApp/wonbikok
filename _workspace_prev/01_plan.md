# W2 플랜 — 월간 청구·납부 안내(F3) + 솔라피 알림톡 + 미납 리마인더(F6)

- 작성: 오케스트레이터 / 2026-10-20
- pipelineType: **full** (신규 엔티티 2종, 외부 연동 1종, 마이그레이션 3건, 배치 잡 3종, ~35파일)
- PRD 근거: 7장 F3·F6, 9.3 메시지 상태, 10.2 솔라피, 14장, 18.1 W2, 22장 Rule ID

## 0. 컨텍스트 확인 결과

- `progress.json`: null → 신규 / git: clean (최종 푸시 5a5296d)
- `_workspace/` → W1 산출물 6건을 `_workspace_prev/`로 이동 완료 (W2 이관 과제는 05_review.md에 보존됨)
- Invoice/MessageLog 관련 코드 없음, `config/recurring.yml` 스캐폴드 존재, app/services·app/jobs 구조 준비됨

## 1. 작업 범위

### F3. 월간 청구 & 납부 안내 (PRD 7장 F3)

- **Invoice 모델**: tenant/student FK, target_month(예: "2026-11"), 원생명·기본 원비 **스냅샷**(TEN-004), adjustment_amount(할인/할증)·adjustment_note(비고), due_on(원생 payment_day 기반 당월 기한), status — PRD 9.1: DRAFT/READY/SENT/UNPAID/OVERDUE/CANCELLED (PARTIALLY_PAID·PAID는 W3 수납 도입 시 활성). **유니크 [student_id, target_month]** (INV-001, 모델 검증+DB 인덱스)
- **자동 생성**: 매월 1일 배치(Solid Queue recurring) + 원장 수동 트리거("이번 달 청구 만들기"). `Student.active`만 대상(INV-004). 중복 실행 시 미처리 건만(멱등)
- **미리보기 → 확정**: 총 청구액·대상 인원·원생별 금액 확인 후 DRAFT→READY(INV-006). 제외 원생은 사유 기록
- **개별 조정**: DRAFT에서 조정액·비고 수정 자유 / READY 이후 수정은 변경 사유 기록(INV-002)
- **발송**: READY 청구 대상 알림톡(솔라피) 즉시/예약 발송, 발송 시 SENT. 예약은 취소 가능·대기열 표시(MSG-007). 본문: 원생명·청구월·금액·납부 계좌·기한·문의(원장 전화) — **청구 링크(F9)는 W3이므로 본문만으로 납부 완결**(PRD 원칙)
- **발송 결과**: 성공/실패 목록 + 실패 사유, '다시 보내기'(명시 액션 — 이력 기록, MSG-001/006)
- **취소**: CANCELLED 전이 — 수납 합계 제외는 W3부터 실질 적용(INV-003)

### 솔라피 연동 (PRD 10.2)

- **Solapi::Client** (app/services/solapi/): Messages v4 API. HMAC-SHA256 인증(api_key·api_secret — credentials), 알림톡+**대체발송(SMS/LMS) 단일 요청**(MSG-002 — 솔라피 대체발송 설정 활용), 응답(messageId/groupId·상태코드) 기반 상태 기록. 타임아웃·오류 코드 매핑
- **MessageLog**: tenant/invoice/student FK, channel(alimtalk/sms), template_type(invoice_notice/reminder_soft/reminder_standard/reminder_formal), status(QUEUED/SENDING/SENT/FAILED/FALLBACK_SENT/SIMULATED — PRD 9.3), provider_message_id, error_code·message, sent_at, resend_of(재발송 이력 연결). **발송 유일성 [invoice_id, template_type] — resend 플래그 예외**(MSG-001)
- **MSG-003**: 자동 재시도 상한 1회
- **연습 모드**: practice 테넌트는 실호출 없이 SIMULATED 기록(기존 전제 유지)
- **credentials**: solapi.api_key·api_secret — 미설정 시 발송 시도는 SIMULATED 처리 + 설정 안내 표시

### F6. 미납 리마인더 (PRD 7장 F6)

- **미납 판정(W2 임시 규칙)**: 발송 완료(SENT) & due_on 경과 & 완납 기록 없음 — Payment 도입(W3) 시 완납 반영으로 확장. **취소 청구 제외**(INV-003)
- **자동 스케줄**: D+3/D+7/월말 D-1, 단계별 ON/OFF + 발송 시각 설정(기본 오전 9시, 야간 발송 금지 — MSG-006). 매일 오전 리마인더 디스패처 배치가 대상 판정·발송
- **템플릿 3종**: 부드러움/표준/공식 + 원장 커스텀 문구 저장, 원생별 발송 톤 선택 — 리마인더 발신자 표기는 원장 상호·연락처 포함(MSG-005)
- **제외 설정**: 원생별 리마인더 제외 → 즉시 자동 발송 배제(MSG-004) — students 컬럼 추가
- **개입**: 미납 목록 뷰(원생·금액·경과일·발송 이력), 선택 즉시 발송(수신자·내용 미리보기), 발송 중단

### 배치 (config/recurring.yml)

1. `monthly_invoice_generation` — 매월 1일 07:00, 전 테넌트 청구 초안 생성
2. `reminder_dispatch` — 매일 09:00, D+3/D+7/월말 D-1 대상 발송

### W1 후속 정리 3건 (W1 리뷰가 W2 과제로 기록)

1. 미완료 온보딩 테넌트의 `/students` 등 직접 접근 차단 게이트
2. 로그아웃 시 세션의 CSV 오류내역 캐시 키 제거
3. 온보딩 스텝 1(계좌) presence 검증 보완(WARNING-7 잔여)
※ CSV confirm 컬럼·중복검사 성능(WARNING-8/9)은 유지보수 이슈로 유지(미포함)

## 2. 대상 파일 (~35)

| 레이어 | 파일 |
|:---|:---|
| 마이그레이션 3 | create_invoices / create_message_logs / tenants(리마인더 설정 4컬럼)+students(excluded_from_reminders) |
| 모델 | invoice, message_log + student/tenant 스코프·설정 |
| 서비스 | solapi/client, solapi/message_builder(템플릿 치환), invoices/generator(배치·수동 공용), reminders/scheduler(대상 판정), notifications/dispatcher(발송 오케스트레이션 — 유일성·대체발송·재시도 1회) |
| 잡 | monthly_invoice_generation_job, reminder_dispatch_job, message_send_job |
| 컨트롤러 | invoices_controller(생성/미리보기/확정/조정/취소/발송/결과), reminders_controller(설정/미납 목록/즉시발송/제외) |
| 뷰 | invoices(목록/미리보기/결과), reminders(설정/미납 목록/이력) ~12 |
| 설정 | config/recurring.yml, routes, ko.yml, credentials(solapi 키 주석 가이드) |
| 테스트 | Phase 7 (Tester) |

## 3. Rule ID 목록 (22장)

- **INV-001**(중복 청구 금지), **INV-002**(확정 후 수정 사유), **INV-003**(취소 수납합계 제외 — W3 실질), **INV-004**(휴원·퇴원 제외 — W1 스코프 재사용), **INV-006**(미리보기·발송 전 수정)
- **MSG-001**(발송 유일성+재발송 예외 이력), **MSG-002**(알림톡 실패 시 SMS 대체), **MSG-003**(재시도 상한), **MSG-004**(제외 즉시 배제), **MSG-005**(원장 발신 표기), **MSG-006**(야간 금지·기본 오전 9~10시), **MSG-007**(예약 취소·대기열 표시)
- **TEN-001**(격리), **TEN-004**(청구 스냅샷)
- 미포함 명시: INV-005(부분납·W3), PAY 도메인(W3), 발행 안내 알림톡(W3 CR)

## 4. PRD/AGENTS.md 수정 필요 (Phase 2)

- **PRD.md**: v2.1→v2.2, 14장에 W2 확정 사항(Invoice 스냅샷 필드 구성, MessageLog 채널·상태·resend_of, 솔라피 응답 기반 상태, W2 미납 임시 판정 규칙, 리마인더 설정 컬럼), F3에 '링크 없는 본문 발송(W2)→링크 추가(W3)' 경계 명시
- **AGENTS.md**: W2 → 🔄 진행 중

## 5. 에이전트 스폰 계획

| Phase | 에이전트 | 지시 |
|:---|:---|:---|
| 3-1 | Developer (신규) | F3+솔라피: 마이그레이션·Invoice·Solapi::Client·발송 파이프라인(유일성·대체발송·재시도)·배치 2종·청구 화면 |
| 3-2 | Developer (신규) | F6: 리마인더 스케줄러·설정 화면·미납 목록·제외·즉시발송 + W1 후속 3건 |
| 4 | 오케스트레이터 | rubocop/brakeman/rails test |
| 5 | Reviewer (신규) | 중점: MSG-001 유일성·MSG-002 대체발송·MSG-003 상한·INV-001/002·TEN-001/004·배치 멱등 |
| 6 | Developer (신규, 필요 시) | 지적 최소 수정 |
| 7 | Tester (신규) | 위 시나리오 기반 (외부 API 스텁 필수) |
| 8 | 오케스트레이터 | 부트 검증 (절대경 Ruby 기동 — W1 런레포트 레시피) |

## 6. 리스크·모호점

1. **실발송 검증(W2 완료 기준)**: 솔라피 API 키·카카오채널 알림톡 템플릿 심사가 **운영 준비물**(사용자 선행 작업). 개발은 스텁/시뮬레이션으로 완결하고, 키 주입 후 실발송 1건 스모크는 별도 단계(유료 발송이므로 사용자 확인 필요)
2. **알림톡 템플릿 코드**: 카카오 사전등록 템플릿 필요 — 코드 파라미터 구조만 구현, 실제 템플릿 ID는 운영 주입
3. **미납 판정**: Payment 부재로 W2 임시 규칙(기한 경과·무완납 기록) — W3에서 확장
4. **솔라피 응답 비동기성**: 발송 요청 응답만으로 최종 전달 보장 없음 — W2는 요청 응답 기반 상태, 수신 리포트 폴링/웹훅은 P1

## 7. 완료 기준 (PRD 18.1 W2)

- [ ] 이번 달 청구 초안 생성(배치·수동) → 미리보기 → 확정 → 발송 흐름 동작
- [ ] 알림톡 발송 파이프라인 완성(유일성·SMS 대체·재시도 1회·이력) — 스텁/시뮬레이션 검증
- [ ] 리마인더 D+3/D+7/월말 자동 판정·발송, 제외 즉시 배제, 3종 템플릿
- [ ] 연습 모드에서 외부 호출 0건(SIMULATED)
- [ ] 품질 게이트 통과 + 리뷰 APPROVED
- [ ] (운영 준비물 충족 시) 실발송 1건 스모크 — 별도 확인 단계
