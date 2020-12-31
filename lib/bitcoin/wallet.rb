module Bitcoin
  module Wallet
    autoload :Base, 'bitcoin/wallet/base'
    autoload :Account, 'bitcoin/wallet/account'
    autoload :DB, 'bitcoin/wallet/db'
    autoload :MasterKey, 'bitcoin/wallet/master_key'
    autoload :Utxo, 'bitcoin/wallet/utxo'
    autoload :UtxoHandler, 'bitcoin/wallet/utxo_handler'
  end
end
