class AddReminderSettingsAndExclusions < ActiveRecord::Migration[8.1]
  def change
    change_table :tenants do |t|
      t.string :remind_tone, default: "standard", null: false
      t.boolean :remind_d3_enabled, default: true, null: false
      t.boolean :remind_d7_enabled, default: true, null: false
      t.boolean :remind_month_end_enabled, default: true, null: false
      t.integer :remind_send_hour, default: 9, null: false # MSG-006: 기본 오전 9시
    end

    # MSG-004: 원생별 리마인더 제외 → 자동 발송 즉시 배제
    add_column :students, :excluded_from_reminders, :boolean, default: false, null: false
  end
end
