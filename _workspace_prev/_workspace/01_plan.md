# 플랜: 랜딩페이지 신규 제작 + 전체 퍼블리싱 리디자인 (2026-11-04)

**모드**: 일반 (`/wonbikok_orchestrator`) — wonbikok-developer / reviewer / tester
**규모**: Full (신규 라우트+컨트롤러+뷰, 마이그레이션 1건, 전 뷰 리디자인 26파일+, 레이아웃·디자인 시스템 재구축)

## 1. 작업 범위

### A. 랜딩페이지 신규 (PRD 13장 — W3 병행 트랙 조기 착수)

- **라우트**: `root` → `landing#show`로 변경. 기존 `root "dashboard#show"`는 `get "/dashboard"`로 이동.
  - LandingController: 비인증 → 랜딩 렌더, 인증 원장 → `/dashboard` 리다이렉트.
- **뷰**: 13.2 IA 10섹션 단일 스크롤 (히어로/문제공감 3카드/해결 4스텝/핵심기능 3카드/규제안내/사용시연/사회적증거=파일럿 모집 배너/요금제 2플랜+연간토글/FAQ 8문답(13.3 시안)/최종 CTA+푸터).
- **카피**: 13.3 시안 그대로 (히어로 A형 기본). 13.4 톤 원칙 준수(공포마케팅 금지, 검증 전 수치 "설계 목표" 표기, 미제공 기능 "준비 중").
- **베타 신청 폼 (13.6)**: `BetaApplication` 모델 신규 + 마이그레이션.
  - 필수: 원장 이름·호칭, 연락 수단(이메일 또는 전화), 교습소 유형 / 선택: 원생 수 구간, 관리 방식, 가장 불편한 업무 / 필수 동의: 개인정보 수집·이용 (마케팅 수신 분리·선택).
  - 연락처는 Active Record Encryption 암호화 저장 (TEN-003 원칙 준용). 주민번호·불필요 정보 수집 금지 (TEN-002 준용).
  - 서버·클라이언트 양측 유효성 검증, 성공 상태 안내. 중복 신청 감지(최소 식별)는 노출하지 않게.
- **SEO 메타 (13.7)**: title 기본값(13.2), description, Open Graph. 실제 URL 미확정이므로 og:url 등 도메인 의존 항목은 생략.
- **트래킹 (13.5)**: 외부 분석 스크립트 미삽입(개인정보 최소화). `data-event` 속성 마크업만으로 이벤트 지점 확보 → 분석 도구 도입은 후속.
- **에셋 대체 방침**: 로고/제품 스크린샷/시연 GIF 부재 → CSS·SVG 목업과 플레이스홀더(의미 있는 alt 필수), 실에셋 확보 후 교체. 시연 섹션은 정적 4스텝 모형. 푸터 법정 고지는 준비된 것만(임의 생성 금지, 13.8) — 문의 채널·서비스 소개만.

### B. 전체 앱 퍼블리싱 리디자인 (PRD 16장)

- **디자인 토큰**: `tailwind.config.js` 신규 생성 — 브랜드 컬러(16.1: #3478F6), 배경 #F7F9FC, 텍스트 #191F28/#667085, 성공/주의/오류, 4px 간격 계열, 중간 라운드 카드, tabular-nums.
- **폰트**: Pretendard (CDN + 시스템 폰트 폴백 스택).
- **공통 컴포넌트 파셜** (`app/views/shared/`): 버튼(primary/secondary/destructive — 라벨은 동작 설명형), 카드, 상태 배지(16.2 체계: 색상+텍스트 병행), 폼 필드(라벨+에러+도움말), 빈 상태, 페이지 헤더, 플래시.
- **앱 셸**: 상단 헤더 개선 + 모바일 하단 탭 내비게이션(홈/원생/청구/알림 — 레퍼런스: 미니스탁·캐시노트), 데스크톱 폭 제한 레이아웃. 최소 터치 영역 44px, 대비 확보(40~60대 접근성 16.0).
- **대상 뷰 26파일 전면 리디자인**: sessions/registrations/onboarding(4)/students(7)/invoices(4)/reminders(4)/dashboard(1) + layouts. 로직·라우팅·모델 변경 없이 마크업·클래스만(예외: root 라우트 이동).
- **반응형**: 모바일 360px 우선 검증(가로 스크롤 금지) ~ 데스크톱. 랜딩은 데스크톱·모바일 병행(max-w-6xl), 앱은 모바일 퍼스트.
- **16.4 체크리스트** 준수: 우선 CTA 명확성, 금액·기한·상태 표시 형식 일관, 빈/로딩/오류 화면 설계.

### 제외

- 관리자 콘솔(W4 미착수), 학부모 청구 링크(W3 F9), 분석 도구 실연동, 실제 디자인 에셋 제작, A/B 테스트 인프라.

## 2. 대상 파일

**신규**: `config/routes.rb`(수정), `app/controllers/landing_controller.rb`, `app/controllers/beta_applications_controller.rb`, `app/models/beta_application.rb`, `db/migrate/xxx_create_beta_applications.rb`, `app/views/landing/*`(섹션 파셜 구성), `app/views/beta_applications/*`(폼·완료), `tailwind.config.js`, `app/views/shared/*`(컴포넌트 파셜), `config/locales/ko.yml`(랜딩 카피 — 하드코딩 금지 규칙 준수).
**수정**: `app/views/layouts/application.html.erb`(앱 셸 재구축), 기존 뷰 26파일, `app/controllers/dashboard_controller.rb`(라우트 이동 무관하나 확인), `db/schema.rb`.
**테스트**: 기존 시스템/통합 테스트 중 `root_path` 의존 수정 + 랜딩 폼 신규 테스트.

## 3. Rule ID

- **TEN-002** (주민번호 수집 금지 — 베타 폼 필드 설계), **TEN-003** (식별정보 암호화·마스킹 — BetaApplication 연락처), **TEN-006 준용** (기록 최소화).
- **16.2 상태 배지 체계**·**16.4 검수 체크리스트** — 리디자인 준거.
- **13.4 카피 원칙** — 랜딩 문구 검증 기준.
- 기존 INV/PAY/MSG/CR 로직 불변 (뷰 마크업만 변경).

## 4. PRD/AGENTS.md 수정 필요 항목 (Phase 2)

- PRD 13장에 "구현 확정 사항(2026-11-04)" 추가: 루트 결정(/=랜딩, /dashboard 이동), BetaApplication 스키마, 트래킹 최소 범위(data-event 마크업, 외부 스크립트 제외), 에셋 목업 대체 방침, Pretendard 채택. 버전 v2.2→v2.3.
- AGENTS.md: 진행 상황 표에 병행 트랙(랜딩·퍼블리싱) 행 추가.

## 5. 위임 계획

| Phase | 위임 | 지시 요약 |
|---|---|---|
| 2 | 오케스트레이터 | PRD 13장 구현 확정 사항 + AGENTS.md 표 갱신 |
| 3-A | wonbikok-developer | 디자인 시스템(토큰·파셜·앱셸) + 기존 26 뷰 리디자인. `_workspace/01_plan.md`, `01a_uibowl_references.md` 참조. 산출물 `03_implementation.md` |
| 3-B | wonbikok-developer | 랜딩페이지 일체(라우트·컨트롤러·BetaApplication·뷰·SEO). 3-A 종료 후 순차 실행. 산출물 `03_implementation.md` 갱신 |
| 4 | 오케스트레이터 | rubocop 0에러 + brakeman 0경고 + rails test |
| 5 | wonbikok-reviewer | 뷰·폼 보안(스팸·개인정보), TEN-002/003, 16.4 체크리스트, 반응형·접근성 준수 검증. `05_review.md` |
| 6 | wonbikok-developer | 리뷰 지적 최소 수정 |
| 7 | wonbikok-tester | 기존 테스트 회귀(라우트 변경 대응 포함) + 랜딩 폼 테스트(유효성·동의·암호화) + 반응형 시스템 테스트. `07_test_report.md` |
| 8 | 오케스트레이터 | bin/dev 부트 + 랜딩/대시보드/주요 화면 렌더 확인 |
| 9 | 오케스트레이터 | 완료 보고 + AGENTS.md 갱신 + progress.json 리셋 |

## 6. 리스크

1. **root 라우트 변경** → 기존 테스트·링크 실패 가능 (Tester에서 일괄 수정).
2. **전 뷰 리디자인** → 시스템 테스트 셀렉터 파손 가능 (마크업 유지보다 접근성 우선, 테스트 수정 허용).
3. **Pretendard CDN** 오프라인 환경 → 시스템 폰트 폴백 스택 필수.
4. **랜딩 폼 스팸** → 기본 rate limit만(과투자 금지, 파일럿 전).
5. **디자인 에셋 부재** → 목업으로 출시 품질 미달 구간 존재(시연·스크린샷) — 실에셋 후속 교체 전제.
6. 퍼블리싱 대규모 위임 1회(3-A) 분량 리스크 → Developer가 섹션별 우선순위(앱셸→폼→목록→상세) 순 진행.
