Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # 랜딩 (루트) — 비인증 렌더, 인증 원장은 /dashboard 리다이렉트 (PRD 13장, 2026-11-04 확정)
  root "landing#show"

  # 베타(파일럿) 신청 — 랜딩 공개 폼 (PRD 13.6)
  resources :beta_applications, only: %i[new create] do
    collection do
      get :done # 신청 완료 화면(리다이렉트 대상 — PRG 패턴)
    end
  end

  # 원장 인증 (가입·로그인·로그아웃)
  resource :registration, only: %i[new create]
  resource :session, only: %i[new create destroy]

  # 가입 휴대폰 인증 (F10 REF-006 — JSON 응답, Stimulus fetch 경유)
  post "registration/send_verification", to: "registrations#send_verification",
       as: :registration_send_verification
  post "registration/verify", to: "registrations#verify_code", as: :registration_verify

  # 온보딩 마법사 (2~5스텝, 1스텝은 가입)
  get "onboarding/step/:step", to: "onboarding#show", as: :onboarding_step
  patch "onboarding/step/:step", to: "onboarding#update"

  # 원생 관리 (목록·상세·등록·수정·상태 변경, CSV 일괄 등록)
  resources :students do
    collection do
      get "import", action: :import_new
      post "import", action: :import
      get "import/template", action: :import_template
      get "import/errors", action: :import_errors, defaults: { format: :csv }
    end
    member do
      patch :pause
      patch :withdraw
      patch :restore
    end
  end

  # 월간 청구 & 납부 안내 (W2 F3)
  resources :invoices, only: %i[index create edit update] do
    collection do
      patch :confirm      # 미리보기 확정: DRAFT → READY (INV-006)
      get :results        # 발송 결과(성공/실패/사유) + 대기열
      post :send_batch    # READY 대상 발송(즉시/예약)
    end
    member do
      get :cancel        # 취소 사유 폼
      post :cancel       # 청구 취소 (INV-003) — 사유 폼 POST
      post :resend       # 다시 보내기 (MSG-001 예외·이력 기록)
      post :issue_link   # 학부모 청구 링크 발급(멱등)·재발급(reissue 파라미터 — LNK-001/003)
      post :revoke_link  # 학부모 청구 링크 폐기 (LNK-003 — 사유 불요·확인 후)
    end
  end
  delete "invoices/message_log/:message_log_id", to: "invoices#cancel_queue",
         as: :invoice_message_log # 예약 발송 취소 (MSG-007)

  # 입금 확인 (W3 F4 — 수납·현금영수증 자동발행 트리거)
  resources :payments, only: %i[index new create] do
    member do
      get :cancel           # 오체크 취소 사유 폼 (PAY-002)
      post :cancel_payment  # 취소 처리(사유 필수 — PAY-002)
    end
  end

  # 미납 리마인더 (W2 F6)
  get "reminders", to: "reminders#index", as: :reminders
  get "reminders/preview", to: "reminders#preview", as: :reminder_preview       # 즉시 발송 미리보기(수신자·내용)
  post "reminders/dispatch", to: "reminders#deliver_now", as: :reminder_dispatch # 즉시 발송(Dispatcher 경유 — 이력 기록)
  get "reminders/settings", to: "reminders#settings", as: :reminder_settings
  patch "reminders/settings", to: "reminders#update_settings"
  get "reminders/history", to: "reminders#history", as: :reminder_history  # 발송 이력(원생별·일시별)
  patch "reminders/students/:student_id/remind_exclusion", to: "reminders#toggle_exclusion",
        as: :reminder_student_exclusion # 원생별 제외/해제 (MSG-004)

  # 현금영수증 발행 (W3 F5 — 바로빌 발급대행)
  resources :cash_receipts, only: %i[index show] do
    collection do
      post :issue # 수동 발행(invoice_id 지정 — CR-002 트리거 인터페이스 경유, 청구 건 신규 발행이므로 collection)
    end
    member do
      post :retry  # 수동 재발행(failed 상태만 — CR-004 상태 재조회 포함)
      get :cancel, action: :cancel_form # 취소 사유 폼
      post :cancel                      # 발행 취소(issued 상태만, 사유 필수 — CR-005)
    end
  end

  # 대시보드 (인증 후 앱 홈 — 루트가 랜딩으로 바뀌면서 이동, 2026-11-04)
  get "/dashboard", to: "dashboard#show", as: :dashboard
  get "dashboard/report", to: "dashboard#report", as: :dashboard_report # 월간 마감 리포트 (W4 F7 — HTML, PDF 후속)

  # 구독·결제 (W4 F8 v1.0 — 단일 리소스 show, 플랜·체험·상태·이력 표시)
  resource :subscription, only: :show

  # 학부모 청구 링크 (W3 F9) — 공개·비로그인, 예측 불가 토큰 (LNK-001~003)
  get "/b/:token", to: "billing_links#show", as: :billing_link

  # 관리자 콘솔 (W4 A1~A3 — 별도 인증 체계, 운영 배포 시 서브도메인 격리 가능 구조)
  namespace :admin do
    root to: "dashboards#show"
    get "dashboard", to: "dashboards#show", as: :dashboard
    resource :session, only: %i[new create destroy]
    post "session/otp", to: "sessions#create_otp", as: :session_otp
    resources :tenants, only: %i[index show]
    post "tenants/:tenant_id/change_plan", to: "tenant_actions#change_plan", as: :tenant_change_plan
    post "tenants/:tenant_id/extend_trial", to: "tenant_actions#extend_trial", as: :tenant_extend_trial
    post "tenants/:tenant_id/suspend", to: "tenant_actions#suspend", as: :tenant_suspend
    post "tenants/:tenant_id/resume", to: "tenant_actions#resume", as: :tenant_resume
    resources :subscription_payments, only: :index do
      collection do
        get :refund_new
        post :refund
      end
    end

    # 영업 직원 관리 (F10 — A2 확장: CRUD·정지 사유 ADM-001·수수료 지급 확정)
    resources :sales_staffs, only: %i[index show new create edit update] do
      member do
        post :suspend # 정지 — 사유 필수(REF-007: 코드 무효화·로그인 차단 병행)
        post :resume # 정지 해제 — 사유 필수
        post :mark_paid # 수수료 지급 확정(pending → paid) — ledger_id 쿼리 파라미터·사유 필수
      end
    end
  end

  # 영업 직원 대시보드 (F10 — 관리자·원장과 분리된 제3 인증 체계, REF-005 스코프 격리)
  namespace :sales do
    root to: "dashboards#show"
    get "dashboard", to: "dashboards#show", as: :dashboard
    resource :session, only: %i[new create destroy]
  end
end
