# 03_implementation.md — task-integ (W3 F4+F9 병렬 배치 통합, Phase 3-S)

- 작성일: 2026-11-18
- 담당: wonbikok-developer (integ 단일 Developer)
- 범위: f4(입금 확인)·f9(청구 링크) 구현 결과의 공유 파일 결선·통합 + 전체 게이트
- 근거: `_workspace/01_plan.md`, `_workspace/parallel/f4/03_implementation.md`, `_workspace/parallel/f9/03_implementation.md`, PRD.md 14장 "W3 F4/F9 구현 확정 사항(2026-11-18)"·22장 PAY/LNK

## 1. 결선 내역

### 1.1 마이그레이션 — 단 1개 (생성 1회, `bin/rails generate migration` 1회만)

`db/migrate/20261118000001_create_payments_and_invoice_public_tokens.rb` (db:migrate 완료·schema.rb version 2026_11_18_000001 갱신)

- **payments 테이블**: invoice_id(FK, NOT NULL)·tenant_id(FK, NOT NULL)·amount(int, NOT NULL — 원 단위)·paid_on(date, NOT NULL)·method(string, NOT NULL — transfer/card/cash/other)·memo·status(string, NOT NULL, default "active")·cancel_reason·cancelled_at·cancelled_by·confirmed_by·confirmed_at + timestamps
- **인덱스**: `[invoice_id, status]`(active 합계·PAY-001 판정), tenant_id(t.references 자동 생성 — f4 보고서의 명시 add_index와 중복이라 제거, 스키마 결과 동일), FK 2건
- **DB CHECK**: `amount > 0`(`chk_payments_amount_positive`)만 반영 — SQLite 안전·모델 검증(PAY-001)의 DB 계층 이중 방어. 상태별 부분 인덱스 합계 트리거는 SQLite 유지보수 비용 대비 효과 낮아 미반영(f4 보고서 4.1 권고 수용 판단)
- **invoices 추가**: `public_token`(string)·`public_token_issued_at`·`public_token_revoked_at` + **부분 유니크 인덱스** `index_invoices_on_public_token`(`WHERE public_token IS NOT NULL` — SQLite 부분 인덱스, 미발급 NULL 다중 허용)
- **cancelled_by 포함 확정**: PRD 14장 확정 블록 컬럼 목록에는 없으나 01_plan §3 소유권 표·Payment 모델 setter(masked_operator, TEN-003·PAY-002 처리자 기록)가 전제 → 포함(PAY-002 "처리자·시간 기록" 정합)

### 1.2 config/routes.rb

- `resources :payments, only: %i[index new create]` + member `get :cancel`·`post :cancel_payment` — f4 보고서 4.2 스펙 그대로
- `get "/b/:token", to: "billing_links#show", as: :billing_link` — 공개·비로그인(f9 결선 권장 경로 그대로)
- invoices member에 `post :issue_link`·`post :revoke_link` 신설(원장 쪽 링크 관리). **재발급은 별도 라우트 없이 `issue_link`에 `reissue` 파라미터**로 처리(라우트 2개 한도 내에서 TokenService.reissue_for 위임 — LNK-003)

### 1.3 config/locales/ko.yml — 병합·전수 대조

- f4 보고서 §3 yaml 목록 **54키**(payments.* 45 + invoices.status PAID/PARTIALLY_PAID 2 + enums.invoice.status 2 + activerecord.errors.models.payment 5) — 보고서 헤더의 "68키"는 실제 목록(54)과 불일치, **목록 그대로 병합**. `payments:` 네임스페이스는 invoices와 reminders 사이에 배치
- f9 보고서 §3 yaml 목록 **28키**(billing_links.* — 헤더 "26키"와 불일치, 목록 그대로). `barobill:` 뒤 도메인 주석 블록과 함께 배치
- 전수 대조: `I18n.exists?`로 f4 54키 + f9 28키 **missing 0** 확인
- integ 추가 키: `invoices.link.*`(title·issue·copy·reissue·revoke·copy_success·copy_fallback·reissue_confirm·revoke_confirm)·`invoices.actions.payment_entry`·`invoices.actions.more`·`invoices.notices.link_issued/link_reissued/link_revoked`·`messages.invoice_notice.billing_link_line`
- 기존 `invoices.status.*`·`enums.invoice.status.*`에 PAID(완납)·PARTIALLY_PAID(부분납) 추가 — 기존 6종 뒤 삽입(CANCELLED 앞)

### 1.4 app/models/invoice.rb (공유 — 단일 수정)

- `has_many :payments` 추가 — **dependent 없음**(수납은 PAY-002 이력이므로 청구 삭제에도 보존, DB FK restrict). f4는 association 미의존 설계였으므로 충돌 없음
- `active_public_token?` 추가(토큰 위임 편의 최소) — 발급·재발급·폐기는 BillingLinks::TokenService 단일 진입점 유지. billing_link_url은 모델에 두지 않음(뷰는 라우트 헬퍼 `billing_link_url(token)` 사용)
- **`cancel!`에 `BillingLinks::TokenService.revoke_for(self)` 연계**(f9 §5-6 권고 수용) — 트랜잭션 내 CANCELLED 전이 직후 호출, 취소 청구의 공개 링크 즉시 폐기(LNK-003·멱등)
- **remindable에 `:PARTIALLY_PAID` 추가**(f4 §4.3 발견 수정) — 부분납은 잔액이 미납으로 남아 리마인더 대상(PRD F4 "잔액은 미납으로 유지되며 리마인더 대상 유지"). 기존 조합(where.not(due_on: nil)·joins students excluded_from_reminders=false) 유지, **PAID는 미포함**. 상태 목록 외 로직 변경 0
- cash_receipt_issuable?·enum·confirm!·adjust! 등 기존 로직 **변경 금지 준수(무변경)**

### 1.5 invoices_controller + invoices/index 뷰 (공유 — 단일 수정)

- 컨트롤러: member 액션 `issue_link`(issue_for 멱등, `reissue` 파라미터 시 reissue_for — 안내 문구 분기)·`revoke_link`(revoke_for, 사유 불요). set_invoice before_action 확장, TEN-001 스코프(current_tenant.invoices.find) 유지, 리다이렉트 `status: :see_other`(303) 준수
- 뷰(과밀 방지 위계 재구성 — "기존 액션 버튼과 위계 정리·필요시 세부 행 접기" 수행):
  - **주 액션**: "입금 확인" 전폭 버튼 — 미완납 확정 청구(READY/SENT/UNPAID/OVERDUE/PARTIALLY_PAID)만 → `new_payment_path(invoice_id:)`(F4 진입)
  - **"더보기" details 접기**: 수정(DRAFT·READY만 — 이후 상태는 컨트롤러가 차단하던 버튼을 노출하지 않게 정리)·청구 취소(`cancellable?`만 — PAID의 취소 버튼 오노출 제거)·링크 관리(유효 토큰 있으면 복사[clipboard 컨트롤러 재사용]·재발급·폐기, 없으면 발급 — 폐기만 turbo_confirm)
  - 배지 톤 맵에 PARTIALLY_PAID=warning·PAID=success 추가(16.2)
- 변경 유의: 기존에는 모든 상태에 수정·취소 버튼이 상시 노출(클릭 시 422 안내) — 실행 가능한 액션만 노출하는 정리이며, W2 흐름 테스트 전부 통과로 회귀 없음

### 1.6 F3 안내 알림톡 링크 주입 (최소 — 과도 확장 금지)

- `app/services/solapi/message_builder.rb`: invoice_notice 경로에 한해 **유효(미폐기) 토큰이 있는 청구만** 카카오 변수 `"청구링크"`(절대 URL) 추가 + SMS 폴백 본문 뒤 `billing_link_line`("청구 내역 확인: %{url}") 1줄 추가. **토큰 없으면 기존 본문 그대로(W2 동작 유지)** — 리마인더 경로는 미변경, SampleInvoice 등 토큰 미보유 객체는 respond_to? 가드. SIMULATED 경로는 builder를 거치지 않으므로 무변경
- URL 호스트: `Rails.application.routes.default_url_options` → 없으면 `action_mailer.default_url_options` 폴백(test=example.com·development=localhost:3000). **운영 호스트는 placeholder(example.com)** — 도메인 확정 후 config 갱신 필요(아래 Reviewer 집중 항목)

## 2. f4/f9 스펙 대조 결과 (불일치 조정 내역)

| 항목 | f4/f9 가정 | integ 확정 | 조정 |
|---|---|---|---|
| Payment 컬럼 | 보고서 4.1 스펙(12컬럼+timestamps) | 동일 + CHECK(amount>0) | 일치 — tenant_id 인덱스는 references 자동 생성으로 명시 add_index 생략(결과 동일) |
| cancelled_by | f4: "01_plan 표 기준 포함 요청" | 포함 | 확정 — Payment setter 존재 |
| `method` 컬럼명 | f4: 유지 권고(리네임 시 전면 수정) | **유지** | 무조정 — Object#method 덮음 주석은 Payment 모델에 존재 |
| invoices 토큰 컬럼 | f9: public_token(string·유니크)+issued_at+revoked_at | 동일 + 부분 유니크 인덱스 | 일치 |
| `/b/:token` 라우트 | f9: `get "/b/:token", as: :billing_link` | 그대로 | 일치 |
| 원장 링크 발급/폐기 | f9: TokenService.issue_for/reissue_for/revoke_for 호출 권고 | issue_link(재발급=reissue 파라미터)·revoke_link로 결선 | 라우트 2개 제약 내 재발급 처리 설계(integ 결정) |
| ko.yml 키 수 | f4 헤더 68 / f9 헤더 26 | **실제 목록 54 / 28** | 헤더 수치 불일치 — 목록 기준 병합·전수 대조로 방어 |
| f4 association | invoice.payments 미의존 설계 | has_many :payments 추가 | 호환 — f4 코드 무수정 |
| remindable | f4: PARTIALLY_PAID 누락 발견 → 추가 권고 | 추가 반영 | §1.4 참조 |

## 3. 게이트 결과 (전 구간 통과)

| 게이트 | 결과 |
|---|---|
| `bin/rubocop` (전체 126 files) | **0 offenses** |
| `bin/brakeman` | **0 errors · Security Warnings 0** |
| `bin/rails db:migrate` | 완료 — schema.rb version 2026_11_18_000001 |
| `bin/rails test` (전체) | **300 runs · 1274 assertions · 0 failures · 0 errors · 0 skips** |

- 테스트 구성: 기존(W1·W2·F5·랜딩/퍼블리싱) 236 + f4 신규 43(payment_test 13·confirm_service 11·matching_hint 9·payments_controller 10 — 보고서 표기 39와 실제 13/11/9/10=43 불일치, 실측 기준) + f9 신규 20(token_service 10·billing_links_controller 10) + integ 결선 회귀 1(invoices_flow_smoke — 아래) = 300
- **integ 신규 테스트 1건**: `invoices_flow_smoke_test.rb` "청구 목록에서 입금 확인 진입과 청구 링크 발급·재발급·폐기가 동작한다" — index 입금 확인 진입 버튼·링크 관리 열 렌더(clipboard)·재발급 후 이전 토큰 404/신규 200·폐기 후 발급 버튼 복귀까지 결선 UI end-to-end 검증(기존 테스트에 이 렌더 경로 커버가 없어 추가)

### 3.1 통합 단계에서 처리한 소량 결함 수정 (규약: 소량은 integ 처리·명시)

첫 전체 실행(299 runs)에서 2 failures + 2 errors — 전부 f4/f9 테스트 코드의 소량 결함으로, integ 소유 구간이므로 직접 수정:

1. **f9 token_service_test 재발급 케이스**: `Result#token`이 `invoice.public_token` **라이브 위임**이어서 재발급 후 `old.token` 재평가 시 새 토큰이 반환되어 `assert_not_equal` 실패 — 이전 토큰을 문자열로 스냅샷 후 비교하도록 수정(서비스 동작은 정상)
2. **f9 token_service_test 유니크 충돌 케이스**: SecureRandom 모듈 싱글턴 스텁이 복원 없이 누수(cash_receipt_triggerable_test 패턴은 ensure 복원) — `ensure`로 원본 복원 추가
3. **f4 matching_hint_service_test TEN-001 케이스**: `assert_empty` 전제 오류 — amount 250,000은 setup의 자기 테넌트 청구(김민준)와 정확 일치하므로 후보 반환은 서비스의 올바른 동작. 단정을 "타 테넌트 청구(other_invoice) 미포함 + 전부 자기 테넌트"로 교정(테넌트 격리 자체는 정상 동작 확인)
4. **f9 billing_links_controller_test 2건**: setup 청구와 같은 [student, target_month]로 청구 추가 생성 → INV-001 유니크 위반(RecordInvalid) — `target_month: "2026-09"` 추가
5. **f9 컨트롤러 테스트 임시 RouteSet 드로우(setup/teardown reload_routes!) 제거** — 정식 `/b/:token` 라우트 사용(태스크 지시)

## 4. remindable 수정 사유 (요약)

W2 임시 규칙은 `SENT/UNPAID/OVERDUE`만 포함 — F4 도입으로 PARTIALLY_PAID(부분납) 청구가 발생하며 잔액이 미납으로 남으므로 리마인더 누락(PRD F4 정합성 위반)이 예상됨. f4 보고서 §4.3이 발견·권고했고 integ가 반영. 파급 범위 확인: Reminders::Scheduler(단계 판정은 due_stage_for 단일 기준이라 무영향)·RemindersController(즉시 발송 대상 재적용 — 일관)·Dashboard(미납 카운트에 부분납 포함 — 잔여 미납 존재하므로 정합). PAID는 완납이므로 미포함 유지. **유의: 리마인더 본문의 %{amount}는 invoice.total_amount 기준 — 부분납 건에 잔액이 아닌 총액이 표기될 수 있음(아래 Reviewer 집중 항목)**

## 5. Reviewer 집중 요청 사항

1. **LNK-002 노출 최소(공개 페이지)** — f9 구현물 화이트리스트(BillingView 13필드)·타 청구 미노출·만료 404를 재검증 바람. integ는 구조 변경 없음
2. **PAY-001·CR-002 연결** — ConfirmService의 PAID 시점 Triggerable 1회·부분납 보류·취소 재계산과 DB CHECK(amount>0)의 이중 방어 적절성
3. **index 뷰 액션 정리 회귀** — 수정 버튼을 DRAFT/READY로, 취소 버튼을 cancellable?로 한정한 것(기존엔 상시 노출)이 W2 UX 기대와 부합하는지
4. **부분납 리마인더 문구의 금액 변수** — MessageBuilder가 reminder 본문에 total_amount를 사용. 부분납 건 리마인더에서 "원비 250,000원 미납"처럼 총액 표기(잔액 아님)의 허용 여부 — PRD F4 문구 정책 확인 필요(본 integ는 스코프 밖으로 보류)
5. **운영 URL 호스트 placeholder** — 알림톡 청구 링크의 절대 URL이 mailer default_url_options(example.com) 폴백. 운영 도메인 확정 시 config 갱신 필요(신규 오픈 이슈성 항목)
6. **CANCELLED + 유효 토큰 잔존 방어** — cancel!이 폐기를 연계하지만 과거 데이터·동시성 여지에 대비해 index의 링크 폐기 버튼은 유효 토큰 존재 시 노출되도록 방어 유지
7. **`method` 컬럼명** — Payment 인스턴스에서 `.method(:sym)` 리플렉션 금지(모델 주석 존재). 유지 결정의 적절성 확인

## 6. 자체 체크리스트

- [x] 마이그레이션 1개·`bin/rails generate migration` 1회·schema.rb 갱신
- [x] f4·f9 도메인 로직(서비스·모델 검증·화이트리스트 렌더) 임의 재작성 없음 — 결선·최소 조정만(조정 목록 §2·§3.1)
- [x] TEN-001(모든 신규 액션 current_tenant 스코프)·LNK-002(공개 페이지 구조 무변경)·PAY-001(모델 검증+DB CHECK) 방어 구조 약화 없음
- [x] 외부 API 실호출 없음(Triggerable·솔라피 스텁/경계 유지)·credentials 수정 없음
- [x] 기존 F1~F6·F5(바로빌) 회귀 없음 — 전체 테스트 300건 통과로 확인
- [x] Turbo 규약 — 신규 액션 303 리다이렉트, 폼 실패 422(기존 경로 유지)
- [x] ko.yml 문구 하드코딩 없음(뷰·컨트롤러·본문 모두 i18n 키 참조)
- [x] ERB 2칸 들여쓰기·RuboCop(omakase) 0 offenses
