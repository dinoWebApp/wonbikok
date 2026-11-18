# 03_implementation.md — task-f9 학부모 청구 링크 (Phase 3-P)

- 작성일: 2026-11-18
- 담당: wonbikok-developer (f9 병렬 태스크)
- PRD: 8장 학부모용 청구 페이지(425행), 22장 LNK-001~005, TEN-001/003
- 소유권 화이트리스트 준수 — 생성 파일 외 수정 없음(routes·마이그레이션·ko.yml·invoice.rb·기존 뷰 미수정)

## 1. 생성 파일 (8)

| 파일 | 내용 | Rule ID |
|---|---|---|
| `app/services/billing_links/token_service.rb` | 토큰 발급(멱등)·재발급·폐기·유효 조회 | LNK-001·LNK-003 |
| `app/controllers/billing_links_controller.rb` | 공개 show 액션·화이트리스트 조립·no-store | LNK-002·003·005·TEN-001/003 |
| `app/javascript/controllers/clipboard_controller.js` | 계좌 원탭 복사·2초 토스트·전체선택 폴백 | PRD 8장(3초 목표) |
| `app/views/layouts/billing_link.html.erb` | 공개 전용 최소 레이아웃(noindex·PWA 메타 없음·하단탭 없음) | LNK·PRD 8장 |
| `app/views/billing_links/show.html.erb` | 청구 페이지(금액>계좌복사>내역·기한·상태>현금영수증 안내>문의) | LNK-002·005·TEN-003 |
| `app/views/billing_links/expired.html.erb` | 만료 안내(청구·교습소 정보 일절 없음) | LNK-003 |
| `test/services/billing_links/token_service_test.rb` | 서비스 테스트 10건 | LNK-001/003·TEN-001 |
| `test/controllers/billing_links_controller_test.rb` | 컨트롤러 테스트 10건(임시 라우트 드로우) | LNK-001~005·TEN-001 |

자체 검증: `bin/rubocop` (Ruby 4파일) 0 offenses, ERB 3파일 Erubi 파싱 OK, JS `node --check` OK.

## 2. 설계 결정

### 2.1 TokenService (app/services/billing_links/token_service.rb)
- `TOKEN_BYTES = 24` → `SecureRandom.urlsafe_base64(24)` = **urlsafe 32자**(LNK-001 예측 불가).
- 컬럼 가정(3-S 마이그레이션): `invoices.public_token(string·전역 유니크 인덱스)·public_token_issued_at·public_token_revoked_at`.
- API 시그니처:
  - `issue_for(invoice)` → `Result(invoice, outcome)` — outcome `:issued`/`:reused`(유효 토큰 존재 시 멱등 재사용)
  - `reissue_for(invoice)` → 폐기 기록 후 신규 발급(이전 토큰은 문자열 자체가 교체되어 즉시 조회 불가 + 최초 폐기 시각 유지)
  - `revoke_for(invoice)` → `public_token_revoked_at` 기록(이미 폐기 시 갱신 없음 — 멱등)
  - `find_active_by_token(token)` → `Invoice.find_by(public_token:, public_token_revoked_at: nil)` — 불일치·폐기·빈 토큰 모두 nil
- 유니크 충돌 시 `ActiveRecord::RecordNotUnique` 재시도 **상한 5회**(무한 재시도 금지 원칙).
- Result 패턴은 기존 `CashReceipt::Triggerable` 관례 따름.

### 2.2 BillingLinksController (노출 화이트리스트 명세 — LNK-002)
- `skip_before_action` ×2: `require_authentication`·`ensure_onboarding_complete`(비로그인·Current.tenant 의존 제거).
- `layout "billing_link"` — 컨트롤러 지정(뷰 layout 지정 불가 규약).
- **뷰에는 `@billing`(Data Struct `BillingView`) 13필드만 전달. @invoice 자체를 뷰에 넘기지 않음** — 실수로 인한 내부 필드 노출 여지를 구조적으로 차단:
  - `academy_name`(tenant.name) / `contact_phone`(원장 계정 휴대폰번호 → 없으면 tenant.biz_tel) /
    `student_name`(**마스킹: 첫 글자+OO**, TEN-003 — 스냅샷 원문은 컨트롤러 단계에서 버려짐) /
    `billing_month`(YYYY-MM 원문) / `base_amount` / `adjustment_amount` / `adjustment_note` / `total_amount` /
    `due_on` / `payment_state`(:pending·:confirming·:paid) / `bank_name` / `bank_account` / `account_holder`
- 절대 미포함(테스트로 강제): 전체 원생 명단·타 청구(타 원생명·타 내역·타 메모)·내부 취소 사유(cancel_reason)·타 토큰·공급자 원본 응답.
- 납부 상태 3값 매핑: `PAID→:paid` / `PARTIALLY_PAID→:confirming` / **그 외 전부(DRAFT·READY·SENT·UNPAID·OVERDUE·CANCELLED)→:pending(납부 전)**. CashReceipt 공급자 상태는 노출하지 않음(명세 준수).
- 만료 렌더: `render :expired, status: :not_found` — 404(토큰 리소스 부재 시맨틱) + 학부모 친화 안내 본문. 존재/폐기/불일치 모두 동일 안내(존재 여부 힌트 없음).
- `Cache-Control: no-store, max-age=0` 헤더(before_action) + 레이아웃 `<meta name="robots" content="noindex, nofollow">`.
- 문의 전화: `tel:` 링크 원문 노출 — PRD 8장 P0 "원터치 발신" 요구로 화이트리스트에 의도 포함(마스킹 시 기능 목적 상실). 휴대폰번호 저장은 User#encrypts(TEN-003) 그대로.

### 2.3 뷰·레이아웃
- 정보 위계(PRD 8장): 교습소명·원생(마스킹)·청구월 헤더 → **금액(text-4xl tabular-nums, brand-50 섹션)** → **계좌 복사 카드(브랜드 오렌지 원탭 버튼, 최우선 액션)** → 내역·기한·상태 → 현금영수증 자동발급 안내 → 문의(tel: 원터치).
- LNK-005: 폼·결제 버튼 없음(테스트 `assert_select "form", count: 0` + `/결제하기/` 부재).
- 계좌 미등록 폴백 카드, 기한 미지정 폴백 문구 포함.
- 웜 오렌지 토큰(brand·canvas·surface·ink·muted·line·success·warning) 사용, `min-h-11`(44px) 터치 타깃.

### 2.4 clipboard_controller.js
- 값·문구는 **data-attribute(Stimulus value)로 뷰에서 주입** — `data-clipboard-text-value`(계좌번호)·`data-clipboard-success-message-value`·`data-clipboard-fallback-message-value`(i18n t() 경유, JS 하드코딩 금지 준수).
- 성공: `navigator.clipboard.writeText` → 토스트("복사되었습니다" 계열 문구, `aria-live="polite"`·`role="status"`, 2초 후 자동 숨김).
- 실패/미지원 폴백: 표시 영역(`data-clipboard-target="display"`) 전체 선택(Selection API) + 복사 안내 토스트.
- 컨트롤러 등록은 기존 `eagerLoadControllersFrom("controllers", application)` 경유 — index.js 수정 불요.

## 3. ko.yml 필요 키 목록 (3-S에서 `billing_links:` 네임스페이스 추가)

```yaml
billing_links:
  meta:
    title: "납부 안내"                # 공개 레이아웃 <title> 기본값
  won: "원"
  show:
    context_label: "납부 안내서"
    student_label: "원생"
    month_label: "청구 월"
    total_label: "납부하실 금액"
    account_title: "입금 계좌"
    bank_unknown: "계좌"
    copy_account: "계좌번호 복사하기"
    copy_success: "복사되었습니다"
    copy_fallback: "복사에 실패했습니다. 선택된 계좌번호를 복사해 주세요."
    account_missing: "입금 계좌는 원장님께 문의해 주세요."
    detail_title: "청구 내역"
    base_amount: "기본 금액"
    adjustment_amount: "조정"
    due_on: "납부 기한"
    due_on_none: "기한 미지정"
    status_title: "납부 상태"
    payment_state:
      pending: "납부 전"
      confirming: "확인 중"
      paid: "납부 완료"
    cash_receipt_notice: "입금 확인 후 현금영수증이 자동 발급됩니다."
    contact_title: "문의"
    contact_hint: "납부 관련 문의는 원장님께 전화로 문의해 주세요."
    call: "전화하기"
  expired:
    title: "링크를 사용할 수 없습니다"
    description: "안내 링크가 만료되었거나 취소되어 청구 내용을 표시할 수 없습니다."
    contact_hint: "청구 내용은 교습소 원장님께 직접 문의해 주세요."
```

- 문구 값은 원비콕 톤(PRD 16장) 기준 초안 — 3-S에서 조정 가능(코드는 키만 참조).
- 키 미병합 상태로도 테스트의 데이터 기반 단정(마스킹명·금액·계좌·토큰·헤더·배지 톤 클래스)은 통과하도록 작성함.

## 4. 테스트 목록 (Rule ID 매핑, 작성만 — 실행은 3-S 게이트)

### test/services/billing_links/token_service_test.rb (10건)
1. LNK-001 발급 토큰 urlsafe 32자 형식·발급 시각 기록
2. LNK-001 토큰에 휴대폰번호·원생명·교습소명 미포함(TEN-003 연계)
3. LNK-001 유효 토큰 재사용 멱등(outcome :reused)
4. 전역 유니크 충돌 재시도 성공(SecureRandom 스텁 — cash_receipt_triggerable_test 패턴, 첫 호출만 충돌 유도)
5. LNK-003 재발급 → 이전 토큰 find_active_by_token nil·신규 토큰 조회 성공
6. LNK-003 폐기 → nil 반환(정보 미노출)
7. 재폐기 멱등 — 최초 폐기 시각 유지
8. 폐기된 토큰 보유 청구 재발급 — 재사용 금지·신규 발급
9. 불일치·빈·nil 토큰 → nil
10. TEN-001 청구별 토큰 고유·자기 청구만 반환

### test/controllers/billing_links_controller_test.rb (10건)
1. LNK-001 유효 토큰 비로그인 200·교습소명·tel: 링크 렌더
2. LNK-002/TEN-003 원생명 마스킹(홍OO)·스냅샷 원문 미노출
3. LNK-002 타 청구·원생 명단·내부 메모·취소 사유·타 토큰 미노출
4. LNK-002 화이트리스트 표시(합계 280,000·조정 사유·계좌) + LNK-005 폼·"결제하기" 부재
5. LNK-003 폐기 토큰 → 404 만료 페이지·청구 정보 일절 미노출
6. LNK-003 재발급 후 이전 토큰 404·신규 토큰 200
7. LNK-003 존재하지 않는 토큰 → 동일 만료 안내
8. TEN-001 타 교습소 청구 정보 미노출
9. no-store 헤더·noindex 메타·앱 셸(nav) 없는 공개 레이아웃
10. 납부 상태 3값 매핑(PAID→success / PARTIALLY_PAID→brand / OVERDUE→warning 배지 톤)

## 5. 3-S 전달 메모 (통합 시 처리)

1. **마이그레이션**: `invoices`에 `public_token(string)` + 전역 유니크 인덱스, `public_token_issued_at(datetime)`·`public_token_revoked_at(datetime)` 추가 — 위 컬럼명·의미 그대로 사용(서비스·컨트롤러·테스트 전부 이 시그니처 기준).
2. **routes.rb**: `get "/b/:token", to: "billing_links#show", as: :billing_link` 결선 권장. 컨트롤러는 표준 `params[:token]` 사용.
   - 결선 후 `test/controllers/billing_links_controller_test.rb` 상단의 **임시 드로우(setup)+reload_routes!(teardown) 블록 제거** 가능(주석 표기해 둠).
3. **ko.yml**: §3 키 목록 `billing_links:` 네임스페이스 병합.
4. **원장 쪽 발급/취소 액션**: `BillingLinks::TokenService.issue_for / reissue_for / revoke_for` 호출로 결선(invoices 뷰 링크 버튼 열 — 01_plan integ 범위).
5. **MessageLog 링크 주입**: 안내 알림톡 템플릿에 `/b/{token}` URL 주입 시 `issue_for` 발급값 사용(발급 안 된 청구는 발송 대상에서 제외하거나 사전 일괄 발급 필요 — 솔라피 SIMULATED 유지).
6. **Invoice#cancel! 연계 권장**: 청구 취소 시 `BillingLinks::TokenService.revoke_for(invoice)` 호출로 취소 청구의 공개 링크 즉시 폐기(현재 컨트롤러는 CANCELLED를 :pending(납부 전)로만 표시 — 폐기는 cancel! 측에서). invoice.rb는 f9 소유권 밖이라 병렬 태스크에서 수정하지 않음.
7. **LNK-004 접근 로그**: PRD 14장 W3 확정 블록 기준 A4/A9 착수 시 연계로 유예 — 본 태스크 미구현(누락 아님).
8. **연습 모드**: 공개 페이지는 발송/발행이 아닌 조회이므로 practice 분기 불필요 — 링크 발급·조회 모두 동작.

## 6. 자체 체크리스트

- [x] 소유권 화이트리스트 준수(생성 8파일 외 수정 없음, routes·마이그레이션·ko.yml·invoice.rb·기존 뷰/컨트롤러 미수정)
- [x] `bin/rubocop <자기 파일들>` 0 offenses / ERB 파싱·JS 문법 체크 통과
- [x] `bin/rails test` 전체 실행·마이그레이션 생성·서버 기동 없음(병렬 제약)
- [x] LNK-001/002/003/005 코드 강제 수단 존재(랜덤 토큰·Struct 화이트리스트·revoked_at 조회 조건·폼 부재), LNK-004는 PRD 유예(§5-7)
- [x] TEN-001(토큰 단일 청구·타 테넌트 미노출 테스트)·TEN-003(마스킹·암호화 필드 직접 노출 최소)
- [x] Turbo 규약 — GET 전용 공개 페이지(폼 없음), 422/303 이슈 미발생
