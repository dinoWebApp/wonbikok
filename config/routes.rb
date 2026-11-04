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
      get :cancel    # 취소 사유 폼
      post :cancel   # 청구 취소 (INV-003) — 사유 폼 POST
      post :resend   # 다시 보내기 (MSG-001 예외·이력 기록)
    end
  end
  delete "invoices/message_log/:message_log_id", to: "invoices#cancel_queue",
         as: :invoice_message_log # 예약 발송 취소 (MSG-007)

  # 미납 리마인더 (W2 F6)
  get "reminders", to: "reminders#index", as: :reminders
  get "reminders/preview", to: "reminders#preview", as: :reminder_preview       # 즉시 발송 미리보기(수신자·내용)
  post "reminders/dispatch", to: "reminders#deliver_now", as: :reminder_dispatch # 즉시 발송(Dispatcher 경유 — 이력 기록)
  get "reminders/settings", to: "reminders#settings", as: :reminder_settings
  patch "reminders/settings", to: "reminders#update_settings"
  get "reminders/history", to: "reminders#history", as: :reminder_history  # 발송 이력(원생별·일시별)
  patch "reminders/students/:student_id/remind_exclusion", to: "reminders#toggle_exclusion",
        as: :reminder_student_exclusion # 원생별 제외/해제 (MSG-004)

  # 대시보드 (인증 후 앱 홈 — 루트가 랜딩으로 바뀌면서 이동, 2026-11-04)
  get "/dashboard", to: "dashboard#show", as: :dashboard
end
