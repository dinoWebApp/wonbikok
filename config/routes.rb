Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

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

  # 대시보드 (루트: 인증 상태별 분기)
  root "dashboard#show"
end
