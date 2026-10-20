class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :phone_number, null: false
      t.string :password_digest, null: false
      t.string :role, default: "owner", null: false
      t.datetime :last_login_at

      t.timestamps
    end
    add_index :users, :phone_number, unique: true
  end
end
