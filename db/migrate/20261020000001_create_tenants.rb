class CreateTenants < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants do |t|
      t.string :name, null: false
      t.string :business_number
      t.string :business_type
      t.string :owner_name
      t.string :address
      t.string :bank_name
      t.string :bank_account
      t.string :account_holder
      t.boolean :practice, default: false, null: false
      t.integer :onboarding_step, default: 1, null: false
      t.string :cash_receipt_link_status, default: "pending", null: false

      t.timestamps
    end
  end
end
